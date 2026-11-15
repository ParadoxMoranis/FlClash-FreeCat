import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'errors.dart';

final class FreecatAccount {
  final String host;
  final String email;
  final String token;
  final String subscribeUrl;
  final DateTime? updatedAt;

  const FreecatAccount({
    required this.host,
    required this.email,
    required this.token,
    required this.subscribeUrl,
    this.updatedAt,
  });

  factory FreecatAccount.fromJson(Map<String, dynamic> json) {
    return FreecatAccount(
      host: json['host'] as String,
      email: json['email'] as String,
      token: json['token'] as String,
      subscribeUrl: json['subscribeUrl'] as String,
      updatedAt: DateTime.tryParse(json['updatedAt'] as String? ?? ''),
    );
  }

  Map<String, Object?> toJson() => {
    'host': host,
    'email': email,
    'token': token,
    'subscribeUrl': subscribeUrl,
    'updatedAt': updatedAt?.toIso8601String(),
  };
}

class FreecatAccountStore {
  final FlutterSecureStorage _storage;

  const FreecatAccountStore({
    FlutterSecureStorage storage = const FlutterSecureStorage(
      aOptions: AndroidOptions(
        storageNamespace: 'FlClashFreecat',
        resetOnError: false,
      ),
      mOptions: MacOsOptions(usesDataProtectionKeychain: false),
    ),
  }) : _storage = storage;

  String _key(int profileId) => 'flclash.freecat.account.$profileId';

  Future<String?> snapshot(int profileId) async {
    try {
      return await _storage.read(key: _key(profileId));
    } catch (_) {
      throw const FreecatException(FreecatFailure.storage);
    }
  }

  Future<void> restore(int profileId, String? value) async {
    try {
      await _storage.write(key: _key(profileId), value: value);
    } catch (_) {
      throw const FreecatException(FreecatFailure.storage);
    }
  }

  Future<FreecatAccount?> read(int profileId) async {
    try {
      final value = await snapshot(profileId);
      if (value == null) return null;
      return FreecatAccount.fromJson(jsonDecode(value) as Map<String, dynamic>);
    } catch (_) {
      throw const FreecatException(FreecatFailure.storage);
    }
  }

  Future<void> write(int profileId, FreecatAccount account) async {
    try {
      await _storage.write(
        key: _key(profileId),
        value: jsonEncode(account.toJson()),
      );
    } catch (_) {
      throw const FreecatException(FreecatFailure.storage);
    }
  }

  Future<void> delete(int profileId) async {
    try {
      await _storage.delete(key: _key(profileId));
    } catch (_) {
      throw const FreecatException(FreecatFailure.storage);
    }
  }
}
