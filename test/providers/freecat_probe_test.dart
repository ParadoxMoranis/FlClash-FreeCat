import 'dart:async';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/core/controller.dart';
import 'package:fl_clash/core/interface.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/action.dart';
import 'package:fl_clash/providers/app.dart';
import 'package:fl_clash/providers/config.dart';
import 'package:fl_clash/providers/core.dart';
import 'package:fl_clash/providers/database.dart';
import 'package:fl_clash/providers/state.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:riverpod/riverpod.dart';

import '../helpers/test_profiles.dart';

const _officialUrl = 'http://cp.cloudflare.com/generate_204';
const _healthUrl = 'http://www.gstatic.com/generate_204';
const _node = Proxy(name: 'test-node', type: 'Trojan');

class _Core extends Mock implements CoreHandlerInterface {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Core core;
  late ProviderContainer container;

  setUpAll(() {
    registerFallbackValue(
      const TestDelayParams(proxyName: '', testUrl: '', timeout: 8000),
    );
  });

  setUp(() {
    core = _Core();
    container = ProviderContainer(
      overrides: [
        coreHandlerProvider.overrideWithValue(CoreController.scoped(core)),
        profilesProvider.overrideWith(
          () => TestProfiles(const [
            Profile(
              id: 1,
              type: ProfileType.freecat,
              autoUpdateDuration: Duration.zero,
            ),
            Profile(
              id: 2,
              type: ProfileType.url,
              autoUpdateDuration: Duration.zero,
            ),
          ]),
        ),
        currentProfileIdProvider.overrideWithBuild((_, _) => 1),
      ],
    );
    container.read(groupsProvider.notifier).value = const [
      Group(
        name: 'Main',
        type: GroupType.Selector,
        hidden: false,
        now: 'Auto',
        all: [
          Proxy(name: 'Auto', type: 'URLTest'),
          _node,
        ],
      ),
      Group(
        name: 'Auto',
        type: GroupType.URLTest,
        hidden: false,
        now: 'test-node',
        testUrl: _healthUrl,
        all: [_node],
      ),
    ];
  });

  tearDown(() => container.dispose());

  Future<void> runGroup() async {
    await container
        .read(proxiesActionProvider.notifier)
        .delayTestPageGroup('Auto');
  }

  test(
    'manual group tests and nested delay displays use the official endpoint',
    () async {
      final answer = Completer<Delay>();
      when(() => core.testDelay(any())).thenAnswer((_) => answer.future);
      final originalGroups = container.read(groupsProvider);
      final run = runGroup();

      final request =
          verify(() => core.testDelay(captureAny())).captured.single
              as TestDelayParams;
      expect(request.testUrl, _officialUrl);
      expect(request.timeout, 5000);
      expect(container.read(coreOptionsProvider).delayTestTimeout, 5000);
      expect(container.read(coreOptionsProvider).testUrl, _officialUrl);
      expect(
        container.read(
          delayTestPhaseProvider(proxyName: 'Auto', testUrl: _healthUrl),
        ),
        DelayTestPhase.running,
      );
      expect(container.read(pendingDelayTestsProvider).keys, [
        delayTestKey(_officialUrl, 'test-node'),
      ]);

      answer.complete(
        const Delay(name: 'test-node', url: _officialUrl, value: 67),
      );
      await run;

      expect(
        container.read(
          delayProvider(proxyName: 'test-node', testUrl: _healthUrl),
        ),
        67,
      );
      expect(
        container.read(delayProvider(proxyName: 'Auto', testUrl: _healthUrl)),
        67,
      );
      expect(container.read(trayDelaysProvider)['Main']?['Auto'], 67);
      expect(container.read(groupsProvider), originalGroups);
      expect(container.read(groupsProvider)[1].testUrl, _healthUrl);
      expect(container.read(patchClashConfigProvider).testUrl, defaultTestUrl);
      expect(
        container.read(appSettingProvider).delayTestTimeout,
        defaultDelayTestTimeout,
      );
    },
  );

