import 'package:Cuplivo/core/database/business_preferences.dart';
import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';
import 'package:Cuplivo/shared/widgets/markdown_with_highlight.dart';
import 'package:Cuplivo/shared/widgets/sanitizing_selection_area.dart';
import 'package:Cuplivo/utils/markdown_subsequence_match.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The renderer only inserts soft-break ZWSPs into inline code segments of
/// 60+ chars (every 24 chars, see `_softBreakInline`).
final String _longToken = 'a' * 61;

Widget _harness(Widget child) {
  SharedPreferences.setMockInitialValues({});
  final prefs = BusinessPreferences.memoryForTests();
  return ChangeNotifierProvider(
    create: (_) => SettingsProvider(preferences: prefs),
    child: MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SanitizingSelectionArea(child: child),
        ),
      ),
    ),
  );
}

class _ClipboardRecorder {
  final List<MethodCall> calls = <MethodCall>[];

  void install(WidgetTester tester) {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        calls.add(call);
        return null;
      },
    );
    addTearDown(() {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      );
    });
  }

  String? copiedText() {
    for (final call in calls.reversed) {
      if (call.method == 'Clipboard.setData') {
        return (call.arguments as Map<Object?, Object?>)['text'] as String?;
      }
    }
    return null;
  }

  String? sharedText() {
    for (final call in calls.reversed) {
      if (call.method == 'Share.invoke') {
        return call.arguments as String?;
      }
    }
    return null;
  }
}

void main() {
  group('stripRendererInsertedCharacters', () {
    test('removes the characters the renderer inserts', () {
      expect(stripRendererInsertedCharacters('a\u200Bb\u200Bc'), 'abc');
      expect(stripRendererInsertedCharacters('1.\u200C\u5F15\u8A00'), '1.引言');
    });

    test('keeps other invisible characters', () {
      // ZWJ, LRM, RLM, BOM, soft hyphen, word joiner, invisible plus.
      const others = [0x200d, 0x200e, 0x200f, 0xfeff, 0x00ad, 0x2060, 0x2064];
      final input = String.fromCharCodes(others);
      expect(stripRendererInsertedCharacters('x${input}y'), 'x${input}y');
      expect(stripRendererInsertedCharacters(''), '');
    });

    test('keeps emoji ZWJ sequences intact', () {
      const womanTechnologist = '\u{1F469}\u200D\u{1F4BB}';
      const prideFlag = '\u{1F3F3}\uFE0F\u200D\u{1F308}';
      expect(
        stripRendererInsertedCharacters('coding $womanTechnologist $prideFlag'),
        'coding $womanTechnologist $prideFlag',
      );
    });

    test('keeps visible content intact', () {
      expect(
        stripRendererInsertedCharacters('plain text\nsecond line • \u{1F600}'),
        'plain text\nsecond line • \u{1F600}',
      );
    });
  });

  group('SanitizingSelectionArea', () {
    testWidgets('keyboard copy strips renderer-inserted zero-width breaks', (
      tester,
    ) async {
      final recorder = _ClipboardRecorder()..install(tester);
      await tester.pumpWidget(
        _harness(MarkdownWithCodeHighlight(text: 'Head `$_longToken` tail')),
      );
      await tester.pumpAndSettle();

      // Fixture sanity: the renderer really inserted soft-break ZWSPs.
      final codeText = tester.widget<Text>(find.textContaining('a' * 12));
      expect(codeText.data, isNotNull);
      expect(codeText.data!, contains('\u200B'));

      final context = tester.element(find.byType(MarkdownWithCodeHighlight));
      Actions.invoke(
        context,
        const SelectAllTextIntent(SelectionChangedCause.keyboard),
      );
      await tester.pump();
      Actions.invoke(context, CopySelectionTextIntent.copy);
      await tester.pump();

      expect(recorder.copiedText(), 'Head $_longToken tail');
    });

    testWidgets('keyboard copy without selection writes nothing', (
      tester,
    ) async {
      final recorder = _ClipboardRecorder()..install(tester);
      await tester.pumpWidget(_harness(const Text('plain')));
      await tester.pumpAndSettle();

      final context = tester.element(find.text('plain'));
      Actions.invoke(context, CopySelectionTextIntent.copy);
      await tester.pump();

      expect(recorder.copiedText(), isNull);
    });

    testWidgets('toolbar Copy button copies sanitized text', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final recorder = _ClipboardRecorder()..install(tester);
      const display = 'before \u200Btarget after';
      await tester.pumpWidget(_harness(const Text(display)));
      await tester.pumpAndSettle();

      final context = tester.element(find.text(display));
      Actions.invoke(
        context,
        const SelectAllTextIntent(SelectionChangedCause.keyboard),
      );
      await tester.pump();

      // Right-click on the selection keeps it and opens the default toolbar.
      await tester.tap(find.text(display), buttons: kSecondaryButton);
      await tester.pumpAndSettle();

      await tester.tap(find.text('Copy'));
      await tester.pumpAndSettle();

      expect(recorder.copiedText(), 'before target after');
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('toolbar Share button shares sanitized text', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final recorder = _ClipboardRecorder()..install(tester);
      const display = 'before \u200Btarget after';
      await tester.pumpWidget(_harness(const Text(display)));
      await tester.pumpAndSettle();

      final context = tester.element(find.text(display));
      Actions.invoke(
        context,
        const SelectAllTextIntent(SelectionChangedCause.keyboard),
      );
      await tester.pump();

      await tester.tap(find.text(display), buttons: kSecondaryButton);
      await tester.pumpAndSettle();

      await tester.tap(find.text('Share'));
      await tester.pumpAndSettle();

      expect(recorder.sharedText(), 'before target after');
      debugDefaultTargetPlatformOverride = null;
    });
  });
}
