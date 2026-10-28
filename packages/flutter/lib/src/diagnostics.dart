import 'dart:collection';
import 'dart:convert';

/// 固定阶段可防止调用者的值成为无界指标标签。
enum BridgeStage {
  ready('ready'),
  start('start'),
  send('send'),
  receive('receive'),
  callbackEnqueue('callback.enqueue'),
  callbackDeliver('callback.deliver'),
  end('end'),
  error('error'),
  timeout('timeout'),
  cancel('cancel'),
  close('close'),
  backpressure('backpressure'),
  callbackException('callback.exception');

  final String label;
  const BridgeStage(this.label);
}

enum BridgeGauge {
  queuedMessages,
  queuedBytes,
  urgentMessages,
  urgentBytes,
  pendingBusiness,
  pendingControl,
  activeCalls,
  activeSubscriptions,
}

final class BridgeDiagnosticRecord {
  final double timestampMs;
  final String stage;
  final String? clientId, callbackId, subscriptionId, method, topic, code;
  const BridgeDiagnosticRecord(
    this.timestampMs,
    this.stage, {
    this.clientId,
    this.callbackId,
    this.subscriptionId,
    this.method,
    this.topic,
    this.code,
  });
  Map<String, Object?> toJson() => {
    'timestampMs': timestampMs,
    'stage': stage,
    if (clientId != null) 'clientId': clientId,
    if (callbackId != null) 'callbackId': callbackId,
    if (subscriptionId != null) 'subscriptionId': subscriptionId,
    if (method != null) 'method': method,
    if (topic != null) 'topic': topic,
    if (code != null) 'code': code,
  };
}

final class BridgeLatencySnapshot {
  final int count;
  final double sumMs, maxMs;
  final List<int> histogram;
  const BridgeLatencySnapshot(this.count, this.sumMs, this.maxMs, this.histogram);
  Map<String, Object?> toJson() => {
    'count': count,
    'sumMs': sumMs,
    'maxMs': maxMs,
    'histogram': histogram,
  };
}

final class BridgeDiagnosticsSnapshot {
  final Map<String, int> counters, gauges, peaks;
  final List<BridgeDiagnosticRecord> records;
  final BridgeLatencySnapshot latency;
  const BridgeDiagnosticsSnapshot(
    this.counters,
    this.gauges,
    this.peaks,
    this.records,
    this.latency,
  );
  Map<String, Object?> toJson() => {
    'counters': counters,
    'gauges': gauges,
    'peaks': peaks,
    'latency': latency.toJson(),
    'records': records.map((r) => r.toJson()).toList(),
  };
}

/// 指标不含载荷，环形缓冲有界；观察者失败不会递归触发通知。
final class BridgeDiagnostics {
  final int capacity;
  final void Function(BridgeDiagnosticRecord)? observer;
  final double Function()? _clock;
  final Stopwatch _watch = Stopwatch()..start();
  final _records = Queue<BridgeDiagnosticRecord>();
  final _counters = <String, int>{};
  final _gauges = {for (final g in BridgeGauge.values) g.name: 0};
  final _peaks = {for (final g in BridgeGauge.values) g.name: 0};
  final _histogram = List<int>.filled(9, 0);
  bool _notifying = false;
  int _latencyCount = 0;
  double _sum = 0, _max = 0, _last = 0;
  BridgeDiagnostics({this.capacity = 128, this.observer, double Function()? clock})
    : _clock = clock {
    if (capacity < 0 || capacity > 1024) throw RangeError.range(capacity, 0, 1024, 'capacity');
  }
  double now() {
    var value = _watch.elapsedMicroseconds / 1000;
    try {
      value = _clock?.call() ?? value;
    } catch (_) {}
    if (!value.isFinite || value < _last) value = _last;
    return _last = value;
  }

  static bool _identifier(String? s) =>
      s != null && s.length <= 256 && RegExp(r'^[A-Za-z0-9_-]+:[A-Za-z0-9_-]+$').hasMatch(s);
  static bool _name(String? s, int max) =>
      s != null &&
      utf8.encode(s).length <= max &&
      RegExp(r'^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)*$').hasMatch(s);
  static const _codes = {
    'BACKPRESSURE',
    'DISCONNECTED',
    'CLOSED',
    'NOT_READY',
    'INVALID_ARGUMENT',
    'INVALID_METHOD',
    'PAYLOAD_TOO_LARGE',
    'TOO_MANY_REQUESTS',
    'TOO_MANY_SUBSCRIPTIONS',
    'TIMEOUT',
    'CANCELLED',
    'PROTOCOL_ERROR',
    'TRANSPORT_ERROR',
    'INVALID_EVENT',
    'UNSUPPORTED',
    'UI_UNAVAILABLE',
    'PERMISSION_DENIED',
    'NOT_FOUND',
    'INTERNAL_ERROR',
  };
  void record(
    BridgeStage stage, {
    String? clientId,
    String? callbackId,
    String? subscriptionId,
    String? method,
    String? topic,
    String? code,
  }) {
    _increment(stage.label);
    final r = BridgeDiagnosticRecord(
      now(),
      stage.label,
      clientId:
          clientId != null &&
              clientId.length <= 256 &&
              RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(clientId)
          ? clientId
          : null,
      callbackId: _identifier(callbackId) ? callbackId : null,
      subscriptionId: _identifier(subscriptionId) ? subscriptionId : null,
      method: method != null && _name(method, 256) && method.split('.').length <= 2 ? method : null,
      topic: _name(topic, 128) ? topic : null,
      code: code == null ? null : (_codes.contains(code) ? code : 'OTHER'),
    );
    if (capacity > 0) {
      if (_records.length == capacity) _records.removeFirst();
      _records.addLast(r);
    }
    final notify = observer;
    if (!_notifying && notify != null) {
      _notifying = true;
      try {
        notify(r);
      } catch (_) {
        _increment('observer.error');
      } finally {
        _notifying = false;
      }
    }
  }

  void _increment(String key) => _counters[key] = (_counters[key] ?? 0) + 1;
  void discarded() => _increment('callback.discard');
  void adjust(BridgeGauge gauge, int delta) {
    final key = gauge.name;
    final current = _gauges[key], peak = _peaks[key];
    if (current == null || peak == null) throw StateError('Missing bridge gauge');
    final value = current + delta;
    if (value < 0) throw StateError('Negative bridge gauge');
    _gauges[key] = value;
    if (value > peak) _peaks[key] = value;
  }

  void observeLatency(double ms) {
    if (!ms.isFinite || ms < 0) return;
    _latencyCount++;
    _sum += ms;
    if (ms > _max) _max = ms;
    const bounds = [1, 5, 10, 50, 100, 500, 1000, 5000];
    var i = 0;
    while (i < bounds.length && ms > bounds[i]) {
      i++;
    }
    _histogram[i]++;
  }

  BridgeDiagnosticsSnapshot snapshot() => BridgeDiagnosticsSnapshot(
    Map.unmodifiable(_counters),
    Map.unmodifiable(_gauges),
    Map.unmodifiable(_peaks),
    List.unmodifiable(_records),
    BridgeLatencySnapshot(_latencyCount, _sum, _max, List.unmodifiable(_histogram)),
  );

  /// 重置累计遥测，保持当前资源计数不变。
  void reset() {
    _counters.clear();
    _records.clear();
    _peaks.addAll(_gauges);
    _latencyCount = 0;
    _sum = 0;
    _max = 0;
    _histogram.fillRange(0, 9, 0);
  }
}
