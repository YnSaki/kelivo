import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:Cuplivo/core/database/business_preferences.dart';

import 'package:Cuplivo/core/providers/assistant_provider.dart';
import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/features/chat/widgets/reasoning_budget_sheet.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';

var businessPrefs = BusinessPreferences.memoryForTests();

Future<SettingsProvider> _settingsForClaudeModel(
  WidgetTester tester,
  String modelId,
) async {
  businessPrefs = BusinessPreferences.memoryForTests({});
  final settings = SettingsProvider(preferences: businessPrefs);
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pump();

  await settings.setProviderConfig(
    'Claude',
    ProviderConfig(
      id: 'Claude',
      enabled: true,
      name: 'Claude',
      apiKey: 'test-key',
      baseUrl: 'https://api.anthropic.com/v1',
      providerType: ProviderKind.claude,
      models: <String>[modelId],
    ),
  );
  await settings.setCurrentModel('Claude', modelId);
  return settings;
}

Future<void> _pumpSheetLauncher(
  WidgetTester tester, {
  required SettingsProvider settings,
  int? initialBudget,
}) async {
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        Provider<BusinessPreferences>.value(value: businessPrefs),
        ChangeNotifierProvider<SettingsProvider>.value(value: settings),
        ChangeNotifierProvider<AssistantProvider>(
          create: (_) => AssistantProvider(preferences: businessPrefs),
        ),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Builder(
            builder: (context) {
              return TextButton(
                key: const ValueKey('open-reasoning-sheet'),
                onPressed: () => showReasoningBudgetSheet(
                  context,
                  initialBudget: initialBudget,
                ),
                child: const Text('open'),
              );
            },
          ),
        ),
      ),
    ),
  );
}

Future<void> _openSheet(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('open-reasoning-sheet')));
  await tester.pumpAndSettle();
}

/// Returns a spy counting Android soft-haptic calls
/// (Haptics.soft() => HapticFeedback.selectionClick on the platform channel).
_HapticSpy _installHapticSpy(WidgetTester tester) {
  final spy = _HapticSpy();
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    SystemChannels.platform,
    spy.call,
  );
  addTearDown(
    () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      null,
    ),
  );
  return spy;
}

class _HapticSpy {
  int selectionClicks = 0;

