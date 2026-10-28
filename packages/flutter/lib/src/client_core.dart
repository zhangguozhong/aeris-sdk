import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'bridge_types.dart';
import 'response_validation.dart';
import 'flow_control.dart';
import 'diagnostics.dart';
export 'bridge_types.dart';
export 'flow_control.dart' show FlowLimits;
export 'diagnostics.dart';

part 'pending_call.dart';

enum _Phase { created, handshaking, ready, closed }

enum _Lane { control, handshake }

final class _Pending {
  final _Lane lane;
  final String operation;
  final void Function(Map<String, Object?>) success;
  final void Function(BridgeError) failure;
  Timer? timer;
  double started = 0;
  _Pending(this.lane, this.operation, this.success, this.failure);
}

final class _Subscription {
  final String id;
  void Function(Map<String, Object?>)? onData;
  void Function(BridgeError)? onError;
  void Function()? onComplete;
  final Zone zone = Zone.current;
  final buffered = <int, Map<String, Object?>>{};
  int lastSeq = 0;
  bool fenced = false;
  bool acked = false;
  Timer? gap;
  _Subscription(this.id, this.onData, this.onError, this.onComplete);
}

/// Core 负责准入、路由与共享交付；Adapter 传输 String 载荷。
final class BridgeClient {
  final BridgeAdapter _adapter;
  final _pending = <String, _Pending>{};
  final _subscriptions = <String, _Subscription>{};
  final _calls = <String, _PendingCall>{};
  int get _businessCount => _calls.values.where((stream) => stream.slotHeld).length;
  _Phase _phase = _Phase.created;
  Completer<void>? _ready;
  int _counter = 0;
  final String _prefix = List.generate(
    4,
    (_) => Random.secure().nextInt(0x100000000).toRadixString(16).padLeft(8, '0'),
  ).join();
  final BridgeDiagnostics diagnostics;
  late final BridgeCallbackQueue _callbacks;
  int _incomingBytes = 0;
  bool _fatal = false;
  Future<void>? _closeTask;
  BridgeClient(
    this._adapter, {
    FlowLimits flowLimits = const FlowLimits(),
    BridgeDiagnostics? diagnostics,
  }) : diagnostics = diagnostics ?? BridgeDiagnostics() {
    _callbacks = BridgeCallbackQueue(flowLimits, this.diagnostics);
  }

  void _checkClosedAdmission() {
    if (_phase == _Phase.closed && !_callbacks.canAdmitUrgent) {
      diagnostics.discarded();
      throw const BridgeError('BACKPRESSURE', 'Terminal callback reserve exceeded');
    }
  }

  bool _enqueue(BridgeDelivery job, {bool urgent = false}) {
    if (_callbacks.enqueue(job, urgent: urgent)) return true;
    if (urgent) {
      diagnostics.discarded();
      _abort(const BridgeError('BACKPRESSURE', 'Terminal callback reserve exceeded'));
      return false;
    }
    final dropped = _callbacks.clearNormal()..add(job);
    _fatal = true;
    // 转换回调前先封闭入口；观察者可能重入。
    _abort(const BridgeError('BACKPRESSURE', 'Callback queue exceeded'));
    diagnostics.record(BridgeStage.backpressure, clientId: _prefix, code: 'BACKPRESSURE');
    for (final pending in dropped) {
      pending.onOverflow?.call();
    }
    return false;
  }

  int _deliveryBytes(Object? value) =>
      _incomingBytes > 0 ? _incomingBytes : utf8.encode(jsonEncode(value)).length;

  String _id() => '$_prefix:${++_counter}';

  Future<void> ready() {
    if (_phase == _Phase.closed)
      return Future.error(const BridgeError('CLOSED', 'Bridge is closed'));
    final cached = _ready;
    if (cached != null) return cached.future;
    final completion = Completer<void>();
    _ready = completion;
    _phase = _Phase.handshaking;
    unawaited(_connect());
    return completion.future;
  }

