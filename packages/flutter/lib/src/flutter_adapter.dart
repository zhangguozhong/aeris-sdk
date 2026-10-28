import 'package:flutter/services.dart';

import 'bridge_types.dart';

/// 每个 BinaryMessenger 主 isolate 恰好对应一个固定通道及处理器。
final class FlutterAdapter implements BridgeAdapter {
  static final Expando<FlutterAdapter> _owners = Expando<FlutterAdapter>();
  final BinaryMessenger _messenger;
  // 框架确认允许为空；实际业务载荷仍只接受非空 String。
  late final BasicMessageChannel<String?> _channel;
  bool _connected = false;
  FlutterAdapter({BinaryMessenger? messenger})
    : _messenger = messenger ?? ServicesBinding.instance.defaultBinaryMessenger {
    _channel = BasicMessageChannel<String?>(
      'aeris_bridge',
      const StringCodec(),
      binaryMessenger: _messenger,
    );
  }
  @override
  Future<void> connect(
    void Function(String) receive,
    void Function(BridgeError) disconnected,
  ) async {
    if (_connected || _owners[_messenger] != null)
      throw const BridgeError('DUPLICATE_INIT', 'One bridge per messenger');
    _owners[_messenger] = this;
    _connected = true;
    _channel.setMessageHandler((String? text) async {
      if (!_connected) return null;
      if (text == null)
        disconnected(const BridgeError('PROTOCOL_ERROR', 'Expected native String'));
      else
        receive(text);
      return null; // 仅为框架确认，不代表业务结果。
    });
  }

  @override
  Future<void> send(String text) async {
    if (!_connected) throw const BridgeError('CLOSED', 'Adapter is closed');
    final ack = await _channel.send(text);
    if (ack != null)
      throw const BridgeError('PROTOCOL_ERROR', 'Expected empty framework acknowledgement');
  }

  @override
  Future<void> close() async {
    if (!_connected) return;
    _connected = false;
    if (identical(_owners[_messenger], this)) {
      _channel.setMessageHandler(null);
      _owners[_messenger] = null;
    }
  }
}
