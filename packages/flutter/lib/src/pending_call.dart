part of 'client_core.dart';

/// 单次请求的生命周期，包括接收终态与交付终态之间的间隔。
/// 该间隔内 Core 保持所有者可达，以处理 cancel/close。
final class _PendingCall {
  final BridgeClient _core;
  final String id;
  final Zone zone = Zone.current;
  void Function(Map<String, Object?>)? onData;
  void Function(Map<String, Object?>)? onComplete;
  void Function(BridgeError)? onError;
  final buffered = <int, ({Map<String, Object?> frame, int bytes})>{};
  int lastSeq = 0;
  int generation = 0;
  bool accepting = true;
  bool hasProgress = false;
  bool localTerminal = false;
  bool slotHeld = false;
  double started = 0;
  Timer? startup;
  Timer? gap;
  Future<bool>? _cancellation;

  _PendingCall(this._core, this.id, this.onData, this.onComplete, this.onError);

  bool get _retained => _core._calls[id] == this;

  /// 在启动观察者或传输层可能重入前，先提交槽位与计时器。
  void start(String method, Duration timeout) {
    started = _core.diagnostics.now();
    slotHeld = true;
    _core.diagnostics.adjust(BridgeGauge.pendingBusiness, 1);
    startup = Timer(timeout, () {
      if (!slotHeld || !_retained) return;
      final ended = _stop();
      fail(const BridgeError('TIMEOUT', 'Bridge deadline exceeded'), cancelNative: true);
      _reportEnd(ended);
      _core.diagnostics.record(
        BridgeStage.timeout,
        clientId: _core._prefix,
        callbackId: id,
        code: 'TIMEOUT',
      );
    });
    _core.diagnostics.record(
      BridgeStage.start,
      clientId: _core._prefix,
      callbackId: id,
      method: method,
    );
  }

  Future<bool> cancel() {
    final cached = _cancellation;
    if (cached != null) return cached;
    final completion = Completer<bool>();
    // 在 fail/enqueue/cancel 诊断可能重入此句柄前发布状态。
    _cancellation = completion.future;
    try {
      completion.complete(_cancel());
    } catch (error, stack) {
      completion.completeError(error, stack);
    }
    return completion.future;
  }

  Future<bool> _cancel() {
    if (_core._phase == _Phase.closed ||
        !_retained ||
        localTerminal ||
        (!accepting && !hasProgress)) {
      return Future.value(false);
    }
    fail(const BridgeError('CANCELLED', 'Request cancelled'));
    return _core._requestCancel(id);
  }

  void close(BridgeError error, {bool preserveFinal = false}) {
    if (preserveFinal && !accepting && !hasProgress) return;
    fail(error, force: true);
  }

  bool _stop() {
    accepting = false;
    startup?.cancel();
    startup = null;
    gap?.cancel();
    gap = null;
    buffered.clear();
    final ended = slotHeld;
    slotHeld = false;
    if (ended) {
      _core.diagnostics.adjust(BridgeGauge.pendingBusiness, -1);
      _core.diagnostics.observeLatency(_core.diagnostics.now() - started);
    }
    return ended;
  }

  void _reportEnd(bool ended) {
    if (ended) {
      _core.diagnostics.record(BridgeStage.end, clientId: _core._prefix, callbackId: id);
    }
  }

  void _release() {
    if (_retained) {
      _core._calls.remove(id);
      _core.diagnostics.adjust(BridgeGauge.activeCalls, -1);
    }
    onData = null;
    onComplete = null;
    onError = null;
  }

