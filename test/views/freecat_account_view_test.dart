import 'dart:async';
import 'dart:convert';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/features/form/form.dart';
import 'package:fl_clash/features/freecat/errors.dart';
import 'package:fl_clash/features/freecat/localization.dart';
import 'package:fl_clash/features/freecat/store.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/action.dart';
import 'package:fl_clash/providers/app.dart';
import 'package:fl_clash/providers/database.dart';
import 'package:fl_clash/state.dart';
import 'package:fl_clash/views/profiles/freecat.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/host_scaffold.dart';
import '../helpers/test_app.dart';
import '../helpers/test_profiles.dart';

typedef _SignIn = ({
  String email,
  String password,
  String? host,
  int? profileId,
});

class _RecordingProfilesAction extends ProfilesAction {
  final calls = <_SignIn>[];
  Future<void> Function()? onImport;

  @override
  Future<void> importFreecat({
    required String email,
    required String password,
    String? host,
    int? profileId,
  }) async {
    calls.add((
      email: email,
      password: password,
      host: host,
      profileId: profileId,
    ));
    await onImport?.call();
  }
}

Finder _field(String title) => find.descendant(
  of: find.widgetWithText(FormRow, title),
  matching: find.byType(TextFormField),
);

TextEditingController _controller(WidgetTester tester, String title) => tester
    .widget<EditableText>(
      find.descendant(of: _field(title), matching: find.byType(EditableText)),
    )
    .controller;

