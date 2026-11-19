import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:fl_clash/features/freecat/client.dart';
import 'package:fl_clash/features/freecat/errors.dart';
import 'package:mocktail/mocktail.dart';
import 'package:test/test.dart';

TypeMatcher<FreecatException> _failure(FreecatFailure failure, [int? status]) =>
    isA<FreecatException>()
        .having((error) => error.failure, 'failure', failure)
        .having((error) => error.statusCode, 'statusCode', status);

class _Adapter implements HttpClientAdapter {
  final FutureOr<ResponseBody> Function(RequestOptions options) respond;
  bool closed = false;

  _Adapter(this.respond);

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async => respond(options);

  @override
  void close({bool force = false}) => closed = true;
}

class _Transport extends Fake implements HttpClient {
  @override
  Duration? connectionTimeout;

  @override
  String Function(Uri)? findProxy;

  bool Function(X509Certificate, String, int)? certificateCheck;

  @override
  set badCertificateCallback(
    bool Function(X509Certificate, String, int)? callback,
  ) => certificateCheck = callback;

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async =>
      throw const SocketException('private network message');

  @override
  void close({bool force = false}) {}
}

class _Certificate extends Fake implements X509Certificate {}

class _Received {
  final String method;
  final Uri uri;
  final HttpHeaders headers;
  final String body;

  _Received(this.method, this.uri, this.headers, this.body);
}

Future<HttpServer> _server(
  FutureOr<void> Function(HttpRequest request) respond,
) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  addTearDown(() => server.close(force: true));
  server.listen((request) async {
    try {
      await respond(request);
    } finally {
      await request.response.close();
    }
  });
  return server;
}

String _host(HttpServer server) => 'http://127.0.0.1:${server.port}';

FreecatClient _localClient() {
  final dio = Dio()
    ..httpClientAdapter = IOHttpClientAdapter(
      createHttpClient: () => HttpClient()..findProxy = ((_) => 'DIRECT'),
    );
  final client = FreecatClient(dio: dio);
  addTearDown(client.close);
  return client;
}

FreecatClient _adaptedClient(_Adapter adapter) {
  final client = FreecatClient(dio: Dio()..httpClientAdapter = adapter);
  addTearDown(client.close);
  return client;
}

ResponseBody _json(Object data, [int status = 200]) =>
    ResponseBody.fromString(jsonEncode(data), status);