  Future<void> _connect() async {
    try {
      await _adapter.connect(
        _receive,
        (error) =>
            _abort(error, notifyNative: error.code != 'DISCONNECTED' && error.code != 'CLOSED'),
      );
      if (_phase == _Phase.closed) {
        await _closeAdapterQuietly();
        return;
      }
      final completion = _ready;
      if (completion == null) throw StateError('Missing handshake completion');
      final id = _id();
      _add(
        id,
        _Pending(
          _Lane.handshake,
          'hello',
          (m) {
            _phase = _Phase.ready;
            completion.complete();
            diagnostics.record(BridgeStage.ready, clientId: _prefix);
          },
          (e) {
            if (!completion.isCompleted) completion.completeError(e);
            _abort(e);
          },
        ),
        const Duration(seconds: 5),
      );
      await _deliver(
        _encode({'callbackId': id, 'method': 'bridge.hello', 'params': <String, Object?>{}}),
        id,
      );
    } catch (e) {
      _abort(_error(e));
    }
  }

  /// Native 可在最终结果前发送进度。函数回调仅接收
  /// 最终结果；观察者回调可消费每个按序到达的帧。
  BridgeHandle call(
    String method,
    Map<String, Object?> params,
    Object callbackOrCallbacks, {
    Duration? timeout,
    String? extra,
  }) {
    _checkClosedAdmission();
    final id = _id();
    final callbacks = callbackOrCallbacks is CallCallbacks
        ? callbackOrCallbacks
        : callbackOrCallbacks is BridgeCompletion
        ? CallCallbacks(
            onComplete: (result) => callbackOrCallbacks(null, result),
            onError: (error) => callbackOrCallbacks(error, null),
          )
        : throw ArgumentError.value(callbackOrCallbacks, 'callbackOrCallbacks');
    final stream = _PendingCall(
      this,
      id,
      callbacks.onData,
      callbacks.onComplete,
      callbacks.onError,
    );
    _calls[id] = stream;
    diagnostics.adjust(BridgeGauge.activeCalls, 1);
    final handle = BridgeHandle(id, stream.cancel);
    try {
      if (_phase != _Phase.ready) {
        throw BridgeError(
          _phase == _Phase.closed ? (_fatal ? 'BACKPRESSURE' : 'CLOSED') : 'NOT_READY',
          'Await ready first',
        );
      }
      final duration = timeout ?? const Duration(seconds: 120);
      final match = RegExp(r'[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)?')
          .matchAsPrefix(method);
      if (match?.end != method.length ||
          utf8.encode(method).length > 256 ||
          duration.inMilliseconds < 1 ||
          duration.inMilliseconds > 600000) {
        throw const BridgeError('INVALID_ARGUMENT', 'Invalid method or timeout');
      }
      if (method.startsWith('bridge.')) {
        throw const BridgeError(
          'INVALID_METHOD',
          'System methods are reserved for SDK lifecycle APIs',
        );
      }
      if (_businessCount >= 128) {
        throw const BridgeError('TOO_MANY_REQUESTS', 'Pending request limit reached');
      }
      if (extra != null && utf8.encode(jsonEncode({'extra': extra})).length > 255 * 1024) {
        throw const BridgeError('PAYLOAD_TOO_LARGE', 'extra leaves no response headroom');
      }
      _jsonValue(params, Set<Object>.identity());
      final text = _encode({
        'callbackId': id,
        'method': method,
        'params': params,
        if (timeout != null) 'timeoutMs': duration.inMilliseconds,
        if (extra != null) 'extra': extra,
      });
      stream.start(method, duration);
      unawaited(_deliver(text, id));
    } catch (error) {
      stream.fail(_error(error));
    }
    return handle;
  }

  void _cancelQuietly(String id) {
    unawaited(_requestCancel(id).then<void>((_) {}, onError: (Object _, StackTrace __) {}));
  }

