import 'dart:convert';
import 'dart:io';

import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/features/freecat/client.dart';
import 'package:fl_clash/features/freecat/errors.dart';
import 'package:fl_clash/features/freecat/service.dart';
import 'package:fl_clash/features/freecat/store.dart';
import 'package:fl_clash/models/profile.dart';
import 'package:fl_clash/state.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/app_paths.dart';

const _yaml = '''
proxies:
  - {name: A, type: trojan, server: 203.0.113.10, port: 443, password: test}
  - {name: '剩余流量：10 GB', type: trojan, server: 203.0.113.10, port: 443, password: test}
proxy-groups:
  - {name: Freecat, type: select, proxies: [A, '剩余流量：10 GB']}
rules: ['MATCH,Freecat']
''';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory directory;
  HttpOverrides? previousHttpOverrides;
  late HttpServer server;
  late String host;
  late FreecatService service;
  const store = FreecatAccountStore();
  final requests = <String>[];
  var expired = false;
  var decoy = false;
  var token = 'account-one';

  Future<String?> validate(String path, String key) async => null;

  const profile = Profile(
    id: 123,
    type: ProfileType.freecat,
    label: 'FreeCat',
    autoUpdateDuration: Duration(hours: 24),
    selectedMap: {'Freecat': 'A'},
  );

  setUp(() async {
    previousHttpOverrides = HttpOverrides.current;
    HttpOverrides.global = null;
    final container = ProviderContainer();
    addTearDown(container.dispose);
    globalState.container = container;
    globalState.packageInfo = PackageInfo(
      appName: 'FlClash',
      packageName: 'com.follow.clash.test',
      version: '0.0.0',
      buildNumber: '0',
    );
    FlutterSecureStorage.setMockInitialValues({});
    directory = await Directory.systemTemp.createTemp('freecat-service-');
    await useAppPaths(directory);
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    host = 'http://127.0.0.1:${server.port}';
    expired = false;
    decoy = false;
    token = 'account-one';
    requests.clear();
    server.listen((request) async {
      requests.add(request.uri.path);
      if (request.uri.path.endsWith('/login')) {
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({
            'data': {'auth_data': token},
          }),
        );
      } else if (request.uri.path.endsWith('/getSubscribe')) {
        if (expired) {
          request.response.statusCode = 403;
        } else {
          request.response.headers.contentType = ContentType.json;
          request.response.write(
            jsonEncode({
              'data': {
                'subscribe_url': '$host/subscription?token=$token',
                'u': 10,
                'd': 20,
                'transfer_enable': 100,
                'expired_at': null,
              },
            }),
          );
        }
      } else {
        request.response.headers.set('profile-update-interval', '12');
        request.response.write(
          decoy
              ? _yaml.replaceAll('203.0.113.10', 'freevip.freecatnodles.com')
              : _yaml,
        );
      }
      await request.response.close();
    });
    service = FreecatService(createClient: FreecatClient.new);
  });

  tearDown(() async {
    HttpOverrides.global = previousHttpOverrides;
    await server.close(force: true);
    await directory.delete(recursive: true);
  });

  Future<Profile> signIn({Profile input = profile}) => service.signIn(
    input,
    host: host,
    email: 'test@example.com',
    password: 'runtime-only-password',
    validate: validate,
  );

  test(
    'imports normalized YAML and updates through the account source',
    () async {
      final imported = await signIn();
      expect(imported.url, isEmpty);
      expect(imported.realAutoUpdate, isTrue);
      expect(imported.autoUpdateDuration, const Duration(hours: 12));
      expect(
        imported.subscriptionInfo,
        const SubscriptionInfo(upload: 10, download: 20, total: 100),
      );
      expect(
        await (await imported.file).readAsString(),
        isNot(contains('剩余流量')),
      );
      expect((await store.read(profile.id))?.token, 'account-one');
      requests.clear();
      final updated = await service.update(imported, validate: validate);
      expect(requests, ['/api/v1/user/getSubscribe', '/subscription']);
      expect(updated.selectedMap, {'Freecat': 'A'});
      expect(updated.toJson().toString(), isNot(contains('account-one')));
      expect(
        updated.toJson().toString(),
        isNot(contains('runtime-only-password')),
      );
    },
  );

  test('successful sign-in replaces a malformed saved account', () async {
    FlutterSecureStorage.setMockInitialValues({
      'flclash.freecat.account.${profile.id}': 'invalid-json',
    });
    await expectLater(
      service.readAccount(profile.id),
      throwsA(
        isA<FreecatException>().having(
          (e) => e.failure,
          'failure',
          FreecatFailure.storage,
        ),
      ),
    );
    final imported = await signIn();
    expect((await service.readAccount(profile.id))?.email, 'test@example.com');
    expect(
      await (await imported.file).readAsString(),
      contains('203.0.113.10'),
    );
  });

  test(
    'ordinary URL profiles retain their existing download behavior',
    () async {
      final ordinary = Profile.normal(
        label: 'ordinary',
        url: '$host/ordinary.yaml',
      );
      final updated = await ordinary.update(validate: validate);
      expect(updated.type, ProfileType.url);
      expect(updated.url, ordinary.url);
      expect(await (await updated.file).readAsString(), _yaml);
      expect(await store.read(updated.id), isNull);
      expect(requests, ['/ordinary.yaml']);
    },
  );

  test(
    'expired authentication and decoys leave the previous file usable',
    () async {
      final imported = await signIn();
      final original = await (await imported.file).readAsBytes();
      expired = true;
      await expectLater(
        service.update(imported, validate: validate),
        throwsA(
          isA<FreecatException>().having(
            (e) => e.failure,
            'failure',
            FreecatFailure.expired,
          ),
        ),
      );
      expired = false;
      decoy = true;
      await expectLater(
        service.update(imported, validate: validate),
        throwsA(
          isA<FreecatException>().having(
            (e) => e.failure,
            'failure',
            FreecatFailure.decoy,
          ),
        ),
      );
      expect(await (await imported.file).readAsBytes(), original);
      expect((await store.read(profile.id))?.token, 'account-one');
    },
  );

  test(
    'rejected replacement rolls back the account and preserves configuration',
    () async {
      final imported = await signIn();
      final original = await (await imported.file).readAsBytes();
      token = 'account-two';
      await expectLater(
        service.signIn(
          imported,
          host: host,
          email: 'second@example.com',
          password: 'second-password',
          validate: (_, _) async => 'invalid secret server password',
        ),
        throwsA(isA<FreecatException>()),
      );
      expect((await store.read(profile.id))?.token, 'account-one');
      expect(await (await imported.file).readAsBytes(), original);
      final switched = await signIn(input: imported);
      expect(switched.id, profile.id);
      expect((await store.read(profile.id))?.token, 'account-two');
      await service.removeAccount(profile.id);
      expect(await service.readAccount(profile.id), isNull);
      await expectLater(
        service.update(switched, validate: validate),
        throwsA(
          isA<FreecatException>().having(
            (e) => e.failure,
            'failure',
            FreecatFailure.expired,
          ),
        ),
      );
    },
  );
}
