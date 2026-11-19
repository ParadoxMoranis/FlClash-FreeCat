import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:fl_clash/features/freecat/errors.dart';
import 'package:fl_clash/features/freecat/subscription.dart';
import 'package:pointycastle/export.dart';
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

const _fixture = '''mixed-port: 7890
proxies:
  - { name: 'A', type: trojan, server: 203.0.113.10, port: 443, password: test, udp: true, sni: example.com, skip-cert-verify: true }
proxy-groups:
  - { name: 'Freecat', type: select, proxies: ['A'] }
rules:
  - 'MATCH,Freecat'
''';
const _ciphertext =
    '8SlwJWj6g+z7Z91qefKl/j+J49j5bY0ZUFvFF5zd/oBzMRbCPr+/5pBUzRXgnvdBZifo4VrMYc/y6J0w9xmLIwk+iPF4n3EnZF0EnORAnlv40XLMuT/OjxE0EsIVVIm8Rau4FYsX0PpNoSZfUIITE7Cl7a+3ng2IO9T4s1NUyJQBsbfEO3ECeP+9ngA1J2abi1aDdObwYE4QpOkmj59E9pBmfGwtIOPEo8gEEwESPrRhRg/sS0zxeAwmhuFBdAVK9SBgUEsTweavCNQgmZHmniMys2ETcgXDAg4ZhOBJGG89tHfOggGmwvl+WfdbZcaPsIpGa9K+p6Z7dOwvs0PITtWRE1smUAk1/d+MUuqSmcEXObCGrk5EGAicRGVsLUSq9rL1L7MLzBKC97OFWIbpoXFDLBVkJZbFuhk7azTQECWoE/7TbpPIuQIuspju6YzsNZYLVvaG965uxIgjFFUoRg==';

TypeMatcher<FreecatException> _failure(FreecatFailure failure) =>
    isA<FreecatException>().having(
      (error) => error.failure,
      'failure',
      failure,
    );

String _encryptBytes(Uint8List plaintext) {
  final cipher = CBCBlockCipher(AESEngine())
    ..init(
      true,
      ParametersWithIV<KeyParameter>(
        KeyParameter(ascii.encode('efbf326c0a946d3f')),
        ascii.encode('ed287033263d145d'),
      ),
    );
  final encrypted = Uint8List(plaintext.length);
  for (var offset = 0; offset < plaintext.length; offset += 16) {
    cipher.processBlock(plaintext, offset, encrypted, offset);
  }
  return base64.encode(encrypted);
}

String _encryptInner(String inner) {
  final bytes = ascii.encode(inner);
  final padding = 16 - bytes.length % 16;
  return _encryptBytes(
    Uint8List.fromList([...bytes, ...List.filled(padding, padding)]),
  );
}

String _encrypt(String yaml) => _encryptInner(base64.encode(utf8.encode(yaml)));

Map _normalize(String text) =>
    loadYaml(utf8.decode(normalizeFreecatSubscription(utf8.encode(text))))
        as Map;

