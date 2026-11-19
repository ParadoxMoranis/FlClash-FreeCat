import 'dart:convert';
import 'dart:typed_data';

import 'package:fl_clash/common/yaml.dart' show loadPlainYaml;
import 'package:fl_clash/common/yaml_writer.dart';
import 'package:pointycastle/export.dart';

import 'errors.dart';

final _whitespace = RegExp(r'\s');
final _base64 = RegExp(
  r'^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$',
);
final _marker = RegExp(r'^(?:(?:📊\s*)?剩余流量|套餐到期|🏠\s*网址|🪧\s*提示)\s*[:：]');
const _builtins = {
  'DIRECT',
  'REJECT',
  'REJECT-DROP',
  'PASS',
  'PASS-RULE',
  'COMPATIBLE',
  'GLOBAL',
};
const _commaPayloadRules = {
  'AND',
  'OR',
  'NOT',
  'SUB-RULE',
  'DOMAIN-REGEX',
  'PROCESS-NAME-REGEX',
  'PROCESS-PATH-REGEX',
};

Uint8List _decodeBase64(String value) {
  final compact = value.replaceAll(_whitespace, '');
  if (compact.isEmpty || !_base64.hasMatch(compact)) {
    throw const FreecatException(FreecatFailure.decryption);
  }
  final bytes = base64.decode(compact);
  if (base64.encode(bytes) != compact) {
    throw const FreecatException(FreecatFailure.decryption);
  }
  return bytes;
}

Uint8List decryptFreecatSubscription(String body) {
  try {
    final ciphertext = _decodeBase64(body);
    if (ciphertext.length % 16 != 0) {
      throw const FreecatException(FreecatFailure.decryption);
    }
    final cipher = CBCBlockCipher(AESEngine())
      ..init(
        false,
        ParametersWithIV<KeyParameter>(
          KeyParameter(ascii.encode('efbf326c0a946d3f')),
          ascii.encode('ed287033263d145d'),
        ),
      );
    final plaintext = Uint8List(ciphertext.length);
    for (var offset = 0; offset < ciphertext.length; offset += 16) {
      cipher.processBlock(ciphertext, offset, plaintext, offset);
    }
    final padding = plaintext.last;
    if (padding < 1 || padding > 16) {
      throw const FreecatException(FreecatFailure.decryption);
    }
    for (
      var index = plaintext.length - padding;
      index < plaintext.length;
      index++
    ) {
      if (plaintext[index] != padding) {
        throw const FreecatException(FreecatFailure.decryption);
      }
    }
    return _decodeBase64(
      ascii.decode(
        Uint8List.sublistView(plaintext, 0, plaintext.length - padding),
      ),
    );
  } catch (_) {
    throw const FreecatException(FreecatFailure.decryption);
  }
}