  Future<Object?>? call(MethodCall message) async {
    if (message.method == 'HapticFeedback.vibrate' &&
        message.arguments == 'HapticFeedbackType.selectionClick') {
      selectionClicks++;
    }
    return null;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ReasoningBudgetSheet', () {
    testWidgets('shows max reasoning stop for Claude Fable 5', (tester) async {
      final settings = await _settingsForClaudeModel(tester, 'claude-fable-5');
      await _pumpSheetLauncher(tester, settings: settings);

      await _openSheet(tester);

      expect(
        find.byKey(const ValueKey('reasoning-stop-64000')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('reasoning-stop-128000')),
        findsOneWidget,
      );

      await tester.tapAt(
        tester.getCenter(find.byKey(const ValueKey('reasoning-stop-128000'))),
      );
      await tester.pumpAndSettle();

      expect(settings.thinkingBudget, 128000);
      expect(find.text('Max'), findsOneWidget);
    });

    testWidgets('keeps max reasoning stop hidden for older Claude models', (
      tester,
    ) async {
      final settings = await _settingsForClaudeModel(
        tester,
        'claude-sonnet-4-5',
      );
      await _pumpSheetLauncher(tester, settings: settings);

      await _openSheet(tester);

      expect(find.byKey(const ValueKey('reasoning-stop-64000')), findsNothing);
      expect(find.byKey(const ValueKey('reasoning-stop-128000')), findsNothing);
    });

    testWidgets('selects presets by tapping track stops', (tester) async {
      final settings = await _settingsForClaudeModel(
        tester,
        'claude-sonnet-4-5',
      );
      final haptic = _installHapticSpy(tester);
      await _pumpSheetLauncher(tester, settings: settings);

      await _openSheet(tester);
      expect(haptic.selectionClicks, 0);

      await tester.tapAt(
        tester.getCenter(find.byKey(const ValueKey('reasoning-stop-1024'))),
      );
      await tester.pumpAndSettle();
      expect(settings.thinkingBudget, 1024);
      expect(find.text('Low'), findsOneWidget);
      expect(haptic.selectionClicks, 1);

      await tester.tapAt(
        tester.getCenter(find.byKey(const ValueKey('reasoning-stop-32000'))),
      );
      await tester.pumpAndSettle();
      expect(settings.thinkingBudget, 32000);
      expect(find.text('High'), findsOneWidget);
      expect(haptic.selectionClicks, 2);
    });

    testWidgets('commits each crossed level once while dragging', (
      tester,
    ) async {
      final settings = await _settingsForClaudeModel(
        tester,
        'claude-sonnet-4-5',
      );
      final haptic = _installHapticSpy(tester);
      await _pumpSheetLauncher(tester, settings: settings);

      await _openSheet(tester);
      expect(haptic.selectionClicks, 0);

      final start = tester.getCenter(
        find.byKey(const ValueKey('reasoning-stop-1024')),
      );
      final end = tester.getCenter(
        find.byKey(const ValueKey('reasoning-stop-32000')),
      );
      final dx = (end.dx - start.dx) / 10;
      final gesture = await tester.startGesture(start);
      await tester.pump(const Duration(milliseconds: 16));
      for (var i = 0; i < 10; i++) {
        await gesture.moveBy(Offset(dx, 0));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await gesture.up();
      await tester.pumpAndSettle();

      expect(settings.thinkingBudget, 32000);
      // auto -> low(drag start) -> medium -> high: one soft tick per level.
      expect(haptic.selectionClicks, 3);
    });

    testWidgets('commits final level when drag ends before a rebuild', (
      tester,
    ) async {
      final settings = await _settingsForClaudeModel(
        tester,
        'claude-sonnet-4-5',
      );
      await _pumpSheetLauncher(tester, settings: settings);
      await _openSheet(tester);

      // Start dragging from Low (index 2) toward High (index 4): after 7
      // pumped steps the thumb sits just past Medium (index ~3.4, rounding to
      // Medium). The last three steps are delivered without a frame in
      // between, and so is the release: a drag end must snap from the freshest
      // position (index 4, High) instead of the last rebuilt one.
      final start = tester.getCenter(
        find.byKey(const ValueKey('reasoning-stop-1024')),
      );
      final end = tester.getCenter(
        find.byKey(const ValueKey('reasoning-stop-32000')),
      );
      final dx = (end.dx - start.dx) / 10;
      final gesture = await tester.startGesture(start);
      await tester.pump(const Duration(milliseconds: 16));
      for (var i = 0; i < 7; i++) {
        await gesture.moveBy(Offset(dx, 0));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await gesture.moveBy(Offset(dx, 0));
      await gesture.moveBy(Offset(dx, 0));
      await gesture.moveBy(Offset(dx, 0));
      await gesture.up();
      await tester.pumpAndSettle();

      expect(settings.thinkingBudget, 32000);
    });

    testWidgets('exposes increase/decrease actions to screen readers', (
      tester,
    ) async {
      final settings = await _settingsForClaudeModel(
        tester,
        'claude-sonnet-4-5',
      );
      await _pumpSheetLauncher(tester, settings: settings);
      await _openSheet(tester);

      final slider = find.semantics.byAction(SemanticsAction.increase);
      expect(slider, findsOne);

      tester.semantics.performAction(slider, SemanticsAction.increase);
      await tester.pumpAndSettle();
      expect(settings.thinkingBudget, 1024);

      tester.semantics.performAction(slider, SemanticsAction.decrease);
      await tester.pumpAndSettle();
      expect(settings.thinkingBudget, -1);
    });

    testWidgets('does not write settings or trigger haptics on open', (
      tester,
    ) async {
      final settings = await _settingsForClaudeModel(
        tester,
        'claude-sonnet-4-5',
      );
      final haptic = _installHapticSpy(tester);
      await _pumpSheetLauncher(
        tester,
        settings: settings,
        initialBudget: 16000,
      );

      await _openSheet(tester);

      expect(settings.thinkingBudget, isNull);
      expect(haptic.selectionClicks, 0);
      expect(find.text('Medium'), findsOneWidget);
    });

    testWidgets('animates label layout when the level changes', (tester) async {
      final settings = await _settingsForClaudeModel(
        tester,
        'claude-sonnet-4-5',
      );
      await _pumpSheetLauncher(
        tester,
        settings: settings,
        initialBudget: 16000,
      );

      await _openSheet(tester);
      expect(find.text('Medium'), findsOneWidget);

      double iconX() => tester.getCenter(find.byType(SvgPicture).first).dx;
      final xs = <double>[iconX()];

      // Medium -> Low shrinks the title; the row must re-center over many
      // frames, not in a single jump.
      await tester.tapAt(
        tester.getCenter(find.byKey(const ValueKey('reasoning-stop-1024'))),
      );
      for (var i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 16));
        xs.add(iconX());
      }
      await tester.pumpAndSettle();

      expect(find.text('Low'), findsOneWidget);
      final movedFrames = <double>[];
      for (var i = 1; i < xs.length; i++) {
        if ((xs[i] - xs[i - 1]).abs() > 0.01) movedFrames.add(xs[i]);
      }
      expect(xs.first, isNot(closeTo(xs.last, 0.5)));
      // A jump would move exactly once; an animation moves over many frames.
      expect(movedFrames.length, greaterThan(3));
    });

    testWidgets('preserves custom budget flow from the custom row', (
      tester,
    ) async {
      final settings = await _settingsForClaudeModel(
        tester,
        'claude-sonnet-4-5',
      );
      await _pumpSheetLauncher(tester, settings: settings);
      await _openSheet(tester);

      await tester.tap(find.text('Custom Reasoning Budget'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), '3000');
      await tester.pump();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(settings.thinkingBudget, 3000);
      // Pill title + custom row label.
      expect(find.text('Custom Reasoning Budget'), findsNWidgets(2));
      // Pill subtitle + custom row trailing value.
      expect(find.text('3000'), findsNWidgets(2));
      // Sheet stays open after the dialog closes.
      expect(find.byKey(const ValueKey('reasoning-stop-1024')), findsOneWidget);
    });
  });
}