void main() {
  group('decryptFreecatSubscription', () {
    test('matches the documented fixture byte for byte and SHA-256', () {
      final bytes = decryptFreecatSubscription(_ciphertext);
      expect(bytes, orderedEquals(utf8.encode(_fixture)));
      expect(
        sha256.convert(bytes).toString(),
        '4a621e84f860996dc4f314e6beb273b85e0c125ad3582fccd8689c05f11543be',
      );
    });

    test('accepts whitespace in both base64 layers', () {
      final inner = base64.encode(utf8.encode(_fixture));
      final spaced = _encryptInner(
        '${inner.substring(0, 24)} \n\t${inner.substring(24)}\r\n',
      );
      final outer = '${spaced.substring(0, 32)} \r\n${spaced.substring(32)}\t';
      expect(
        decryptFreecatSubscription(outer),
        orderedEquals(utf8.encode(_fixture)),
      );
    });

    test('rejects invalid outer encoding, block sizes and inner encoding', () {
      for (final input in [
        '',
        'not-base64!',
        '%41AAA',
        'AAAA',
        _ciphertext.replaceAll('+', '-'),
        _encryptInner('not base64!'),
        _encryptInner('Zh=='),
        _encryptInner(''),
      ]) {
        expect(
          () => decryptFreecatSubscription(input),
          throwsA(_failure(FreecatFailure.decryption)),
        );
      }
    });

    test(
      'checks every PKCS7 padding byte and rejects zero or oversized pad',
      () {
        for (final padding in [
          [...List.filled(15, 65), 0],
          [...List.filled(15, 65), 17],
          [...List.filled(14, 65), 1, 2],
        ]) {
          expect(
            () => decryptFreecatSubscription(
              _encryptBytes(Uint8List.fromList(padding)),
            ),
            throwsA(_failure(FreecatFailure.decryption)),
          );
        }
      },
    );
  });

  group('normalizeFreecatSubscription', () {
    test(
      'accepts short encrypted and already verified plaintext Clash YAML',
      () {
        final expected = loadYaml(_fixture);
        expect(_normalize(_fixture), expected);
        expect(_normalize(_ciphertext), expected);
        expect(_normalize(_encrypt(_fixture)), expected);
      },
    );

    test(
      'removes flow and block markers everywhere, preserving DNS and rules',
      () {
        const text = '''
proxies:
  - {name: A, type: trojan, server: 203.0.113.10, port: 443, password: test}
  - {name: '📊 剩余流量：20 GB', type: trojan}
  - name: '套餐到期: 长期有效'
    type: trojan
  - {name: '🏠 网址：https://example.com', type: trojan}
  - name: '🪧 提示：AI请使用AI名称节点'
    type: trojan
proxy-groups:
  - {name: 'Freecat 🐾自由猫', type: select, proxies: ['📊 剩余流量：20 GB', '套餐到期: 长期有效', '🏠 网址：https://example.com', '🪧 提示：AI请使用AI名称节点', A, Auto]}
  - name: Auto
    type: url-test
    proxies:
      - '🏠 网址：https://example.com'
      - A
    url: https://example.com/generate_204
    interval: 300
dns:
  enable: true
  enhanced-mode: fake-ip
  nameserver: [https://dns.example.com/dns-query]
  fallback-filter: {geosite: [gfw], ipcidr: [240.0.0.0/4]}
rules:
  - PROCESS-NAME,codex.exe,Freecat 🐾自由猫
  - PROCESS-NAME,WeChat.exe,DIRECT
  - IP-CIDR,192.0.2.0/24,DIRECT,no-resolve
  - MATCH,Freecat 🐾自由猫
''';
        final original = loadYaml(text) as Map;
        for (final input in [text, _encrypt(text)]) {
          final result = _normalize(input);
          expect((result['proxies'] as List).map((p) => p['name']), ['A']);
          final groups = result['proxy-groups'] as List;
          expect(groups[0]['name'], 'Freecat 🐾自由猫');
          expect(groups[0]['proxies'], ['A', 'Auto']);
          expect(groups[1]['proxies'], ['A']);
          expect(groups[1]['url'], 'https://example.com/generate_204');
          expect(groups[1]['interval'], 300);
          expect(result['dns'], original['dns']);
          expect(result['rules'], original['rules']);
        }
      },
    );

    test('only removes documented marker prefixes from nodes and groups', () {
      const markerNames = [
        '剩余流量：20 GB',
        '剩余流量 : 20 GB',
        '📊 剩余流量：20 GB',
        '套餐到期: 长期有效',
        '🏠网址 : https://example.test',
        '🪧 提示：AI请使用AI名称节点',
      ];
      const nodeNames = [
        '香港 提示：限速节点',
        '香港 网址：https://node.example.test',
        '🇭🇰 提示：限速节点',
        '🇭🇰 网址：https://node.example.test',
        '🐾 提示：限速节点',
        '🐾 网址：https://node.example.test',
        '📊 提示：限速节点',
        '🏠 提示：限速节点',
        '🪧 网址：https://node.example.test',
        '🏠 香港 网址：https://node.example.test',
        '🪧 香港 提示：限速节点',
        '🇭🇰 剩余流量：限速节点',
        '🐾 套餐到期：限速节点',
        '提示：限速节点',
        '网址：https://node.example.test',
        '🪧 提示节点',
        '🏠 网址节点',
      ];
      final nodes = [
        for (final name in nodeNames)
          {
            'name': name,
            'type': 'trojan',
            'server': '203.0.113.10',
            'port': 443,
            'password': 'synthetic-password',
          },
      ];
      final text = jsonEncode({
        'proxies': [
          ...nodes,
          for (final name in markerNames) {'name': name, 'type': 'trojan'},
        ],
        'proxy-groups': [
          {
            'name': 'Freecat',
            'type': 'select',
            'proxies': [...markerNames, ...nodeNames],
          },
        ],
        'rules': ['MATCH,Freecat'],
      });
      for (final input in [text, _encrypt(text)]) {
        final result = _normalize(input);
        expect(result['proxies'], nodes);
        expect((result['proxy-groups'] as List).single['proxies'], nodeNames);
      }
    });

    test('preserves node fields and official group health checks', () {
      const text = '''
proxies:
  - {name: A, type: trojan, server: node.example.test, port: 443, password: 'synthetic-password', sni: tls.example.test, udp: true, skip-cert-verify: true}
  - {name: B, type: trojan, server: 203.0.113.20, port: 8443, password: 'second-password', sni: other.example.test, udp: false, skip-cert-verify: false}
  - {name: C, type: trojan, server: 203.0.113.30, port: 443, password: 'third-password'}
proxy-groups:
  - {name: Freecat, type: select, proxies: [Auto, Failover, A, B, C]}
  - {name: Auto, type: url-test, proxies: [A, B, C], url: 'http://www.gstatic.com/generate_204', interval: 86400}
  - {name: Failover, type: fallback, proxies: [A, B, C], url: 'http://www.gstatic.com/generate_204', interval: 7200}
dns:
  enable: true
  respect-rules: true
  listen: ''
  nameserver: [https://dns.example.test/dns-query]
  proxy-server-nameserver: [https://proxy-dns.example.test/dns-query]
rules: ['MATCH,Freecat']
''';
      final original = loadYaml(text) as Map;
      for (final input in [text, _encrypt(text)]) {
        final result = _normalize(input);
        expect(result['proxies'], original['proxies']);
        expect(result['proxy-groups'], original['proxy-groups']);
        expect(result['dns'], original['dns']);
        expect(result['rules'], original['rules']);
      }
    });

    test('applies YAML merges before identifying marker names', () {
      final result = _normalize('''
base: &base {type: trojan, server: 203.0.113.10, port: 443, password: test}
proxies:
  - {<<: *base, name: A}
  - {<<: *base, name: '🏠 网址：https://example.com'}
proxy-groups:
  - {name: Freecat, type: select, proxies: [A, '🏠 网址：https://example.com']}
rules: ['MATCH,Freecat']
''');
      expect((result['proxies'] as List).single['server'], '203.0.113.10');
      expect((result['proxy-groups'] as List).single['proxies'], ['A']);
    });

    test(
      'rejects both plaintext and encrypted decoys without body leakage',
      () {
        for (final domain in [
          'freevip1.freecatnodles.com',
          'FREECATNODLES.COM',
          'freevip.example.com',
        ]) {
          final text = _fixture.replaceFirst('203.0.113.10', domain);
          for (final input in [text, _encrypt(text)]) {
            expect(
              () => _normalize(input),
              throwsA(
                _failure(FreecatFailure.decoy).having(
                  (error) => error.toString(),
                  'safe error',
                  'FreecatException(decoy)',
                ),
              ),
            );
          }
        }
      },
    );

    test('preserves builtin, logical, regex, process and no-resolve rules', () {
      const rules = [
        'PROCESS-NAME,Telegram.exe,Freecat',
        r'PROCESS-PATH,C:\Windows\app.exe,DIRECT',
        'IP-CIDR,192.0.2.0/24,Freecat,no-resolve',
        'GEOIP,CN,DIRECT,src,no-resolve',
        'AND,((NETWORK,TCP),(DOMAIN,example.com)),Freecat',
        'OR,((IP-CIDR,192.0.2.0/24,no-resolve),(NETWORK,UDP)),REJECT-DROP',
        'NOT,((NETWORK,UDP)),Freecat,no-resolve',
        'DOMAIN-REGEX,^example{1,2}\\.com,Freecat',
        'PROCESS-NAME-REGEX,app{1,2},COMPATIBLE,no-resolve',
        'PROCESS-PATH-REGEX,/opt/(foo,bar),PASS',
        'DOMAIN,direct.example,DIRECT',
        'DOMAIN,reject.example,REJECT',
        'DOMAIN,drop.example,REJECT-DROP',
        'DOMAIN,pass.example,PASS-RULE',
        'DOMAIN,global.example,GLOBAL',
        'MATCH,Freecat',
      ];
      final text = _fixture.substring(0, _fixture.indexOf('rules:'));
      final result = _normalize('$text${_ruleYaml(rules)}');
      expect(result['rules'], rules);
    });

    test('checks sub-rule targets independently from proxy targets', () {
      const suffix = '''
sub-rules:
  process:
    - PROCESS-NAME,codex.exe,Freecat
    - MATCH,DIRECT
rules:
  - SUB-RULE,(NETWORK,TCP),process
  - MATCH,Freecat
''';
      final text = _fixture.substring(0, _fixture.indexOf('rules:'));
      expect(
        _normalize('$text$suffix')['sub-rules'],
        (loadYaml(suffix) as Map)['sub-rules'],
      );
      expect(
        () => _normalize('$text${suffix.replaceFirst(',process', ',missing')}'),
        throwsA(_failure(FreecatFailure.invalidProfile)),
      );
    });

    test(
      'rejects missing group and rule targets, duplicates and empty groups',
      () {
        for (final input in [
          _fixture.replaceFirst("proxies: ['A']", "proxies: ['missing']"),
          _fixture.replaceFirst('MATCH,Freecat', 'MATCH,missing'),
          _fixture.replaceFirst(
            'MATCH,Freecat',
            'IP-CIDR,192.0.2.0/24,missing,no-resolve',
          ),
          _fixture.replaceFirst('MATCH,Freecat', 'AND,((NETWORK,TCP)),missing'),
          _fixture.replaceFirst("proxies: ['A']", 'proxies: []'),
          _fixture.replaceFirst("name: 'A'", "name: '剩余流量：0'"),
          _fixture.replaceFirst("name: 'Freecat'", "name: 'A'"),
          _fixture.replaceFirst(
            'proxies:\n',
            'proxies:\n  - {name: A, type: trojan}\n',
          ),
          _fixture.replaceFirst('type: trojan', 'type: direct'),
          _fixture.replaceFirst('server: 203.0.113.10, ', ''),
          _fixture.replaceFirst('port: 443', 'port: 0'),
        ]) {
          expect(
            () => _normalize(input),
            throwsA(_failure(FreecatFailure.invalidProfile)),
          );
        }
      },
    );

    test(
      'rejects a group emptied by removing markers without inserting DIRECT',
      () {
        final text = _fixture
            .replaceFirst(
              'proxy-groups:',
              "  - {name: '🪧 提示：test', type: trojan}\nproxy-groups:",
            )
            .replaceFirst("proxies: ['A']", "proxies: ['🪧 提示：test']");
        expect(
          () => _normalize(text),
          throwsA(_failure(FreecatFailure.invalidProfile)),
        );
      },
    );

    test(
      'keeps ciphertext failures distinct from invalid decrypted profiles',
      () {
        expect(
          () => _normalize('AAAA'),
          throwsA(_failure(FreecatFailure.decryption)),
        );
        expect(
          () => _normalize(_encrypt('private-body: [\n')),
          throwsA(
            _failure(FreecatFailure.invalidProfile).having(
              (error) => error.toString(),
              'safe error',
              isNot(contains('private-body')),
            ),
          ),
        );
        expect(
          () => normalizeFreecatSubscription(Uint8List.fromList([255])),
          throwsA(_failure(FreecatFailure.invalidProfile)),
        );
      },
    );
  });
}

String _ruleYaml(List<String> rules) =>
    'rules:\n${rules.map((rule) => '  - ${jsonEncode(rule)}\n').join()}';
