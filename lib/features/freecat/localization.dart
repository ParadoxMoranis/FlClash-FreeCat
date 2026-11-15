import 'package:fl_clash/common/app_localizations.dart';
import 'package:fl_clash/l10n/l10n.dart';

import 'errors.dart';

String freecatErrorMessage(Object error, [AppLocalizations? appLocalizations]) {
  final l10n = appLocalizations ?? currentAppLocalizations;
  if (error is! FreecatException) return l10n.freecatErrorGeneric;
  return switch (error.failure) {
    FreecatFailure.invalidHost => l10n.freecatErrorInvalidHost,
    FreecatFailure.credentials => l10n.freecatErrorCredentials,
    FreecatFailure.expired => l10n.freecatErrorExpired,
    FreecatFailure.network => l10n.freecatErrorNetwork,
    FreecatFailure.http => l10n.freecatErrorHttp,
    FreecatFailure.invalidResponse => l10n.freecatErrorInvalidResponse,
    FreecatFailure.decryption => l10n.freecatErrorDecryption,
    FreecatFailure.decoy => l10n.freecatErrorDecoy,
    FreecatFailure.invalidProfile => l10n.freecatErrorInvalidProfile,
    FreecatFailure.storage => l10n.freecatErrorStorage,
  };
}
