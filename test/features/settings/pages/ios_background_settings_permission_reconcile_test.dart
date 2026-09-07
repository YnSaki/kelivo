import 'package:Cuplivo/core/database/business_preferences.dart';
import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/core/services/ios_background_generation.dart';
import 'package:Cuplivo/core/services/ios_keep_alive.dart';
import 'package:Cuplivo/features/settings/pages/display_settings_page.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

const MethodChannel _keepAliveChannel = MethodChannel('app.ios_keepalive');
const MethodChannel _generationChannel = MethodChannel(
  'app.ios_background_generation',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final calls = <String>[];
  var keepAliveLocationAuthorized = false;
  var keepAliveLocationGranted = false;

  setUp(() {
    calls.clear();
    keepAliveLocationAuthorized = false;
    keepAliveLocationGranted = false;
    SharedPreferences.setMockInitialValues({});
    IosKeepAliveService.instance.debugForceIosForTest = true;
    IosBackgroundGenerationService.instance.debugForceIosForTest = true;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_keepAliveChannel, (call) async {
          calls.add('keepAlive.${call.method}');
          switch (call.method) {
            case 'getStatus':
              return <String, Object?>{
                'masterEnabled': true,
                'silentAudioEnabled': false,
                'locationEnabled': true,
                'liveActivityPrivacyMode': false,
                'sessionActive': false,
                'appIsInBackground': false,
                'silentAudioActive': false,
                'locationUpdating': false,
                'locationArmed': false,
                'locationAuthorized': keepAliveLocationAuthorized,
                'survivalTier': 'extended',
                'interruptionCount': 0,
                'lastInterruptedAt': 0,
              };
            case 'requestLocationAuthorization':
              return keepAliveLocationGranted;
            default:
              return null;
          }
        });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_generationChannel, (call) async {
          calls.add('generation.${call.method}');
          switch (call.method) {
            case 'getStatus':
              return <String, Object?>{
                'backgroundTaskActive': false,
                'liveActivityActive': false,
                'notificationsAuthorized': false,
                'liveActivitiesEnabled': true,
              };
            case 'requestNotificationAuthorization':
              return true;
            default:
              return true;
          }
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_keepAliveChannel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_generationChannel, null);
    IosKeepAliveService.instance.debugForceIosForTest = false;
    IosBackgroundGenerationService.instance.resetForTest();
  });

  Future<void> pumpPage(
    WidgetTester tester, {
    Map<String, Object> prefs = const <String, Object>{},
  }) async {
    tester.view.physicalSize = const Size(800, 1800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final settings = SettingsProvider(
      preferences: BusinessPreferences.memoryForTests(prefs),
    );
    addTearDown(settings.dispose);
    await settings.loaded;
    await tester.pumpWidget(
      ChangeNotifierProvider<SettingsProvider>.value(
        value: settings,
        child: const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: IosBackgroundSettingsPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  List<String> requests() => calls
      .where(
        (m) =>
            m == 'keepAlive.requestLocationAuthorization' ||
            m == 'generation.requestNotificationAuthorization',
      )
      .toList();

  String locationPermissionLabel(WidgetTester tester) {
    final l10n = AppLocalizations.of(
      tester.element(find.byType(IosBackgroundSettingsPage)),
    )!;
    return l10n.iosKeepAliveConfigLocationPermissionNeeded;
  }

  testWidgets(
    'page open reconciles restored-ON toggles that lack OS permission',
    (tester) async {
      await pumpPage(
        tester,
        prefs: {
          'ios_location_keepalive_enabled_v1': true,
          'ios_background_notifications_enabled_v1': true,
        },
      );
      await tester.pumpAndSettle();

      expect(
        requests(),
        containsAll(<String>[
          'keepAlive.requestLocationAuthorization',
          'generation.requestNotificationAuthorization',
        ]),
      );
      expect(
        calls.where((m) => m == 'keepAlive.requestLocationAuthorization'),
        hasLength(1),
      );
      expect(
        calls.where((m) => m == 'generation.requestNotificationAuthorization'),
        hasLength(1),
      );
    },
  );

  testWidgets('no request when toggles are off (plain visit)', (tester) async {
    await pumpPage(tester, prefs: const <String, Object>{});
    await tester.pumpAndSettle();

    expect(requests(), isEmpty);
  });

  testWidgets('only the location leg fires when only location toggle is ON', (
    tester,
  ) async {
    await pumpPage(tester, prefs: {'ios_location_keepalive_enabled_v1': true});
    await tester.pumpAndSettle();

    expect(requests(), <String>['keepAlive.requestLocationAuthorization']);
  });

  testWidgets(
    'permission-needed row tap falls back to app settings when denied',
    (tester) async {
      keepAliveLocationGranted = false;
      await pumpPage(
        tester,
        prefs: <String, Object>{'ios_location_keepalive_enabled_v1': true},
      );
      final label = locationPermissionLabel(tester);
      await tester.tap(find.text(label));
      await tester.pumpAndSettle();

      expect(calls, contains('generation.openAppSettings'));
      final settings = tester
          .element(find.byType(IosBackgroundSettingsPage))
          .read<SettingsProvider>();
      expect(settings.iosLocationKeepAliveEnabled, isTrue);
    },
  );

  testWidgets('permission-needed row tap pushes config once granted', (
    tester,
  ) async {
    keepAliveLocationGranted = true;
    await pumpPage(tester, prefs: {'ios_location_keepalive_enabled_v1': true});
    final label = locationPermissionLabel(tester);
    await tester.tap(find.text(label));
    await tester.pumpAndSettle();

    expect(calls, contains('keepAlive.configure'));
    final settings = tester
        .element(find.byType(IosBackgroundSettingsPage))
        .read<SettingsProvider>();
    expect(settings.iosLocationKeepAliveEnabled, isTrue);
  });

  testWidgets('page open survives a channel failure (best-effort reconcile)', (
    tester,
  ) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_keepAliveChannel, (call) async {
          calls.add('keepAlive.${call.method}');
          if (call.method == 'getStatus') {
            throw PlatformException(code: 'channel_down');
          }
          return null;
        });
    await pumpPage(
      tester,
      prefs: <String, Object>{'ios_location_keepalive_enabled_v1': true},
    );

    expect(tester.takeException(), isNull);
    expect(calls, contains('keepAlive.getStatus'));
    expect(calls, isNot(contains('keepAlive.requestLocationAuthorization')));
  });
}
