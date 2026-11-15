import 'dart:async';
import 'dart:io';

import 'package:fl_clash/common/path.dart';
import 'package:fl_clash/models/profile.dart';
import 'package:flutter/foundation.dart' show compute;

import 'client.dart';
import 'errors.dart';
import 'store.dart';
import 'subscription.dart';

class FreecatService {
  final FreecatAccountStore _store;
  final FreecatClient Function() _createClient;
  final _operations = <int, Future<void>>{};

  FreecatService({
    FreecatAccountStore store = const FreecatAccountStore(),
    FreecatClient Function()? createClient,
  }) : _store = store,
       _createClient = createClient ?? FreecatClient.new;

  Future<T> _serial<T>(int profileId, Future<T> Function() run) async {
    final previous = _operations[profileId];
    final complete = Completer<void>();
    final operation = complete.future;
    _operations[profileId] = operation;
    try {
      await previous;
      return await run();
    } finally {
      complete.complete();
      if (identical(_operations[profileId], operation)) {
        unawaited(_operations.remove(profileId));
      }
    }
  }

  Future<FreecatAccount?> readAccount(int profileId) => _store.read(profileId);

  Future<void> removeAccount(int profileId) =>
      _serial(profileId, () => _store.delete(profileId));

  Future<Profile> signIn(
    Profile profile, {
    required String email,
    required String password,
    String? host,
    required ValidateConfig validate,
  }) {
    return _serial(profile.id, () async {
      final client = _createClient();
      try {
        final login = await client.login(
          host: host,
          email: email,
          password: password,
        );
        return await _download(
          profile,
          FreecatAccount(
            host: login.host,
            email: email,
            token: login.token,
            subscribeUrl: '',
          ),
          client,
          validate,
          useServerInterval: true,
        );
      } finally {
        client.close();
      }
    });
  }

  Future<Profile> update(Profile profile, {required ValidateConfig validate}) {
    return _serial(profile.id, () async {
      final account = await _store.read(profile.id);
      if (account == null) {
        throw const FreecatException(FreecatFailure.expired);
      }
      final client = _createClient();
      try {
        return await _download(profile, account, client, validate);
      } finally {
        client.close();
      }
    });
  }

  Future<Profile> _download(
    Profile profile,
    FreecatAccount account,
    FreecatClient client,
    ValidateConfig validate, {
    bool useServerInterval = false,
  }) async {
    final subscription = await client.getSubscribe(account.host, account.token);
    final response = await client.fetchSubscription(subscription.url);
    final bytes = await compute(normalizeFreecatSubscription, response.bytes);
    final nextAccount = FreecatAccount(
      host: account.host,
      email: account.email,
      token: account.token,
      subscribeUrl: subscription.url,
      updatedAt: DateTime.now(),
    );
    final info = response.userinfo == null
        ? SubscriptionInfo(
            upload: subscription.upload,
            download: subscription.download,
            total: subscription.total,
            expire: subscription.expire,
          )
        : SubscriptionInfo.formHString(response.userinfo);
    final next = profile.copyWith(
      url: '',
      subscriptionInfo: info,
      autoUpdateDuration: useServerInterval
          ? response.updateInterval ?? const Duration(hours: 24)
          : profile.autoUpdateDuration,
    );
    final path = await appPath.getProfilePath(profile.id.toString());
    final target = File(path);
    await target.parent.create(recursive: true);
    final staging = await target.parent.createTemp('.freecat-');
    final staged = File('${staging.path}/profile.yaml');
    try {
      await staged.writeAsBytes(bytes, flush: true);
      try {
        if (await validate(staged.path, '') != null) {
          throw const FreecatException(FreecatFailure.invalidProfile);
        }
      } catch (_) {
        throw const FreecatException(FreecatFailure.invalidProfile);
      }
      final previous = await _store.snapshot(profile.id);
      await _store.write(profile.id, nextAccount);
      try {
        await staged.rename(path);
      } catch (_) {
        await _store.restore(profile.id, previous);
        rethrow;
      }
      return next.copyWith(lastUpdateDate: nextAccount.updatedAt);
    } finally {
      await staging.delete(recursive: true);
    }
  }
}

final freecatService = FreecatService();