  Future<BridgeSubscription> subscribe(
    String topic,
    void Function(Map<String, Object?>) onData, {
    void Function(BridgeError)? onError,
    void Function()? onComplete,
  }) {
    if (_phase != _Phase.ready) {
      return Future.error(
        BridgeError(
          _phase == _Phase.closed ? (_fatal ? 'BACKPRESSURE' : 'CLOSED') : 'NOT_READY',
          'Await ready first',
        ),
      );
    }
    final topicMatch = RegExp(r'[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)*')
        .matchAsPrefix(topic);
    if (topic.isEmpty || topic.length > 128 || topicMatch?.end != topic.length) {
      return Future.error(const BridgeError('INVALID_ARGUMENT', 'Invalid event topic'));
    }
    if (_subscriptions.length >= 32) {
      return Future.error(
        const BridgeError('TOO_MANY_SUBSCRIPTIONS', 'Subscription limit reached'),
      );
    }
    final stream = _Subscription(_id(), onData, onError, onComplete);
    bool? offNeeded;
    final handle = BridgeSubscription(stream.id, () {
      offNeeded ??= _subscriptions[stream.id] == stream;
      _retireSubscription(stream, fence: true);
      if (offNeeded != true || _phase != _Phase.ready) return Future.value(false);
      return _requestUnsubscribe(stream.id).then((accepted) {
        offNeeded = false; // false 也确认 Native 已无此订阅。
        return accepted;
      });
    });
    final done = Completer<BridgeSubscription>();
    // 发送前安装监听器：Native 可能同步确认并发送事件。
    _subscriptions[stream.id] = stream;
    diagnostics.adjust(BridgeGauge.activeSubscriptions, 1);
    void fail(BridgeError error) {
      _retireSubscription(stream, fence: true);
      _unsubscribeQuietly(stream.id);
      done.completeError(error);
    }

    final id = _id();
    _add(
      id,
      _Pending(_Lane.control, 'subscribe', (result) {
        if (result['subscriptionId'] != stream.id) {
          fail(const BridgeError('PROTOCOL_ERROR', 'Invalid subscription acknowledgement'));
          return;
        }
        stream.acked = true;
        _drainEvents(stream);
        done.complete(handle);
      }, fail),
      const Duration(seconds: 5),
    );
    unawaited(
      _deliver(
        _encode({
          'callbackId': id,
          'method': 'bridge.subscribe',
          'params': {'topic': topic, 'subscriptionId': stream.id},
        }),
        id,
      ),
    );
    return done.future;
  }

  Future<bool> _requestUnsubscribe(String target) {
    if (_phase != _Phase.ready) return Future.value(false);
    final id = _id(), done = Completer<bool>();
    _add(
      id,
      _Pending(_Lane.control, 'unsubscribe', (result) {
        if (result['accepted'] is! bool) {
          done.completeError(const BridgeError('PROTOCOL_ERROR', 'Invalid unsubscribe result'));
        } else {
          done.complete(result['accepted'] as bool);
        }
      }, done.completeError),
      const Duration(seconds: 5),
    );
    unawaited(
      _deliver(
        _encode({
          'callbackId': id,
          'method': 'bridge.unsubscribe',
          'params': {'subscriptionId': target},
        }),
        id,
      ),
    );
    return done.future;
  }

  void _unsubscribeQuietly(String id) {
    unawaited(_requestUnsubscribe(id).then<void>((_) {}, onError: (Object _, StackTrace __) {}));
  }

  void _retireSubscription(_Subscription stream, {bool fence = false}) {
    if (_subscriptions[stream.id] == stream) {
      _subscriptions.remove(stream.id);
      diagnostics.adjust(BridgeGauge.activeSubscriptions, -1);
    }
    stream.gap?.cancel();
    stream.gap = null;
    stream.buffered.clear();
    // 退出活动状态后，保留的公开句柄仍可能拥有此记录。
    // 排队交付各自保留回调，直到执行结束。
    stream.onData = null;
    stream.onError = null;
    stream.onComplete = null;
    if (fence) stream.fenced = true;
  }

  void _queueEventCallback(_Subscription stream, void Function() callback) {
    _enqueue(
      BridgeDelivery(stream.zone, _incomingBytes > 0 ? _incomingBytes : 256, () {
        if (_phase == _Phase.closed || stream.fenced) return;
        try {
          callback();
        } catch (_) {
          diagnostics.record(BridgeStage.callbackException, subscriptionId: stream.id);
        }
      }),
    );
  }

  void _failSubscription(_Subscription stream, BridgeError error) {
    final onError = stream.onError;
    _retireSubscription(stream);
    if (onError != null) _queueEventCallback(stream, () => onError(error));
    _unsubscribeQuietly(stream.id);
  }

