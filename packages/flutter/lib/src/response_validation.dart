import 'dart:convert';

/// 路由解码器的防御性上限大于有效传输帧的上限。
/// 在平台解码器丢失重复信息前，拒绝有歧义的对象键。
final class BridgeResponseValidation {
  static const maxWireBytes = 256 * 1024;
  static const maxRoutingBytes = 2 * 1024 * 1024;
  static const maxSafeInteger = 9007199254740991;
  static final _identifier = RegExp(r'^[A-Za-z0-9_-]+:[A-Za-z0-9_-]+$');

  static bool validIdentifier(Object? value) =>
      value is String && utf8.encode(value).length <= 256 && _identifier.hasMatch(value);

  static Map<String, dynamic> decode(String text) {
    if (utf8.encode(text).length > maxRoutingBytes) {
      throw const FormatException('Defensive response limit exceeded');
    }
    _JsonStructure(text).scan();
    final raw = jsonDecode(text);
    if (raw is! Map<String, dynamic>) {
      throw const FormatException('Expected response object');
    }
    return raw;
  }

  static void validate(Map<String, dynamic> raw, String mode, {bool oversized = false}) {
    final event = mode == 'event', call = mode == 'call';
    final allowed = event
        ? const {'subscriptionId', 'seq', 'data', 'error', 'complete'}
        : const {'callbackId', 'seq', 'finished', 'result', 'error', 'extra'};
    final seq = raw['seq'];
    if (oversized ||
        raw.keys.any((k) => !allowed.contains(k)) ||
        !validIdentifier(raw[event ? 'subscriptionId' : 'callbackId']) ||
        seq is! num ||
        !seq.isFinite ||
        seq < 1 ||
        seq > maxSafeInteger ||
        seq != seq.truncateToDouble() ||
        (!event && !call && seq != 1)) {
      throw const FormatException('Invalid response envelope');
    }
    if (event) {
      if (['data', 'error', 'complete'].where(raw.containsKey).length != 1 ||
          (raw.containsKey('complete') && raw['complete'] != true)) {
        throw const FormatException('Invalid event variant');
      }
    } else {
      if (raw.containsKey('result') == raw.containsKey('error') ||
          (raw.containsKey('extra') && raw['extra'] is! String) ||
          (call
              ? raw['finished'] is! bool
              : raw.containsKey('finished') && raw['finished'] != true) ||
          (call && raw.containsKey('error') && raw['finished'] != true)) {
        throw const FormatException('Invalid response variant');
      }
    }
    if (raw.containsKey('error')) {
      final error = raw['error'];
      if (error is! Map<String, dynamic> ||
          error.length != 2 ||
          error['code'] is! String ||
          error['message'] is! String ||
          (error['code'] as String).isEmpty ||
          (error['code'] as String).length > 128 ||
          (error['message'] as String).isEmpty ||
          (error['message'] as String).length > 4096) {
        throw const FormatException('Invalid native error');
      }
    } else if (raw.containsKey(event ? 'data' : 'result')) {
      final payload = raw[event ? 'data' : 'result'];
      if (payload is! Map<String, dynamic>) throw const FormatException('Expected object payload');
      _payload(payload, 0);
    }
  }

  static void _payload(Object? value, int depth) {
    if (depth > 32) throw const FormatException('Payload depth exceeded');
    if (value == null || value is bool || value is String) return;
    if (value is num) {
      if (!value.isFinite || (value == value.truncateToDouble() && value.abs() > maxSafeInteger)) {
        throw const FormatException('Invalid payload number');
      }
      return;
    }
    if (value is Map<String, dynamic>) {
      for (final entry in value.entries) {
        if (const {'__proto__', 'prototype', 'constructor'}.contains(entry.key)) {
          throw const FormatException('Reserved payload key');
        }
        _payload(entry.value, depth + 1);
      }
      return;
    }
    if (value is List) {
      for (final item in value) {
        _payload(item, depth + 1);
      }
      return;
    }
    throw const FormatException('Invalid payload value');
  }
}

/// JSON 语法由 jsonDecode 检查；此有界结构检查
/// 保留 jsonDecode 会合并的重复键，包括转义后的等价拼写。
final class _JsonStructure {
  final String text;
  int at = 0;
  _JsonStructure(this.text);
  void scan() {
    _value(0);
    _space();
    if (at != text.length) _invalid();
  }

  Never _invalid() => throw const FormatException('Invalid or ambiguous JSON');
  void _space() {
    while (at < text.length && const [32, 9, 10, 13].contains(text.codeUnitAt(at))) {
      at++;
    }
  }

  String _string() {
    if (at >= text.length || text[at] != '"') _invalid();
    final start = at++;
    while (at < text.length) {
      final ch = text[at++];
      if (ch == r'\') {
        if (at >= text.length) _invalid();
        at++;
      } else if (ch == '"') {
        final value = jsonDecode(text.substring(start, at)) as String;
        // 在整帧解码或路由前，拒绝依赖解码器的替换或键混淆；
        // 成对的 UTF16 码元仍作为有效 Unicode 接受。
        for (var i = 0; i < value.length; i++) {
          final unit = value.codeUnitAt(i);
          if (unit >= 0xd800 && unit <= 0xdbff) {
            if (++i >= value.length) _invalid();
            final low = value.codeUnitAt(i);
            if (low < 0xdc00 || low > 0xdfff) _invalid();
          } else if (unit >= 0xdc00 && unit <= 0xdfff) {
            _invalid();
          }
        }
        return value;
      }
    }
    _invalid();
  }

  void _value(int depth) {
    _space();
    if (at >= text.length) _invalid();
    final ch = text[at];
    if (ch == '"') {
      _string();
      return;
    }
    if (ch == '{' || ch == '[') {
      if (depth >= 64) _invalid();
      final object = ch == '{', end = ch == '{' ? '}' : ']';
      final keys = <String>{};
      at++;
      _space();
      if (at < text.length && text[at] == end) {
        at++;
        return;
      }
      while (true) {
        _space();
        if (object) {
          if (!keys.add(_string())) _invalid();
          _space();
          if (at >= text.length || text[at++] != ':') _invalid();
        }
        _value(depth + 1);
        _space();
        if (at >= text.length) _invalid();
        final next = text[at++];
        if (next == end) return;
        if (next != ',') _invalid();
      }
    }
    final start = at;
    while (at < text.length && !const [',', ']', '}', ' ', '\t', '\n', '\r'].contains(text[at])) {
      at++;
    }
    if (at == start) _invalid();
  }
}