Uint8List normalizeFreecatSubscription(Uint8List body) {
  try {
    final text = utf8.decode(body);
    Object? parsed;
    try {
      final plaintext = utf8.decode(decryptFreecatSubscription(text));
      _rejectDecoy(plaintext);
      parsed = loadPlainYaml(plaintext);
    } on FreecatException catch (error) {
      if (error.failure != FreecatFailure.decryption) {
        rethrow;
      }
      _rejectDecoy(text);
      try {
        parsed = loadPlainYaml(text);
      } catch (_) {
        throw error;
      }
      if (parsed is! Map<String, Object?> || parsed['proxies'] is! List) {
        rethrow;
      }
    }
    if (parsed is! Map<String, Object?>) {
      throw const FreecatException(FreecatFailure.invalidProfile);
    }
    final proxies = _maps(parsed['proxies']);
    final groups = _maps(parsed['proxy-groups'] ?? const []);
    final names = {..._builtins};
    final proxyNames = <String>{};
    final removed = <String>{};
    final retained = <Map>[];
    var usable = false;
    for (final proxy in proxies) {
      final name = _name(proxy['name']);
      if (!proxyNames.add(name)) {
        throw const FreecatException(FreecatFailure.invalidProfile);
      }
      if (_marker.hasMatch(name)) {
        removed.add(name);
        continue;
      }
      if (!names.add(name)) {
        throw const FreecatException(FreecatFailure.invalidProfile);
      }
      final type = _name(proxy['type']).toLowerCase();
      if (!{
        'direct',
        'reject',
        'reject-drop',
        'pass',
        'compatible',
      }.contains(type)) {
        _name(proxy['server']);
        final port = proxy['port'];
        final number = port is int ? port : int.tryParse('$port');
        if (number == null || number < 1 || number > 65535) {
          throw const FreecatException(FreecatFailure.invalidProfile);
        }
        usable = true;
      }
      retained.add(proxy);
    }
    if (!usable) {
      throw const FreecatException(FreecatFailure.invalidProfile);
    }
    var hasGlobal = false;
    for (final group in groups) {
      final name = _name(group['name']);
      _name(group['type']);
      if (name == 'GLOBAL' && !hasGlobal) {
        hasGlobal = true;
      } else if (!names.add(name)) {
        throw const FreecatException(FreecatFailure.invalidProfile);
      }
    }
    for (final group in groups) {
      final members = group['proxies'];
      if (members is! List) {
        throw const FreecatException(FreecatFailure.invalidProfile);
      }
      final kept = <String>[];
      for (final member in members) {
        final name = _name(member);
        if (!removed.contains(name)) {
          if (!names.contains(name)) {
            throw const FreecatException(FreecatFailure.invalidProfile);
          }
          kept.add(name);
        }
      }
      if (kept.isEmpty) {
        throw const FreecatException(FreecatFailure.invalidProfile);
      }
      group['proxies'] = kept;
    }
    final subRules = parsed['sub-rules'] ?? const <String, Object?>{};
    if (subRules is! Map) {
      throw const FreecatException(FreecatFailure.invalidProfile);
    }
    final subRuleNames = subRules.keys.map(_name).toSet();
    _validateRules(parsed['rules'] ?? const [], names, subRuleNames);
    for (final rules in subRules.values) {
      _validateRules(rules, names, subRuleNames);
    }
    parsed['proxies'] = retained;
    final output = writeYaml(parsed);
    _rejectDecoy(output);
    return utf8.encode(output);
  } on FreecatException {
    rethrow;
  } catch (_) {
    throw const FreecatException(FreecatFailure.invalidProfile);
  }
}

List<Map> _maps(Object? value) {
  if (value is! List || value.any((item) => item is! Map)) {
    throw const FreecatException(FreecatFailure.invalidProfile);
  }
  return value.cast<Map>();
}

String _name(Object? value) {
  if (value is! String || value.trim().isEmpty) {
    throw const FreecatException(FreecatFailure.invalidProfile);
  }
  return value;
}

void _rejectDecoy(String text) {
  final lower = text.toLowerCase();
  if (lower.contains('freecatnodles.com') || lower.contains('freevip')) {
    throw const FreecatException(FreecatFailure.decoy);
  }
}

void _validateRules(
  Object? rules,
  Set<String> names,
  Set<String> subRuleNames,
) {
  if (rules is! List) {
    throw const FreecatException(FreecatFailure.invalidProfile);
  }
  for (final rule in rules) {
    final parts = _name(rule).split(',').map((part) => part.trim()).toList();
    final type = parts.first.toUpperCase();
    var targetIndex = type == 'MATCH' ? 1 : 2;
    if (_commaPayloadRules.contains(type)) {
      targetIndex = parts.length - 1;
      while (targetIndex > 1 &&
          {'no-resolve', 'src'}.contains(parts[targetIndex])) {
        targetIndex--;
      }
    }
    final target = parts.length > targetIndex ? parts[targetIndex] : '';
    if (!(type == 'SUB-RULE' ? subRuleNames : names).contains(target)) {
      throw const FreecatException(FreecatFailure.invalidProfile);
    }
  }
}