  test('the selected manual URL and timeout take precedence', () async {
    const customUrl = 'https://custom.example/generate_204';
    container
        .read(patchClashConfigProvider.notifier)
        .update(
          (config) => config.copyWith(
            testUrl: customUrl,
            generalOverrideKeys: {GeneralOverrideKey.testUrl},
          ),
        );
    container
        .read(appSettingProvider.notifier)
        .update((settings) => settings.copyWith(delayTestTimeout: 2000));
    when(() => core.testDelay(any())).thenAnswer(
      (_) async => const Delay(name: 'test-node', url: customUrl, value: 91),
    );

    await runGroup();

    final request =
        verify(() => core.testDelay(captureAny())).captured.single
            as TestDelayParams;
    expect(request.testUrl, customUrl);
    expect(request.timeout, 2000);
    expect(container.read(coreOptionsProvider).testUrl, customUrl);
    expect(container.read(coreOptionsProvider).delayTestTimeout, 2000);
    expect(
      container.read(delayProvider(proxyName: 'Auto', testUrl: _healthUrl)),
      91,
    );
  });

  test('an explicitly selected 8000 ms timeout is preserved', () async {
    container
        .read(appSettingProvider.notifier)
        .update(
          (settings) => settings.copyWith(
            delayTestTimeout: 8000,
            delayTestTimeoutExplicit: true,
          ),
        );
    when(() => core.testDelay(any())).thenAnswer(
      (_) async => const Delay(name: 'test-node', url: _officialUrl, value: 91),
    );

    await runGroup();

    final request =
        verify(() => core.testDelay(captureAny())).captured.single
            as TestDelayParams;
    expect(request.timeout, 8000);
    expect(container.read(coreOptionsProvider).delayTestTimeout, 8000);
  });

  test('legacy saved timeout survives source switching', () async {
    container
        .read(appSettingProvider.notifier)
        .update((_) => AppSettingProps.fromJson({'delayTestTimeout': 8000}));
    expect(container.read(manualTestTimeoutProvider), 8000);
    container.read(currentProfileIdProvider.notifier).value = 2;
    expect(container.read(manualTestTimeoutProvider), 8000);
    container.read(currentProfileIdProvider.notifier).value = 1;
    expect(container.read(manualTestTimeoutProvider), 8000);
  });

  test('an explicitly picked original URL is preserved for FreeCat', () {
    container
        .read(patchClashConfigProvider.notifier)
        .update(
          (config) => config.copyWith(
            generalOverrideKeys: {GeneralOverrideKey.testUrl},
          ),
        );
    expect(container.read(realTestUrlProvider(_healthUrl)), defaultTestUrl);
    expect(container.read(coreOptionsProvider).testUrl, defaultTestUrl);
  });

  test('a saved custom URL works even without override metadata', () {
    container
        .read(patchClashConfigProvider.notifier)
        .update(
          (config) => config.copyWith(testUrl: 'https://saved.example/204'),
        );
    expect(
      container.read(realTestUrlProvider(_healthUrl)),
      'https://saved.example/204',
    );
  });

  test(
    'switching to a regular source restores existing group test behavior',
    () async {
      container.listen(realTestUrlProvider(_healthUrl), (_, _) {});
      expect(container.read(realTestUrlProvider(_healthUrl)), _officialUrl);
      container.read(currentProfileIdProvider.notifier).value = 2;
      when(() => core.testDelay(any())).thenAnswer(
        (_) async => const Delay(name: 'test-node', url: _healthUrl, value: 88),
      );

      await runGroup();

      final request =
          verify(() => core.testDelay(captureAny())).captured.single
              as TestDelayParams;
      expect(request.testUrl, _healthUrl);
      expect(request.timeout, defaultDelayTestTimeout);
      expect(container.read(coreOptionsProvider).testUrl, defaultTestUrl);
      expect(
        container.read(delayProvider(proxyName: 'Auto', testUrl: _healthUrl)),
        88,
      );
      expect(container.read(realTestUrlProvider(_healthUrl)), _healthUrl);
    },
  );

  test(
    'the same node in multiple groups is manually probed once for FreeCat',
    () async {
      when(() => core.testDelay(any())).thenAnswer(
        (_) async =>
            const Delay(name: 'test-node', url: _officialUrl, value: 61),
      );
      await container.read(proxiesActionProvider.notifier).delayTestGroups(
        const [
          Group(name: 'A', type: GroupType.Selector, all: [_node]),
          Group(
            name: 'B',
            type: GroupType.URLTest,
            testUrl: _healthUrl,
            all: [_node],
          ),
        ],
      );
      verify(() => core.testDelay(any())).called(1);
      expect(
        container.read(delayDataSourceProvider)[_officialUrl]?['test-node'],
        61,
      );
    },
  );
}