void main() {
  setUp(() {
    final overrides = HttpOverrides.current;
    HttpOverrides.global = null;
    addTearDown(() => HttpOverrides.global = overrides);
  });

  group('FreecatClient login', () {
    test(
      'posts an exact form and panel UA, using auth_data before token',
      () async {
        final received = <_Received>[];
        final server = await _server((request) async {
          received.add(
            _Received(
              request.method,
              request.uri,
              request.headers,
              await utf8.decoder.bind(request).join(),
            ),
          );
          request.response.write(
            jsonEncode({
              'data': {'auth_data': 'jwt-token', 'token': 'fallback-token'},
            }),
          );
        });
        final host = _host(server);
        final result = await _localClient().login(
          host: '$host/panel///',
          email: 'a+b@example.test',
          password: 'p &=+雪',
        );
        expect(result, (host: '$host/panel', token: 'jwt-token'));
        expect(received, hasLength(1));
        final request = received.single;
        expect(request.method, 'POST');
        expect(request.uri.path, '/panel/api/v1/passport/auth/login');
        expect(
          request.headers.contentType?.mimeType,
          'application/x-www-form-urlencoded',
        );
        expect(Uri.splitQueryString(request.body), {
          'email': 'a+b@example.test',
          'password': 'p &=+雪',
        });
        expect(
          request.headers.value(HttpHeaders.userAgentHeader),
          'ziyoumao/v3.1.0 clash-verge Platform/windows',
        );
        expect(
          request.headers.value(HttpHeaders.acceptHeader),
          'application/json',
        );
        expect(request.headers.value(HttpHeaders.authorizationHeader), isNull);
      },
    );

    test(
      'falls back to token only when auth_data is absent or empty',
      () async {
        for (final auth in [null, '', '  ']) {
          final client = _adaptedClient(
            _Adapter(
              (_) => _json({
                'data': {'auth_data': auth, 'token': 'plain-token'},
              }),
            ),
          );
          expect(
            (await client.login(
              host: 'https://panel.example',
              email: 'test@example.test',
              password: 'private-password',
            )).token,
            'plain-token',
          );
        }
      },
    );

    test(
      'tries exactly the documented default hosts in order on network failure',
      () async {
        final hosts = <String>[];
        final client = _adaptedClient(
          _Adapter((options) {
            hosts.add(options.uri.origin);
            expect(options.connectTimeout, const Duration(seconds: 20));
            expect(options.sendTimeout, const Duration(seconds: 20));
            expect(options.receiveTimeout, const Duration(seconds: 20));
            if (hosts.length < 3) {
              throw DioException.connectionError(
                requestOptions: options,
                reason: 'private-password',
              );
            }
            return _json({
              'data': {'token': 'last-host-token'},
            });
          }),
        );
        final result = await client.login(
          email: 'test',
          password: 'private-password',
        );
        expect(hosts, [
          'https://tccdnclient.miaowuppaa.com',
          'https://115.159.221.23',
          'https://tuc.skyoutdoors.com.cn',
        ]);
        expect(result.host, hosts.last);
        expect(result.token, 'last-host-token');
      },
    );

    test('never sends custom-host credentials to a fallback host', () async {
      final urls = <Uri>[];
      final client = _adaptedClient(
        _Adapter((options) {
          urls.add(options.uri);
          throw DioException.connectionError(
            requestOptions: options,
            reason: 'private-password',
          );
        }),
      );
      await expectLater(
        client.login(
          host: 'https://custom.example',
          email: 'test',
          password: 'private-password',
        ),
        throwsA(_failure(FreecatFailure.network)),
      );
      expect(urls.map((uri) => uri.host), ['custom.example']);
    });

    for (final status in [401, 422, 500, 302]) {
      test(
        'handles login HTTP $status without fallback or secret leakage',
        () async {
          var requests = 0;
          final client = _adaptedClient(
            _Adapter((_) {
              requests++;
              return _json({
                'message': 'secret-email secret-password secret-token',
              }, status);
            }),
          );
          await expectLater(
            client.login(email: 'secret-email', password: 'secret-password'),
            throwsA(
              _failure(
                status == 401 || status == 422
                    ? FreecatFailure.credentials
                    : FreecatFailure.http,
                status,
              ).having(
                (error) => error.toString(),
                'safe error',
                isNot(contains('secret')),
              ),
            ),
          );
          expect(requests, 1);
        },
      );
    }

    test(
      'rejects malformed and missing-token login responses safely',
      () async {
        for (final response in [
          'private-password not json',
          '[]',
          '{}',
          '{"data":{}}',
          '{"data":{"auth_data":42}}',
          '{"data":{"token":"line\\r\\nprivate-password"}}',
        ]) {
          final client = _adaptedClient(
            _Adapter((_) => ResponseBody.fromString(response, 200)),
          );
          await expectLater(
            client.login(
              host: 'https://panel.example',
              email: 'test',
              password: 'private-password',
            ),
            throwsA(
              _failure(FreecatFailure.invalidResponse).having(
                (error) => error.toString(),
                'safe error',
                'FreecatException(invalidResponse)',
              ),
            ),
          );
        }
      },
    );
  });

  group('FreecatClient getSubscribe', () {
    test(
      'sends a bare token and handles both URL spellings and numeric strings',
      () async {
        final requests = <_Received>[];
        var camelCase = false;
        late HttpServer server;
        server = await _server((request) async {
          requests.add(
            _Received(request.method, request.uri, request.headers, ''),
          );
          request.response.write(
            jsonEncode({
              'data': {
                if (camelCase)
                  'subscribeUrl': '${_host(server)}/subscribe?token=sub-secret'
                else
                  'subscribe_url':
                      '${_host(server)}/subscribe?token=sub-secret',
                'u': camelCase ? 10 : '10',
                'd': camelCase ? '20' : 20,
                'transfer_enable': '100',
                'expired_at': camelCase ? '1234567890' : null,
                'plan': {'name': 'Test plan'},
              },
            }),
          );
        });
        final client = _localClient();
        for (final camel in [false, true]) {
          camelCase = camel;
          final result = await client.getSubscribe(
            '${_host(server)}/',
            'bare-secret',
          );
          expect(result.url, '${_host(server)}/subscribe?token=sub-secret');
          expect(result.upload, 10);
          expect(result.download, 20);
          expect(result.total, 100);
          expect(result.expire, camel ? 1234567890 : 0);
          expect(result.plan, 'Test plan');
        }
        expect(requests, hasLength(2));
        for (final request in requests) {
          expect(request.method, 'GET');
          expect(request.uri.path, '/api/v1/user/getSubscribe');
          expect(
            request.headers.value(HttpHeaders.authorizationHeader),
            'bare-secret',
          );
          expect(
            request.headers.value(HttpHeaders.acceptHeader),
            'application/json',
          );
          expect(
            request.headers.value(HttpHeaders.userAgentHeader),
            'ziyoumao/v3.1.0 clash-verge Platform/windows',
          );
        }
      },
    );

    for (final status in [401, 403]) {
      test('reports HTTP $status as expired, discarding server body', () async {
        final server = await _server((request) {
          request.response.statusCode = status;
          request.response.write('private-token private-password');
        });
        await expectLater(
          _localClient().getSubscribe(_host(server), 'private-token'),
          throwsA(
            _failure(FreecatFailure.expired, status).having(
              (error) => error.toString(),
              'safe error',
              'FreecatException(expired, $status)',
            ),
          ),
        );
      });
    }

    test('rejects missing URLs and malformed accounting values', () async {
      for (final data in [
        <String, Object?>{},
        {'subscribe_url': 'https://sub.example/?token=secret', 'u': 'NaN'},
        {'subscribe_url': 'https://sub.example/?token=secret', 'd': -1},
        {
          'subscribe_url': 'https://sub.example/?token=secret',
          'transfer_enable': 1.5,
        },
      ]) {
        final client = _adaptedClient(_Adapter((_) => _json({'data': data})));
        await expectLater(
          client.getSubscribe('https://panel.example', 'bare-secret'),
          throwsA(_failure(FreecatFailure.invalidResponse)),
        );
      }
    });
  });

  group('FreecatClient fetchSubscription', () {
    test(
      'keeps raw bytes and query, official UA and headers without authorization',
      () async {
        final requests = <_Received>[];
        final bytes = [0, 255, 128, 13, 10, 65];
        final server = await _server((request) {
          requests.add(
            _Received(request.method, request.uri, request.headers, ''),
          );
          request.response.headers.set(
            'subscription-userinfo',
            'upload=1; download=2; total=3; expire=',
          );
          request.response.headers.set('profile-update-interval', '24');
          request.response.add(bytes);
        });
        final dio =
            Dio(BaseOptions(headers: {'Authorization': 'must-not-leak'}))
              ..httpClientAdapter = IOHttpClientAdapter(
                createHttpClient: () =>
                    HttpClient()..findProxy = ((_) => 'DIRECT'),
              );
        final client = FreecatClient(dio: dio);
        addTearDown(client.close);
        const query = 'token=a%2Bb%2Fc%3D&x=1&x=2&flag=meta';
        final result = await client.fetchSubscription(
          '${_host(server)}/sub?$query',
        );
        expect(result.bytes, orderedEquals(bytes));
        expect(result.userinfo, 'upload=1; download=2; total=3; expire=');
        expect(result.updateInterval, const Duration(hours: 24));
        expect(requests, hasLength(1));
        final request = requests.single;
        expect(request.uri.query, query);
        expect(request.headers.value(HttpHeaders.authorizationHeader), isNull);
        expect(request.headers.value(HttpHeaders.acceptHeader), '*/*');
        expect(
          request.headers.value(HttpHeaders.userAgentHeader),
          'freecatencua/v3.2.0 clash-verge Platform/windows',
        );
      },
    );

    test(
      'follows validated subscription redirects with official UA and no token header',
      () async {
        final requests = <_Received>[];
        final target = await _server((request) {
          requests.add(
            _Received(request.method, request.uri, request.headers, ''),
          );
          request.response.write('encrypted-body');
        });
        final source = await _server((request) {
          request.response.statusCode = 302;
          request.response.headers.set(
            HttpHeaders.locationHeader,
            '${_host(target)}/final?token=a%2Bb',
          );
        });
        final result = await _localClient().fetchSubscription(
          '${_host(source)}/first',
        );
        expect(utf8.decode(result.bytes), 'encrypted-body');
        expect(requests, hasLength(1));
        expect(requests.single.uri.query, 'token=a%2Bb');
        expect(
          requests.single.headers.value(HttpHeaders.authorizationHeader),
          isNull,
        );
        expect(
          requests.single.headers.value(HttpHeaders.userAgentHeader),
          'freecatencua/v3.2.0 clash-verge Platform/windows',
        );
      },
    );

    test('rejects redirect decoy URLs and limits redirect loops', () async {
      var requests = 0;
      var location = '/sub?flag=clash';
      final server = await _server((request) {
        requests++;
        request.response.statusCode = 302;
        request.response.headers.set(HttpHeaders.locationHeader, location);
      });
      final client = _localClient();
      await expectLater(
        client.fetchSubscription('${_host(server)}/sub'),
        throwsA(_failure(FreecatFailure.invalidHost)),
      );
      expect(requests, 1);
      location = '/loop';
      requests = 0;
      await expectLater(
        client.fetchSubscription('${_host(server)}/loop'),
        throwsA(_failure(FreecatFailure.http, 302)),
      );
      expect(requests, 6);
    });

    test(
      'treats absent or malformed optional update headers as absent',
      () async {
        for (final interval in [
          null,
          '',
          '0',
          '-1',
          'bad',
          '99999999999999999999999',
        ]) {
          final client = _adaptedClient(
            _Adapter(
              (_) => ResponseBody.fromString(
                'body',
                200,
                headers: {
                  if (interval != null) 'profile-update-interval': [interval],
                },
              ),
            ),
          );
          final result = await client.fetchSubscription(
            'https://sub.example/?token=secret',
          );
          expect(result.userinfo, isNull);
          expect(result.updateInterval, isNull);
          expect(utf8.decode(result.bytes), 'body');
        }
      },
    );

    test(
      'discards empty responses and maps HTTP and transport failures safely',
      () async {
        final empty = _adaptedClient(
          _Adapter((_) => ResponseBody.fromString('', 200)),
        );
        await expectLater(
          empty.fetchSubscription('https://sub.example/?token=private-token'),
          throwsA(_failure(FreecatFailure.invalidResponse)),
        );
        final server = await _server((request) {
          request.response.statusCode = 403;
          request.response.write('private-token');
        });
        await expectLater(
          _localClient().fetchSubscription(
            '${_host(server)}/?token=private-token',
          ),
          throwsA(_failure(FreecatFailure.expired, 403)),
        );
        for (final type in [
          DioExceptionType.connectionTimeout,
          DioExceptionType.receiveTimeout,
          DioExceptionType.sendTimeout,
          DioExceptionType.connectionError,
          DioExceptionType.badCertificate,
        ]) {
          final client = _adaptedClient(
            _Adapter((options) {
              throw DioException(
                requestOptions: options,
                type: type,
                message: 'private-token',
                error: 'private-password',
              );
            }),
          );
          await expectLater(
            client.fetchSubscription(
              'https://sub.example/?token=private-token',
            ),
            throwsA(
              _failure(FreecatFailure.network).having(
                (error) => error.toString(),
                'safe error',
                'FreecatException(network)',
              ),
            ),
          );
        }
      },
    );
  });

  test(
    'validates hosts and subscription URLs before sending any request',
    () async {
      var requests = 0;
      final client = _adaptedClient(
        _Adapter((_) {
          requests++;
          return _json({
            'data': {'token': 'unexpected'},
          });
        }),
      );
      for (final host in [
        '',
        'panel.example',
        '//panel.example',
        'ftp://panel.example',
        'http://panel.example',
        'https://user:pass@panel.example',
        'https://@panel.example',
        'https://panel.example?token=secret',
        'https://panel.example#fragment',
        'https://panel.example:0',
        'https://panel.example:65536',
        'https://panel.example/ bad',
      ]) {
        await expectLater(
          client.login(
            host: host,
            email: 'private-email',
            password: 'private-password',
          ),
          throwsA(_failure(FreecatFailure.invalidHost)),
        );
      }
      for (final url in [
        'file:///tmp/private',
        'http://remote.example/sub',
        'https://user:pass@sub.example/sub',
        'https://sub.example/sub#secret',
        'https://sub.example/sub?token=secret&flag=clash',
        'https://sub.example/sub?%66lag=%63lash',
        'https://sub.example/sub?flag=meta&flag=clash',
      ]) {
        await expectLater(
          client.fetchSubscription(url),
          throwsA(_failure(FreecatFailure.invalidHost)),
        );
      }
      expect(requests, 0);
    },
  );

  test(
    'default transport overrides global proxy and insecure certificate settings',
    () async {
      final transport = _Transport()
        ..findProxy = ((_) => 'PROXY private-proxy:1234')
        ..badCertificateCallback = ((_, _, _) => true);
      await HttpOverrides.runZoned(() async {
        final client = FreecatClient();
        try {
          await expectLater(
            client.fetchSubscription(
              'https://sub.example/?token=private-token',
            ),
            throwsA(_failure(FreecatFailure.network)),
          );
        } finally {
          client.close();
        }
      }, createHttpClient: (_) => transport);
      expect(transport.findProxy!(Uri.parse('https://example.com')), 'DIRECT');
      expect(
        transport.certificateCheck!(_Certificate(), 'example.com', 443),
        isFalse,
      );
      expect(transport.connectionTimeout, const Duration(seconds: 20));
    },
  );

  test('close releases the injected transport', () {
    final adapter = _Adapter((_) => _json({}));
    FreecatClient(dio: Dio()..httpClientAdapter = adapter).close();
    expect(adapter.closed, isTrue);
  });
}
