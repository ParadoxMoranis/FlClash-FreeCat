import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';

import 'errors.dart';

class FreecatSubscription {
  final String url;
  final int upload;
  final int download;
  final int total;
  final int expire;
  final String? plan;

  const FreecatSubscription({
    required this.url,
    required this.upload,
    required this.download,
    required this.total,
    required this.expire,
    this.plan,
  });
}

class FreecatResponse {
  final Uint8List bytes;
  final String? userinfo;
  final Duration? updateInterval;

  const FreecatResponse({
    required this.bytes,
    this.userinfo,
    this.updateInterval,
  });
}

class FreecatClient {
  static const defaultHosts = [
    'https://tccdnclient.miaowupaa.com',
    'https://115.159.221.23',
    'https://tuc.skyoutdoors.com.cn',
  ];
  static const _panelUserAgent = 'ziyoumao/v3.1.0 clash-verge Platform/windows';
  static const subscriptionUserAgent =
      'freecatencua/v3.2.0 clash-verge Platform/windows';
  static const _timeout = Duration(seconds: 20);

  final Dio _dio;

  FreecatClient({Dio? dio}) : _dio = dio ?? _createDio();

  static Dio _createDio() => Dio()
    ..httpClientAdapter = IOHttpClientAdapter(
      createHttpClient: () {
        final client = HttpClient()
          ..findProxy = ((_) => 'DIRECT')
          ..badCertificateCallback = ((_, _, _) => false)
          ..connectionTimeout = _timeout;
        return client;
      },
    );

  Future<({String host, String token})> login({
    String? host,
    required String email,
    required String password,
  }) async {
    final hosts = host == null ? defaultHosts : [_panelHost(host)];
    for (var index = 0; index < hosts.length; index++) {
      final current = hosts[index];
      try {
        final response = await _request(
          '$current/api/v1/passport/auth/login',
          method: 'POST',
          data: {'email': email, 'password': password},
          login: true,
        );
        final data = _panelData(response.data);
        final token = _nonEmpty(data['auth_data']) ?? _nonEmpty(data['token']);
        if (token == null || _hasControlCharacters(token)) {
          throw const FreecatException(FreecatFailure.invalidResponse);
        }
        return (host: current, token: token);
      } on FreecatException catch (error) {
        if (error.failure != FreecatFailure.network ||
            index == hosts.length - 1) {
          rethrow;
        }
      }
    }
    throw const FreecatException(FreecatFailure.network);
  }

  Future<FreecatSubscription> getSubscribe(String host, String token) async {
    final panel = _panelHost(host);
    if (token.trim().isEmpty || _hasControlCharacters(token)) {
      throw const FreecatException(FreecatFailure.expired);
    }
    final response = await _request(
      '$panel/api/v1/user/getSubscribe',
      token: token,
    );
    try {
      final data = _panelData(response.data);
      final url =
          _nonEmpty(data['subscribe_url']) ?? _nonEmpty(data['subscribeUrl']);
      if (url == null) {
        throw const FreecatException(FreecatFailure.invalidResponse);
      }
      _subscriptionUri(url);
      final plan = data['plan'];
      return FreecatSubscription(
        url: url,
        upload: _number(data['u']),
        download: _number(data['d']),
        total: _number(data['transfer_enable']),
        expire: _number(data['expired_at']),
        plan: _nonEmpty(plan is Map ? plan['name'] : plan),
      );
    } on FreecatException {
      rethrow;
    } catch (_) {
      throw const FreecatException(FreecatFailure.invalidResponse);
    }
  }

  Future<FreecatResponse> fetchSubscription(String url) async {
    var current = url;
    var uri = _subscriptionUri(current);
    var response = await _request(current, subscription: true);
    for (
      var count = 0;
      _redirectStatuses.contains(response.statusCode);
      count++
    ) {
      final location =
          response.headers[HttpHeaders.locationHeader]?.firstOrNull;
      if (count >= 5 || location == null) {
        throw FreecatException(
          FreecatFailure.http,
          statusCode: response.statusCode,
        );
      }
      try {
        current = uri.resolve(location).toString();
        uri = _subscriptionUri(current);
      } on FreecatException {
        rethrow;
      } catch (_) {
        throw const FreecatException(FreecatFailure.invalidHost);
      }
      response = await _request(current, subscription: true);
    }
    final bytes = response.data;
    if (bytes == null || bytes.isEmpty) {
      throw const FreecatException(FreecatFailure.invalidResponse);
    }
    final userinfo = response.headers['subscription-userinfo']?.join('; ');
    final interval = response.headers['profile-update-interval']?.firstOrNull;
    final hours = interval == null ? null : int.tryParse(interval.trim());
    return FreecatResponse(
      bytes: bytes is Uint8List ? bytes : Uint8List.fromList(bytes),
      userinfo: userinfo,
      updateInterval:
          hours != null &&
              hours > 0 &&
              hours <= 0x7fffffffffffffff ~/ Duration.microsecondsPerHour
          ? Duration(hours: hours)
          : null,
    );
  }