  void _receiveEvent(Map<String, dynamic> raw, bool oversized) {
    final stream = _subscriptions[raw['subscriptionId']];
    if (stream == null) return; // 忽略已退出及其他连接的 ID。
    try {
      BridgeResponseValidation.validate(raw, 'event', oversized: oversized);
      final seq = raw['seq'] as num;
      final number = seq.toInt();
      if (number <= stream.lastSeq || stream.buffered.containsKey(number)) return;
      if (!stream.acked) {
        if (stream.buffered.length >= 32) {
          throw const FormatException('Early event buffer full');
        }
        stream.buffered[number] = Map<String, Object?>.from(raw);
        return;
      }
      if (number != stream.lastSeq + 1 && stream.buffered.length >= 32) {
        throw const FormatException('Event reorder buffer full');
      }
      stream.buffered[number] = Map<String, Object?>.from(raw);
      _drainEvents(stream);
    } catch (_) {
      _failSubscription(stream, const BridgeError('PROTOCOL_ERROR', 'Malformed native event'));
    }
  }

  void _drainEvents(_Subscription stream) {
    var progressed = false;
    while (_subscriptions[stream.id] == stream) {
      final next = stream.buffered.remove(stream.lastSeq + 1);
      if (next == null) break;
      stream.lastSeq++;
      progressed = true;
      if (next.containsKey('data')) {
        final data = Map<String, Object?>.from(next['data'] as Map);
        final onData = stream.onData;
        if (onData != null) _queueEventCallback(stream, () => onData(data));
      } else {
        final onError = stream.onError, onComplete = stream.onComplete;
        _retireSubscription(stream);
        if (next.containsKey('error') && onError != null) {
          final error = _nativeError(next['error']);
          _queueEventCallback(stream, () => onError(error));
        } else if (next['complete'] == true && onComplete != null) {
          _queueEventCallback(stream, onComplete);
        }
      }
    }
    if (progressed || stream.buffered.isEmpty) {
      stream.gap?.cancel();
      stream.gap = null;
    }
    if (_subscriptions[stream.id] == stream && stream.buffered.isNotEmpty) {
      stream.gap ??= Timer(const Duration(seconds: 2), () {
        if (_subscriptions[stream.id] == stream) {
          _failSubscription(
            stream,
            const BridgeError('PROTOCOL_ERROR', 'Event sequence gap expired'),
          );
        }
      });
    }
  }

  Future<bool> _requestCancel(String target) {
    diagnostics.record(BridgeStage.cancel, clientId: _prefix, callbackId: target);
    if (_phase != _Phase.ready) return Future.value(false);
    final id = _id(), done = Completer<bool>();
    _add(
      id,
      _Pending(_Lane.control, 'cancel', (m) {
        if (m['accepted'] is! bool) {
          done.completeError(const BridgeError('PROTOCOL_ERROR', 'Invalid cancel result'));
          return;
        }
        done.complete(m['accepted'] as bool);
      }, done.completeError),
      const Duration(seconds: 5),
    );
    unawaited(
      _deliver(
        _encode({
          'callbackId': id,
          'method': 'bridge.cancel',
          'params': {'targetCallbackId': target},
        }),
        id,
      ),
    );
    return done.future;
  }

  void _add(String id, _Pending p, Duration timeout) {
    if (p.lane == _Lane.control &&
        _pending.values.where((p) => p.lane == _Lane.control).length >= 16) {
      p.failure(const BridgeError('TOO_MANY_REQUESTS', 'Control request limit reached'));
      return;
    }
    _pending[id] = p;
    p.started = diagnostics.now();
    diagnostics.adjust(BridgeGauge.pendingControl, 1);
    p.timer = Timer(timeout, () {
      if (_pending[id] != p) return;
      _remove(id);
      p.failure(const BridgeError('TIMEOUT', 'Bridge deadline exceeded'));
      _reportEnd(id, p);
      diagnostics.record(BridgeStage.timeout, clientId: _prefix, callbackId: id, code: 'TIMEOUT');
    });
    diagnostics.record(
      BridgeStage.start,
      clientId: _prefix,
      callbackId: id,
      method: 'bridge.${p.operation}',
    );
  }

  _Pending? _remove(String id) {
    final p = _pending.remove(id);
    p?.timer?.cancel();
    if (p != null) {
      diagnostics.adjust(BridgeGauge.pendingControl, -1);
      diagnostics.observeLatency(diagnostics.now() - p.started);
    }
    return p;
  }

  void _reportEnd(String id, _Pending? pending) {
    if (pending != null) diagnostics.record(BridgeStage.end, clientId: _prefix, callbackId: id);
  }

