import 'dart:async';

class BridgeError implements Exception {
  final String code;
  final String message;
  const BridgeError(this.code, this.message);
  @override
  String toString() => '$code: $message';
}

typedef BridgeCompletion = void Function(BridgeError? error, Map<String, Object?>? result);

abstract interface class BridgeAdapter {
  Future<void> connect(void Function(String) receive, void Function(BridgeError) disconnected);
  Future<void> send(String text);
  Future<void> close();
}

final class BridgeHandle {
  final String callbackId;
  final Future<bool> Function() _cancel;
  BridgeHandle(this.callbackId, this._cancel);
  Future<bool> cancel() => _cancel();
}

/// 本地事件监听器，其生命周期独立于请求回调。
final class BridgeSubscription {
  final String subscriptionId;
  final Future<bool> Function() _unsubscribe;
  Future<bool>? _completion;
  BridgeSubscription(this.subscriptionId, this._unsubscribe);
  Future<bool> unsubscribe() {
    final current = _completion;
    if (current != null) return current;
    final completion = Completer<bool>();
    final attempt = completion.future;
    // 先保存共享 Future，防止发送或诊断回调同步重入并重复退订。
    _completion = attempt;
    Future<bool>.sync(_unsubscribe).then<void>(
      completion.complete,
      onError: (Object error, StackTrace stack) {
        if (identical(_completion, attempt)) _completion = null;
        completion.completeError(error, stack);
      },
    );
    return attempt;
  }
}

/// 单个 Native 请求的可选进度处理器和必需终态处理器。
final class CallCallbacks {
  final void Function(Map<String, Object?>)? onData;
  final void Function(Map<String, Object?>) onComplete;
  final void Function(BridgeError) onError;
  const CallCallbacks({this.onData, required this.onComplete, required this.onError});
}