  void _enqueue({
    Map<String, Object?>? data,
    Map<String, Object?>? result,
    BridgeError? error,
    int? bytes,
  }) {
    final token = generation;
    final terminal = data == null;
    final urgent = _core._phase == _Phase.closed;
    final accepted = _core._enqueue(
      BridgeDelivery(
        zone,
        urgent
            ? 256
            : bytes ??
                  _core._deliveryBytes(
                    data ?? result ?? {'code': error?.code, 'message': error?.message},
                  ),
        () {
          if (!_retained || generation != token) return;
          final dataCallback = onData;
          final completeCallback = onComplete;
          final errorCallback = onError;
          // 执行可能重入的终态业务代码前，释放业务闭包。
          if (terminal) _release();
          try {
            if (data != null) {
              dataCallback?.call(data);
            } else if (error != null) {
              errorCallback?.call(error);
            } else {
              completeCallback?.call(result ?? (throw StateError('Missing terminal result')));
            }
          } catch (_) {
            _core.diagnostics.record(BridgeStage.callbackException, callbackId: id);
          }
        },
        callbackId: id,
        onOverflow: () {
          // 关闭可能已转换此所有者的状态；被丢弃的过期
          // 数据任务不得为其重复排入紧急终态。
          if (_retained && generation == token) {
            close(const BridgeError('BACKPRESSURE', 'Callback queue exceeded'));
          }
        },
      ),
      urgent: urgent,
    );
    if (!accepted && urgent) _release();
  }

  void fail(BridgeError error, {bool cancelNative = false, bool force = false}) {
    if (!_retained || (localTerminal && !force)) return;
    localTerminal = true;
    generation++;
    final ended = _stop();
    _enqueue(error: error);
    _reportEnd(ended);
    _core.diagnostics.record(
      BridgeStage.error,
      clientId: _core._prefix,
      callbackId: id,
      code: error.code,
    );
    if (cancelNative) _core._cancelQuietly(id);
  }

  void accept(Map<String, dynamic> raw, bool oversized) {
    if (!accepting) return;
    try {
      BridgeResponseValidation.validate(raw, 'call', oversized: oversized);
      final number = (raw['seq'] as num).toInt();
      if (number <= lastSeq || buffered.containsKey(number)) return;
      if (number != lastSeq + 1 && buffered.length >= 32) {
        throw const FormatException('Call reorder buffer full');
      }
      buffered[number] = (frame: Map<String, Object?>.from(raw), bytes: _core._deliveryBytes(raw));
      var progressed = false;
      while (accepting) {
        final bufferedFrame = buffered.remove(lastSeq + 1);
        if (bufferedFrame == null) break;
        final next = bufferedFrame.frame;
        lastSeq++;
        progressed = true;
        startup?.cancel();
        startup = null;
        if (next['finished'] == true) {
          final ended = _stop();
          BridgeError? error;
          if (next.containsKey('error')) {
            error = _core._nativeError(next['error']);
            _enqueue(error: error, bytes: bufferedFrame.bytes);
          } else {
            _enqueue(
              result: Map<String, Object?>.from(next['result'] as Map),
              bytes: bufferedFrame.bytes,
            );
          }
          _reportEnd(ended);
          if (error != null) {
            _core.diagnostics.record(
              BridgeStage.error,
              clientId: _core._prefix,
              callbackId: id,
              code: error.code,
            );
          }
        } else {
          // 在入队诊断可能重入 cancel/close 前，先提交进度状态。
          hasProgress = true;
          if (onData == null) continue;
          _enqueue(
            data: Map<String, Object?>.from(next['result'] as Map),
            bytes: bufferedFrame.bytes,
          );
        }
      }
      // Dart 现有策略在按序推进后重置缺帧等待时间。
      if (progressed || buffered.isEmpty) {
        gap?.cancel();
        gap = null;
      }
      if (accepting && buffered.isNotEmpty) {
        gap ??= Timer(const Duration(seconds: 2), () {
          fail(
            const BridgeError('PROTOCOL_ERROR', 'Call sequence gap expired'),
            cancelNative: true,
          );
        });
      }
    } catch (_) {
      fail(
        const BridgeError('PROTOCOL_ERROR', 'Malformed native call response'),
        cancelNative: true,
      );
    }
  }
}