  Future<void> _deliver(String text, String id) async {
    if (!_pending.containsKey(id) && !(_calls[id]?.slotHeld ?? false)) return;
    try {
      diagnostics.record(BridgeStage.send, clientId: _prefix, callbackId: id);
      if (_phase == _Phase.closed ||
          (!_pending.containsKey(id) && !(_calls[id]?.slotHeld ?? false)))
        return;
      await _adapter.send(text);
    } catch (_) {
      if (_pending.containsKey(id) || (_calls[id]?.slotHeld ?? false))
        _abort(const BridgeError('DISCONNECTED', 'Native channel send failed'));
    }
  }

  void _receive(String text) {
    if (_phase == _Phase.closed) return;
    final previousBytes = _incomingBytes;
    _incomingBytes = utf8.encode(text).length;
    diagnostics.record(BridgeStage.receive, clientId: _prefix);
    try {
      final raw = BridgeResponseValidation.decode(text);
      final oversized = utf8.encode(text).length > BridgeResponseValidation.maxWireBytes;
      if (raw['method'] == 'bridge.close') {
        final params = raw['params'];
        if (oversized ||
            raw.length != 2 ||
            !raw.containsKey('params') ||
            params is! Map ||
            params.length != 2 ||
            !params.containsKey('code') ||
            !params.containsKey('reason') ||
            !const {'BACKPRESSURE', 'DISCONNECTED'}.contains(params['code']) ||
            params['reason'] is! String ||
            (params['reason'] as String).isEmpty ||
            (params['reason'] as String).length > 256) {
          throw const FormatException('Invalid native close');
        }
        _abort(BridgeError(params['code'] as String, 'Native bridge closed'), notifyNative: false);
        return;
      }
      final callbackId = raw['callbackId'];
      // 在排队交付完成前，终态调用记录仍具有优先权。
      final stream = callbackId is String ? _calls[callbackId] : null;
      if (stream != null) {
        stream.accept(raw, oversized);
        return;
      }
      final p = callbackId is String ? _pending[callbackId] : null;
      if (p != null) {
        try {
          BridgeResponseValidation.validate(raw, 'control', oversized: oversized);
          if (p.operation == 'hello' &&
              !raw.containsKey('error') &&
              (raw['result'] as Map)['ready'] != true) {
            throw const FormatException('Invalid readiness result');
          }
        } catch (_) {
          if (p.operation == 'hello') {
            _abort(const BridgeError('PROTOCOL_ERROR', 'Malformed readiness response'));
          } else {
            _remove(callbackId as String);
            p.failure(const BridgeError('PROTOCOL_ERROR', 'Malformed native response'));
            _reportEnd(callbackId, p);
          }
          return;
        }
        _remove(callbackId as String);
        final error = raw.containsKey('error') ? _nativeError(raw['error']) : null;
        if (error != null) {
          p.failure(error);
        } else {
          p.success(Map<String, Object?>.from(raw['result'] as Map));
        }
        _reportEnd(callbackId, p);
        if (error != null)
          diagnostics.record(
            BridgeStage.error,
            clientId: _prefix,
            callbackId: callbackId,
            code: error.code,
          );
        return;
      }
      final subscriptionId = raw['subscriptionId'];
      if (subscriptionId is String && _subscriptions.containsKey(subscriptionId)) {
        _receiveEvent(raw, oversized);
        return;
      }
      // 未知或已退出的 ID 没有可失败的目标，但 ID 本身必须可靠。
      final identifiers = ['callbackId', 'subscriptionId'].where(raw.containsKey);
      if (identifiers.isNotEmpty &&
          identifiers.every((key) => BridgeResponseValidation.validIdentifier(raw[key])))
        return;
      throw const FormatException('Unreliable response identifiers');
    } catch (_) {
      _abort(const BridgeError('PROTOCOL_ERROR', 'Malformed native message'));
    } finally {
      _incomingBytes = previousBytes;
    }
  }

  BridgeError _nativeError(Object? value) {
    if (value is! Map || value['code'] is! String || value['message'] is! String)
      throw const FormatException('Invalid error');
    return BridgeError(value['code'] as String, value['message'] as String);
  }

  BridgeError _error(Object e) {
    final error = e is BridgeError
        ? e
        : const BridgeError('TRANSPORT_ERROR', 'Bridge transport failed');
    return error;
  }

