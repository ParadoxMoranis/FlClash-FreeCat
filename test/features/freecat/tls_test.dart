import 'package:fl_clash/common/task.dart';
import 'package:fl_clash/features/freecat/tls.dart';
import 'package:fl_clash/models/models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yaml/yaml.dart';

void main() {
  test(
    'only standard Trojan nodes without a fingerprint receive compatibility',
    () {
      final nodes = <Map<String, dynamic>>[
        {
          'name': 'plain',
          'type': 'trojan',
          'server': '203.0.113.1',
          'sni': 'example.com',
          'password': 'test',
          'skip-cert-verify': false,
        },
        {'name': 'explicit', 'type': 'trojan', 'client-fingerprint': 'firefox'},
        {'name': 'none', 'type': 'trojan', 'client-fingerprint': 'none'},
        {'name': 'empty', 'type': 'trojan', 'client-fingerprint': ''},
        {'name': 'ws', 'type': 'trojan', 'network': 'ws'},
        {'name': 'other', 'type': 'vless'},
      ];
      final input = <String, dynamic>{
        'proxies': nodes,
        'dns': {'respect-rules': true},
        'rules': ['MATCH,DIRECT'],
      };
      final result = withFreecatTlsCompatibility(input);
      final output = result['proxies'] as List;
      expect(output.first, {...nodes.first, 'client-fingerprint': 'chrome120'});
      expect(output.skip(1), nodes.skip(1));
      expect(nodes.first.containsKey('client-fingerprint'), isFalse);
      expect(result['dns'], input['dns']);
      expect(result['rules'], input['rules']);
      expect(withFreecatTlsCompatibility(result), result);
    },
  );

  test(
    'the final runtime config applies compatibility only for the selected source',
    () async {
      final raw = <String, dynamic>{
        'proxies': [
          {
            'name': 'A',
            'type': 'trojan',
            'server': '203.0.113.1',
            'port': 443,
            'password': 'test',
            'sni': 'example.com',
            'skip-cert-verify': true,
          },
        ],
        'dns': {
          'enable': true,
          'respect-rules': true,
          'nameserver': ['1.1.1.1'],
          'proxy-server-nameserver': ['https://dns.example/dns-query'],
        },
        'rules': ['MATCH,DIRECT'],
      };
      final input = MakeRealProfileState(
        profilesPath: '/tmp/freecat-tls-test',
        profileId: 1,
        rawConfig: raw,
        realPatchConfig: const PatchClashConfig(),
        freecatTlsCompatibility: true,
        appendSystemDns: false,
        proxyGroups: const [],
        rules: const [],
        addedRules: const [],
        defaultUA: 'test',
      );
      final freecat = loadYaml((await makeRealProfileTask(input)).yaml) as Map;
      final ordinary =
          loadYaml(
                (await makeRealProfileTask(
                  input.copyWith(freecatTlsCompatibility: false),
                )).yaml,
              )
              as Map;
      expect(freecat['proxies'][0]['client-fingerprint'], 'chrome120');
      expect(ordinary['proxies'][0].containsKey('client-fingerprint'), isFalse);
      expect(freecat['proxies'][0]['server'], '203.0.113.1');
      expect(freecat['proxies'][0]['sni'], 'example.com');
      expect(freecat['dns'], raw['dns']);
      expect(freecat['rules'], raw['rules']);
      expect(raw['proxies'][0].containsKey('client-fingerprint'), isFalse);
    },
  );
}
