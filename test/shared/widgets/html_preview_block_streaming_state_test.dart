import 'package:Cuplivo/core/database/business_preferences.dart';
import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';
import 'package:Cuplivo/shared/widgets/html_preview_block.dart';
import 'package:Cuplivo/shared/widgets/markdown_with_highlight.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

/// Streaming HTML fences must not remount `HtmlPreviewBlock` on every chunk:
/// the preprocessing token embeds the content length and hash, so the
/// tokenized payload changes non-appending while the raw fence source only
/// grows. A remount restarts the preview spinner and resets the selected tab
/// (issue #706 follow-up).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Widget harness(ValueListenable<String> html) {
    final businessPrefs = BusinessPreferences.memoryForTests();
    return ChangeNotifierProvider(
      create: (_) => SettingsProvider(preferences: businessPrefs),
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: ValueListenableBuilder<String>(
            valueListenable: html,
            builder: (context, value, _) =>
                MarkdownWithCodeHighlight(text: value, streaming: true),
          ),
        ),
      ),
    );
  }

  testWidgets('HtmlPreviewBlock keeps its state while a stream grows', (
    tester,
  ) async {
    final html = ValueNotifier<String>('```html\n<div>\n  <p>hello</p>');
    addTearDown(html.dispose);
    await tester.pumpWidget(harness(html));
    await tester.pump();

    final blockFinder = find.byType(HtmlPreviewBlock);
    expect(blockFinder, findsOneWidget);
    final blockState = tester.state<State<HtmlPreviewBlock>>(blockFinder);
    final spinner = find.byType(CircularProgressIndicator);
    expect(spinner, findsOneWidget);
    final spinnerElement = tester.element(spinner);

    html.value += '\n  <p>more</p>';
    await tester.pump();
    await tester.pump();

    expect(
      tester.state<State<HtmlPreviewBlock>>(blockFinder),
      same(blockState),
    );
    expect(
      tester.element(find.byType(CircularProgressIndicator)),
      same(spinnerElement),
    );
  });

  testWidgets('HtmlPreviewBlock keeps the user-selected tab while streaming', (
    tester,
  ) async {
    final html = ValueNotifier<String>('```html\n<div>\n  <p>hello</p>');
    addTearDown(html.dispose);
    await tester.pumpWidget(harness(html));
    await tester.pump();

    final blockFinder = find.byType(HtmlPreviewBlock);
    final blockState = tester.state<State<HtmlPreviewBlock>>(blockFinder);

    await tester.tap(find.text('Code'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('html-code-body')), findsOneWidget);

    html.value += '\n  <p>even more</p>';
    await tester.pump();
    await tester.pumpAndSettle();

    expect(
      tester.state<State<HtmlPreviewBlock>>(blockFinder),
      same(blockState),
    );
    expect(find.byKey(const ValueKey('html-code-body')), findsOneWidget);
  });
}
