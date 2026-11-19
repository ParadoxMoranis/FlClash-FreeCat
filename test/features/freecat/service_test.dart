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

class _FailingStore extends FreecatAccountStore {
  bool failWrites = false;

  @override
  Future<void> write(int profileId, FreecatAccount account) {
    if (failWrites) {
      throw const FreecatException(FreecatFailure.storage);
    }
    return super.write(profileId, account);
  }
}

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
  String? subscriptionUrl;
  String? userinfo;
  var updateInterval = '12';

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
    subscriptionUrl = null;
    userinfo = null;
    updateInterval = '12';
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
                'subscribe_url':
                    subscriptionUrl ?? '$host/subscription?token=$token',
                'u': 10,
                'd': 20,
                'transfer_enable': 100,
                'expired_at': null,
              },
            }),
          );
        }
      } else {
        request.response.headers.set('profile-update-interval', updateInterval);
        if (userinfo != null) {
          request.response.headers.set('subscription-userinfo', userinfo!);
        }
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

  test('follows refreshed subscription frontends safely', () async {
    final imported = await signIn();
    final frontend = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => frontend.close(force: true));
    final received = <Uri>[];
    frontend.listen((request) async {
      received.add(request.uri);
      expect(request.headers.value(HttpHeaders.authorizationHeader), isNull);
      expect(
        request.headers.value(HttpHeaders.userAgentHeader),
        FreecatClient.subscriptionUserAgent,
      );
      request.response.write(_yaml);
      await request.response.close();
    });
    subscriptionUrl =
        'http://127.0.0.1:${frontend.port}/rotated?token=synthetic%2Btoken';
    requests.clear();
    final updated = await service.update(imported, validate: validate);
    expect(requests, ['/api/v1/user/getSubscribe']);
    expect(received.single.path, '/rotated');
    expect(received.single.query, 'token=synthetic%2Btoken');
    final account = await store.read(profile.id);
    expect(account?.host, host);
    expect(account?.token, 'account-one');
    expect(account?.subscribeUrl, subscriptionUrl);
    expect(updated.url, isEmpty);
    expect(updated.toJson().toString(), isNot(contains('synthetic')));
  });

  test('uses a daily interval when the server header is invalid', () async {
    updateInterval = 'invalid';
    final imported = await signIn();
    expect(imported.autoUpdateDuration, const Duration(hours: 24));
  });

  test(
    'refresh preserves user intervals and uses response accounting',
    () async {
      final imported = await signIn();
      final customized = imported.copyWith(
        autoUpdateDuration: const Duration(hours: 6),
        autoUpdate: false,
      );
      updateInterval = '48';
      userinfo = 'upload=30; download=40; total=200; expire=1234567890';
      final updated = await service.update(customized, validate: validate);
      expect(updated.autoUpdateDuration, const Duration(hours: 6));
      expect(updated.autoUpdate, isFalse);
      expect(
        updated.subscriptionInfo,
        const SubscriptionInfo(
          upload: 30,
          download: 40,
          total: 200,
          expire: 1234567890,
        ),
      );
    },
  );

  test(
    'failed secure writes preserve the last usable account and file',
    () async {
      final failingStore = _FailingStore();
      service = FreecatService(store: failingStore);
      final imported = await signIn();
      final original = await (await imported.file).readAsBytes();
      final saved = await store.snapshot(profile.id);
      failingStore.failWrites = true;
      token = 'account-two';
      await expectLater(
        signIn(input: imported),
        throwsA(
          isA<FreecatException>().having(
            (error) => error.failure,
            'failure',
            FreecatFailure.storage,
          ),
        ),
      );
      expect(await store.snapshot(profile.id), saved);
      expect(await (await imported.file).readAsBytes(), original);
      failingStore.failWrites = false;
      final recovered = await signIn(input: imported);
      expect((await service.readAccount(recovered.id))?.token, 'account-two');
    },
  );

  test(
    'failed file replacement restores the previous account snapshot',
    () async {
      final imported = await signIn();
      final target = await imported.file;
      final original = await target.readAsBytes();
      final saved = await store.snapshot(profile.id);
      final backup = File('${target.path}.previous');
      token = 'account-two';
      await expectLater(
        service.signIn(
          imported,
          host: host,
          email: 'second@example.test',
          password: 'synthetic-password',
          validate: (_, _) async {
            await target.rename(backup.path);
            await Directory(target.path).create();
            return null;
          },
        ),
        throwsA(isA<FileSystemException>()),
      );
      expect(await store.snapshot(profile.id), saved);
      await Directory(target.path).delete();
      await backup.rename(target.path);
      expect(await target.readAsBytes(), original);
      final recovered = await service.update(imported, validate: validate);
      expect(recovered.selectedMap, imported.selectedMap);
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
      decoy = false;
      final recovered = await service.update(imported, validate: validate);
      expect(recovered.selectedMap, imported.selectedMap);
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
