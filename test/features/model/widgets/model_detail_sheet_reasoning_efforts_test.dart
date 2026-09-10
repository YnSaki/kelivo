import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:Cuplivo/core/database/business_preferences.dart';
import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/features/model/widgets/model_detail_sheet.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';
import 'package:Cuplivo/shared/widgets/ios_switch.dart';
import 'package:Cuplivo/shared/widgets/segmented_toggle.dart';

var businessPrefs = BusinessPreferences.memoryForTests();

Future<SettingsProvider> _settingsForNicheModel(
  WidgetTester tester, {
  List<String>? reasoningEfforts,
}) async {
  businessPrefs = BusinessPreferences.memoryForTests({});
  final settings = SettingsProvider(preferences: businessPrefs);
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pump();

  await settings.setProviderConfig(
    'NicheProvider',
    ProviderConfig(
      id: 'NicheProvider',
      enabled: true,
      name: 'NicheProvider',
      apiKey: 'test-key',
      baseUrl: 'https://api.niche.example/v1',
      providerType: ProviderKind.openai,
      models: const <String>['my-niche-reasoner'],
      modelOverrides: <String, dynamic>{
        'my-niche-reasoner': <String, dynamic>{
          'type': 'chat',
          'input': <String>['text'],
          'output': <String>['text'],
          'abilities': <String>['reasoning'],
          if (reasoningEfforts != null)
            'reasoningEfforts': List<String>.of(reasoningEfforts),
        },
      },
    ),
  );
  return settings;
}

Future<void> _pumpEditor(
  WidgetTester tester, {
  required SettingsProvider settings,
}) async {
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        Provider<BusinessPreferences>.value(value: businessPrefs),
        ChangeNotifierProvider<SettingsProvider>.value(value: settings),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              key: const ValueKey('open-model-editor'),
              onPressed: () => showModelDetailSheet(
                context,
                providerKey: 'NicheProvider',
                modelId: 'my-niche-reasoner',
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
}

Future<void> _openEditor(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('open-model-editor')));
  await tester.pumpAndSettle();
}

Future<void> _revealReasoningSwitch(WidgetTester tester) async {
  await tester.scrollUntilVisible(
    find.byType(IosSwitch),
    200,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.pumpAndSettle();
}

SegmentedToggleMulti _reasoningSegments(WidgetTester tester) {
  // The reasoning-effort chips are the last SegmentedToggleMulti in the
  // basic tab.
  return tester.widget<SegmentedToggleMulti>(
    find.byType(SegmentedToggleMulti).last,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ModelDetailSheet reasoning effort vocabulary', () {
    testWidgets('chip taps mutate the list and persist on save', (
      tester,
    ) async {
      final settings = await _settingsForNicheModel(tester);
      await _pumpEditor(tester, settings: settings);
      await _openEditor(tester);

      await _revealReasoningSwitch(tester);
      await tester.tap(find.byType(IosSwitch));
      await tester.pumpAndSettle();

      // Unmatched openai models prefill with the low/medium/high fallback.
      expect(_reasoningSegments(tester).isSelected, [
        true,
        true,
        true,
        false,
        false,
      ]);

      // Add a level: on a const list this throws UnsupportedError.
      await tester.ensureVisible(find.text('Extreme Reasoning'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Extreme Reasoning'));
      await tester.pump();
      expect(tester.takeException(), isNull);

      // Remove a level: also mutates the list.
      await tester.ensureVisible(find.text('Light Reasoning'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Light Reasoning'));
      await tester.pump();
      expect(tester.takeException(), isNull);

      expect(_reasoningSegments(tester).isSelected, [
        false,
        true,
        true,
        true,
        false,
      ]);

      await tester.tap(find.text('Confirm'));
      await tester.pumpAndSettle();

      final override =
          settings
                  .getProviderConfig('NicheProvider')
                  .modelOverrides['my-niche-reasoner']
              as Map<String, dynamic>;
      expect(override['reasoningEfforts'], ['medium', 'high', 'xhigh']);
    });

    testWidgets('an explicitly empty vocabulary survives toggle off/on', (
      tester,
    ) async {
      final settings = await _settingsForNicheModel(
        tester,
        reasoningEfforts: const <String>[],
      );
      await _pumpEditor(tester, settings: settings);
      await _openEditor(tester);

      await _revealReasoningSwitch(tester);
      // Loaded with an explicit empty vocabulary: switch on, nothing selected.
      expect(_reasoningSegments(tester).isSelected, everyElement(isFalse));

      await tester.tap(find.byType(IosSwitch));
      await tester.pump();
      await tester.tap(find.byType(IosSwitch));
      await tester.pumpAndSettle();

      // The first enable refill must not clobber the intentional empty list.
      expect(_reasoningSegments(tester).isSelected, everyElement(isFalse));

      await tester.tap(find.text('Confirm'));
      await tester.pumpAndSettle();

      final override =
          settings
                  .getProviderConfig('NicheProvider')
                  .modelOverrides['my-niche-reasoner']
              as Map<String, dynamic>;
      expect(override['reasoningEfforts'], isEmpty);
    });
  });
}
