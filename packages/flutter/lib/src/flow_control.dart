import 'dart:async';
import 'dart:collection';

import 'diagnostics.dart';

final class FlowLimits {
  final int maxMessages, maxBytes, urgentMessages, urgentBytes, batchSize;
  const FlowLimits({
    this.maxMessages = 256,
    this.maxBytes = 4 * 1024 * 1024,
    this.urgentMessages = 512,
    this.urgentBytes = 512 * 1024,
    this.batchSize = 32,
  });
  void validate() {
    if (maxMessages < 1 ||
        maxBytes < 1 ||
        urgentMessages < 1 ||
        urgentBytes < 1 ||
        batchSize < 1 ||
        batchSize > 32) {
      throw ArgumentError('Flow limits must be positive; batchSize must be at most 32');
    }
  }
}

/// 每个任务保留一个所有者；丢弃的普通任务可转为终态错误。
final class BridgeDelivery {
  final Zone zone;
  final int bytes;
  final void Function() callback;
  final void Function()? onOverflow;
  final String? callbackId;
  const BridgeDelivery(this.zone, this.bytes, this.callback, {this.onOverflow, this.callbackId});
}

/// 内部交付调度器：首轮使用微任务，后续轮次让出调度。
final class BridgeCallbackQueue {
  final FlowLimits limits;
  final BridgeDiagnostics diagnostics;
  final _normal = Queue<BridgeDelivery>(), _urgent = Queue<BridgeDelivery>();
  int _normalBytes = 0, _urgentBytes = 0;
  bool _scheduled = false;
  BridgeCallbackQueue(this.limits, this.diagnostics) {
    limits.validate();
  }
  bool get canAdmitUrgent =>
      _urgent.length < limits.urgentMessages && _urgentBytes + 256 <= limits.urgentBytes;
  bool enqueue(BridgeDelivery job, {bool urgent = false}) {
    if (urgent
        ? (_urgent.length >= limits.urgentMessages || _urgentBytes + job.bytes > limits.urgentBytes)
        : (_normal.length >= limits.maxMessages || _normalBytes + job.bytes > limits.maxBytes))
      return false;
    (urgent ? _urgent : _normal).addLast(job);
    if (urgent) {
      _urgentBytes += job.bytes;
    } else {
      _normalBytes += job.bytes;
    }
    _adjust(job, urgent, 1);
    diagnostics.record(BridgeStage.callbackEnqueue, callbackId: job.callbackId);
    if (!_scheduled) {
      _scheduled = true;
      job.zone.scheduleMicrotask(_drain);
    }
    return true;
  }

  void _adjust(BridgeDelivery j, bool urgent, int sign) {
    diagnostics.adjust(BridgeGauge.queuedMessages, sign);
    diagnostics.adjust(BridgeGauge.queuedBytes, j.bytes * sign);
    if (urgent) {
      diagnostics.adjust(BridgeGauge.urgentMessages, sign);
      diagnostics.adjust(BridgeGauge.urgentBytes, j.bytes * sign);
    }
  }

  List<BridgeDelivery> clearNormal() {
    final dropped = _normal.toList();
    _normal.clear();
    _normalBytes = 0;
    for (final j in dropped) {
      _adjust(j, false, -1);
    }
    return dropped;
  }

  void _drain() {
    var n = 0;
    while (n++ < limits.batchSize && (_urgent.isNotEmpty || _normal.isNotEmpty)) {
      final urgent = _urgent.isNotEmpty;
      final job = (urgent ? _urgent : _normal).removeFirst();
      if (urgent) {
        _urgentBytes -= job.bytes;
      } else {
        _normalBytes -= job.bytes;
      }
      // 先释放资源，涵盖过期或已隔离任务以及消费者异常。
      _adjust(job, urgent, -1);
      diagnostics.record(BridgeStage.callbackDeliver, callbackId: job.callbackId);
      try {
        job.zone.run(job.callback);
      } catch (_) {
        diagnostics.record(BridgeStage.callbackException, callbackId: job.callbackId);
      }
    }
    if (_urgent.isNotEmpty || _normal.isNotEmpty) {
      Timer.run(_drain);
    } else {
      _scheduled = false;
    }
  }
}