  String _encode(Map<String, Object?> m) {
    final text = jsonEncode(m);
    if (utf8.encode(text).length > 256 * 1024)
      throw const BridgeError('PAYLOAD_TOO_LARGE', 'Message too large');
    return text;
  }

  void _jsonValue(Object? v, Set<Object> stack) {
    if (v == null || v is bool || v is String) return;
    if (v is num && v.isFinite && v.abs() <= 9007199254740991) return;
    if (v is Map || v is List) {
      if (!stack.add(v)) throw const BridgeError('INVALID_ARGUMENT', 'Cyclic params');
      if (v is Map) {
        for (final entry in v.entries) {
          if (entry.key is! String)
            throw const BridgeError('INVALID_ARGUMENT', 'Params keys must be strings');
          _jsonValue(entry.value, stack);
        }
      } else {
        for (final item in v as List) _jsonValue(item, stack);
      }
      stack.remove(v);
      return;
    }
    throw const BridgeError(
      'INVALID_ARGUMENT',
      'Params must be JSON; parameter callbacks are not implemented',
    );
  }

  void _abort(BridgeError error, {bool notifyNative = true}) {
    final shouldNotify = notifyNative && (_phase == _Phase.ready || _phase == _Phase.handshaking);
    if (_phase == _Phase.closed) return;
    // 紧急任务仅保留短错误码与固定消息。
    // Adapter 由应用提供，可能传入任意大小的错误。
    final safeCode = error.code.length <= 64 && RegExp(r'^[A-Z][A-Z0-9_]*$').hasMatch(error.code)
        ? error.code
        : 'DISCONNECTED';
    error = BridgeError(safeCode, 'Bridge disconnected');
    _phase = _Phase.closed;
    unawaited(_closeTransport(shouldNotify));
    _fatal = _fatal || error.code == 'BACKPRESSURE';
    diagnostics.record(BridgeStage.close, clientId: _prefix, code: error.code);
    for (final stream in _calls.values.toList()) {
      stream.close(error, preserveFinal: true);
    }
    for (final stream in _subscriptions.values.toList()) {
      _retireSubscription(stream, fence: true);
    }
    final operations = _pending.entries.toList();
    for (final entry in operations) {
      _remove(entry.key);
    }
    for (final entry in operations) {
      entry.value.failure(error);
      _reportEnd(entry.key, entry.value);
    }
    final completion = _ready;
    if (completion != null && !completion.isCompleted) completion.completeError(error);
  }

  Future<void> _closeAdapterQuietly() async {
    try {
      await _adapter.close();
    } catch (_) {}
  }

  Future<void> _closeTransport(bool notifyNative) {
    return _closeTask ??= Future<void>.microtask(() async {
      try {
        if (notifyNative) {
          await _adapter
              .send(
                _encode({
                  'callbackId': _id(),
                  'method': 'bridge.close',
                  'params': <String, Object?>{},
                }),
              )
              .timeout(const Duration(milliseconds: 250));
        }
      } catch (_) {
        // 尽力通知；无法通信时由原生宿主关闭对应容器。
      } finally {
        try {
          await _adapter.close();
        } catch (_) {}
      }
    });
  }

  Future<void> dispose() async {
    if (_phase == _Phase.closed) {
      await _closeTask;
      return;
    }
    final shouldNotify = _phase == _Phase.ready || _phase == _Phase.handshaking;
    _phase = _Phase.closed;
    unawaited(_closeTransport(shouldNotify));
    diagnostics.record(BridgeStage.close, clientId: _prefix, code: 'CLOSED');
    for (final stream in _calls.values.toList()) {
      stream.close(const BridgeError('DISCONNECTED', 'Bridge disconnected'), preserveFinal: true);
    }
    for (final stream in _subscriptions.values.toList()) {
      _retireSubscription(stream, fence: true);
    }
    final operations = _pending.entries.toList();
    for (final entry in operations) {
      _remove(entry.key);
    }
    for (final entry in operations) {
      entry.value.failure(const BridgeError('CLOSED', 'Bridge disposed'));
      _reportEnd(entry.key, entry.value);
    }
    final completion = _ready;
    if (completion != null && !completion.isCompleted)
      completion.completeError(const BridgeError('CLOSED', 'Bridge disposed'));
    await _closeTransport(shouldNotify);
  }
}