Future<ProviderContainer> _open(
  WidgetTester tester,
  _RecordingProfilesAction action, {
  int? profileId,
  List<Profile> profiles = const [],
}) async {
  const size = Size(1200, 1000);
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final container = ProviderContainer(
    overrides: [
      profilesProvider.overrideWith(() => TestProfiles(profiles)),
      profilesActionProvider.overrideWith(() => action),
    ],
  );
  addTearDown(container.dispose);
  globalState.container = container;
  container.read(viewSizeProvider.notifier).update((_) => size);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: TestApp(
        locale: const Locale('en'),
        child: HostScaffold(
          body: Builder(
            builder: (context) => FilledButton(
              onPressed: () => showFormSheet<void>(
                context: context,
                builder: (_) => FreecatAccountView(profileId: profileId),
              ),
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Open'));
  await tester.pumpAndSettle();
  return container;
}

Future<void> _enterAccount(WidgetTester tester) async {
  final l10n = currentAppLocalizations;
  await tester.enterText(_field(l10n.email), ' person@example.test ');
  await tester.enterText(_field(l10n.password), ' synthetic password ');
}

Finder _submit() =>
    find.widgetWithText(TextButton, currentAppLocalizations.signIn);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
  });

  tearDown(() {
    FlutterSecureStorage.setMockInitialValues({});
  });

  testWidgets('requires email and password before signing in', (tester) async {
    final action = _RecordingProfilesAction();
    await _open(tester, action);
    final l10n = currentAppLocalizations;

    expect(find.text(l10n.freecatHostTip), findsOne);
    expect(find.text(l10n.freecatAccountMissingTip), findsNothing);
    await tester.tap(_submit());
    await tester.pumpAndSettle();
    expect(find.text(l10n.emptyTip(l10n.email)), findsOne);
    expect(
      tester.widget<FormRow>(find.widgetWithText(FormRow, l10n.email)).invalid,
      isTrue,
    );
    expect(action.calls, isEmpty);

    await tester.enterText(_field(l10n.email), ' person@example.test ');
    await tester.tap(_submit());
    await tester.pumpAndSettle();
    expect(find.text(l10n.emptyTip(l10n.password)), findsOne);
    expect(action.calls, isEmpty);

    await tester.enterText(_field(l10n.password), ' synthetic password ');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(action.calls, [
      (
        email: 'person@example.test',
        password: ' synthetic password ',
        host: null,
        profileId: null,
      ),
    ]);
    expect(find.byType(FreecatAccountView), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('obscures the password and lets the user reveal it', (
    tester,
  ) async {
    await _open(tester, _RecordingProfilesAction());
    final l10n = currentAppLocalizations;
    final password = find.descendant(
      of: _field(l10n.password),
      matching: find.byType(EditableText),
    );
    await tester.enterText(_field(l10n.password), 'synthetic-secret');
    expect(tester.widget<EditableText>(password).obscureText, isTrue);
    await tester.tap(find.byTooltip(l10n.showPassword));
    await tester.pumpAndSettle();
    expect(tester.widget<EditableText>(password).obscureText, isFalse);
    await tester.tap(find.byTooltip(l10n.hidePassword));
    await tester.pumpAndSettle();
    expect(tester.widget<EditableText>(password).obscureText, isTrue);
  });

  testWidgets('prevents duplicate requests and can retry after login fails', (
    tester,
  ) async {
    final pending = Completer<void>();
    final action = _RecordingProfilesAction()..onImport = () => pending.future;
    await _open(tester, action);
    await _enterAccount(tester);
    await tester.tap(_submit());
    await tester.pump();

    final page = tester.widget<FormPage>(find.byType(FormPage));
    expect(page.saving, isTrue);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    page.onSave();
    await tester.pump();
    expect(action.calls, hasLength(1));

    pending.completeError(const FreecatException(FreecatFailure.credentials));
    await tester.pumpAndSettle();
    final l10n = currentAppLocalizations;
    expect(find.text(l10n.freecatErrorCredentials), findsOne);
    expect(tester.widget<FormPage>(find.byType(FormPage)).saving, isFalse);
    expect(find.byType(ActivityIndicator), findsNothing);
    expect(find.byType(FreecatAccountView), findsOne);

    action.onImport = null;
    await tester.tap(_submit());
    await tester.pumpAndSettle();
    expect(action.calls, hasLength(2));
    expect(find.byType(FreecatAccountView), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('edits the saved account on the same profile without secrets', (
    tester,
  ) async {
    const profileId = 41;
    FlutterSecureStorage.setMockInitialValues({
      'flclash.freecat.account.$profileId': jsonEncode(
        const FreecatAccount(
          host: 'https://panel.example.test',
          email: 'saved@example.test',
          token: 'synthetic-hidden-token',
          subscribeUrl: 'https://sub.example.test/private-token',
        ).toJson(),
      ),
    });
    const profile = Profile(
      id: profileId,
      type: ProfileType.freecat,
      label: 'Saved subscription',
      autoUpdateDuration: Duration(hours: 24),
      subscriptionInfo: SubscriptionInfo(
        upload: 1024,
        download: 2048,
        total: 1073741824,
        expire: 4102444800,
      ),
    );
    final action = _RecordingProfilesAction();
    final container = await _open(
      tester,
      action,
      profileId: profileId,
      profiles: [profile],
    );
    final l10n = currentAppLocalizations;
    expect(_controller(tester, l10n.host).text, 'https://panel.example.test');
    expect(_controller(tester, l10n.email).text, 'saved@example.test');
    expect(_controller(tester, l10n.password).text, isEmpty);
    expect(find.text(l10n.freecatReplaceAccountTip), findsOne);
    expect(find.byType(SubscriptionInfoDetailView), findsOne);
    expect(find.text('3KB'), findsOne);
    expect(find.text('1GB'), findsOne);
    expect(find.text(l10n.expireTime), findsOne);
    expect(find.textContaining('synthetic-hidden-token'), findsNothing);
    expect(find.textContaining('private-token'), findsNothing);

    await _enterAccount(tester);
    await tester.enterText(
      _field(l10n.host),
      ' https://replacement.example.test ',
    );
    await tester.tap(_submit());
    await tester.pumpAndSettle();
    expect(action.calls.single, (
      email: 'person@example.test',
      password: ' synthetic password ',
      host: 'https://replacement.example.test',
      profileId: profileId,
    ));
    expect(container.read(profilesProvider), [profile]);
    expect(find.byType(FreecatAccountView), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('explains missing credentials and can sign in to the same id', (
    tester,
  ) async {
    final action = _RecordingProfilesAction();
    await _open(tester, action, profileId: 42);
    final l10n = currentAppLocalizations;
    expect(find.text(l10n.freecatAccountMissingTip), findsOne);
    expect(_controller(tester, l10n.password).text, isEmpty);
    await _enterAccount(tester);
    await tester.enterText(_field(l10n.host), '   ');
    await tester.tap(_submit());
    await tester.pumpAndSettle();
    expect(action.calls.single.profileId, 42);
    expect(action.calls.single.host, isNull);
    expect(find.byType(FreecatAccountView), findsNothing);
  });

  testWidgets('account read errors recover into a usable sign-in form', (
    tester,
  ) async {
    FlutterSecureStorage.setMockInitialValues({
      'flclash.freecat.account.43': 'invalid-json-with-private-data',
    });
    final action = _RecordingProfilesAction();
    await _open(tester, action, profileId: 43);
    final l10n = currentAppLocalizations;
    expect(find.text(l10n.freecatErrorStorage), findsOne);
    expect(find.textContaining('invalid-json-with-private-data'), findsNothing);
    expect(tester.widget<FormPage>(find.byType(FormPage)).saving, isFalse);
    expect(find.byType(ActivityIndicator), findsNothing);

    await _enterAccount(tester);
    await tester.pump();
    expect(find.text(l10n.freecatErrorStorage), findsNothing);
    await tester.tap(_submit());
    await tester.pumpAndSettle();
    expect(action.calls.single.profileId, 43);
    expect(find.byType(FreecatAccountView), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('unknown login failures never display raw request details', (
    tester,
  ) async {
    final action = _RecordingProfilesAction()
      ..onImport = () async {
        throw StateError(
          'POST https://secret.example.test?token=hidden '
          'Authorization: hidden password=private',
        );
      };
    await _open(tester, action);
    await _enterAccount(tester);
    await tester.tap(_submit());
    await tester.pumpAndSettle();
    expect(find.text(currentAppLocalizations.freecatErrorGeneric), findsOne);
    expect(find.textContaining('secret.example.test'), findsNothing);
    expect(find.textContaining('Authorization:'), findsNothing);
    expect(find.textContaining('password=private'), findsNothing);
    expect(tester.widget<FormPage>(find.byType(FormPage)).saving, isFalse);
    expect(tester.takeException(), isNull);
  });

  for (final fail in [false, true]) {
    testWidgets('can cancel while signing in with late failure=$fail', (
      tester,
    ) async {
      final pending = Completer<void>();
      final action = _RecordingProfilesAction()
        ..onImport = () => pending.future;
      await _open(tester, action);
      await _enterAccount(tester);
      await tester.tap(_submit());
      await tester.pump();
      await tester.tap(
        find.widgetWithText(TextButton, currentAppLocalizations.cancel),
      );
      await tester.pumpAndSettle();
      expect(find.byType(FreecatAccountView), findsNothing);
      if (fail) {
        pending.completeError(const FreecatException(FreecatFailure.network));
      } else {
        pending.complete();
      }
      await tester.pumpAndSettle();
      expect(find.text('Open'), findsOne);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('maps every FreeCat failure to a safe localized message', (
    tester,
  ) async {
    await _open(tester, _RecordingProfilesAction());
    final l10n = currentAppLocalizations;
    final messages = {
      FreecatFailure.invalidHost: l10n.freecatErrorInvalidHost,
      FreecatFailure.credentials: l10n.freecatErrorCredentials,
      FreecatFailure.expired: l10n.freecatErrorExpired,
      FreecatFailure.network: l10n.freecatErrorNetwork,
      FreecatFailure.http: l10n.freecatErrorHttp,
      FreecatFailure.invalidResponse: l10n.freecatErrorInvalidResponse,
      FreecatFailure.decryption: l10n.freecatErrorDecryption,
      FreecatFailure.decoy: l10n.freecatErrorDecoy,
      FreecatFailure.invalidProfile: l10n.freecatErrorInvalidProfile,
      FreecatFailure.storage: l10n.freecatErrorStorage,
    };
    expect(messages.keys, unorderedEquals(FreecatFailure.values));
    for (final entry in messages.entries) {
      final error = FreecatException(entry.key, statusCode: 403);
      expect(freecatErrorMessage(error), entry.value);
      expect(freecatErrorMessage(error, l10n), entry.value);
    }
    expect(
      freecatErrorMessage(StateError('private')),
      l10n.freecatErrorGeneric,
    );
  });
}