  Future<Response<List<int>>> _request(
    String url, {
    String method = 'GET',
    Map<String, String>? data,
    String? token,
    bool login = false,
    bool subscription = false,
  }) async {
    try {
      // Fresh options keep injected Dio defaults out of credentialed requests.
      final response = await _dio.fetch<List<int>>(
        RequestOptions(
          path: url,
          method: method,
          data: data,
          responseType: ResponseType.bytes,
          headers: {
            HttpHeaders.userAgentHeader: subscription
                ? subscriptionUserAgent
                : _panelUserAgent,
            HttpHeaders.acceptHeader: subscription ? '*/*' : 'application/json',
            HttpHeaders.authorizationHeader: ?token,
            if (data != null)
              HttpHeaders.contentTypeHeader: Headers.formUrlEncodedContentType,
          },
          connectTimeout: _timeout,
          sendTimeout: _timeout,
          receiveTimeout: _timeout,
          followRedirects: false,
          validateStatus: (_) => true,
        ),
      );
      final status = response.statusCode;
      if ((status == null || status < 200 || status >= 300) &&
          !(subscription && _redirectStatuses.contains(status))) {
        throw _statusFailure(status, login: login);
      }
      return response;
    } on FreecatException {
      rethrow;
    } on DioException catch (error) {
      final status = error.response?.statusCode;
      if (status != null) {
        throw _statusFailure(status, login: login);
      }
      throw FreecatException(switch (error.type) {
        DioExceptionType.connectionTimeout ||
        DioExceptionType.sendTimeout ||
        DioExceptionType.receiveTimeout ||
        DioExceptionType.connectionError ||
        DioExceptionType.badCertificate ||
        DioExceptionType.cancel => FreecatFailure.network,
        _ =>
          error.error is SocketException || error.error is HandshakeException
              ? FreecatFailure.network
              : FreecatFailure.invalidResponse,
      });
    } catch (_) {
      throw const FreecatException(FreecatFailure.invalidResponse);
    }
  }

  static FreecatException _statusFailure(int? status, {required bool login}) =>
      FreecatException(
        login && (status == 401 || status == 422)
            ? FreecatFailure.credentials
            : !login && (status == 401 || status == 403)
            ? FreecatFailure.expired
            : FreecatFailure.http,
        statusCode: status,
      );

  static Map _panelData(List<int>? bytes) {
    try {
      final value = jsonDecode(utf8.decode(bytes ?? const []));
      if (value is Map && value['data'] is Map) {
        return value['data'] as Map;
      }
    } catch (_) {
      throw const FreecatException(FreecatFailure.invalidResponse);
    }
    throw const FreecatException(FreecatFailure.invalidResponse);
  }

  static String? _nonEmpty(Object? value) =>
      value is String && value.trim().isNotEmpty ? value.trim() : null;

  static int _number(Object? value) {
    if (value == null || value == '') {
      return 0;
    }
    final parsed = switch (value) {
      int() => value,
      num() when value.isFinite && value == value.truncateToDouble() =>
        value.toInt(),
      String() => int.tryParse(value),
      _ => null,
    };
    if (parsed == null || parsed < 0) {
      throw const FreecatException(FreecatFailure.invalidResponse);
    }
    return parsed;
  }

  static String _panelHost(String host) {
    final value = host.trim();
    final uri = _httpUri(value);
    if (uri.hasQuery || uri.hasFragment) {
      throw const FreecatException(FreecatFailure.invalidHost);
    }
    return value.replaceFirst(RegExp(r'/+$'), '');
  }

  static Uri _subscriptionUri(String url) {
    try {
      final uri = _httpUri(url);
      if (uri.hasFragment ||
          uri.queryParametersAll.entries.any(
            (entry) =>
                entry.key.toLowerCase() == 'flag' &&
                entry.value.any((value) => value.toLowerCase() == 'clash'),
          )) {
        throw const FreecatException(FreecatFailure.invalidHost);
      }
      return uri;
    } catch (_) {
      throw const FreecatException(FreecatFailure.invalidHost);
    }
  }

  static const _redirectStatuses = {301, 302, 303, 307, 308};

  static Uri _httpUri(String value) {
    try {
      final uri = Uri.parse(value);
      final loopback =
          uri.host.toLowerCase() == 'localhost' ||
          (InternetAddress.tryParse(uri.host)?.isLoopback ?? false);
      if (!uri.isAbsolute ||
          !uri.hasAuthority ||
          uri.host.isEmpty ||
          uri.userInfo.isNotEmpty ||
          uri.authority.contains('@') ||
          RegExp(r'^\w+://[^/?#]*@').hasMatch(value) ||
          RegExp(r'[\s\\]').hasMatch(value) ||
          (uri.scheme != 'https' && !(uri.scheme == 'http' && loopback)) ||
          uri.port < 1 ||
          uri.port > 65535) {
        throw const FreecatException(FreecatFailure.invalidHost);
      }
      return uri;
    } catch (_) {
      throw const FreecatException(FreecatFailure.invalidHost);
    }
  }

  static bool _hasControlCharacters(String value) =>
      value.runes.any((rune) => rune < 0x20 || rune == 0x7f);

  void close() => _dio.close(force: true);
}
