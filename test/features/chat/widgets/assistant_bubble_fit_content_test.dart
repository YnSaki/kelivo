import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:Cuplivo/core/database/business_preferences.dart';
import 'package:Cuplivo/core/models/chat_message.dart';
import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/core/providers/tts_provider.dart';
import 'package:Cuplivo/features/chat/widgets/chat_message_widget.dart';
import 'package:Cuplivo/features/home/services/ask_user_interaction_service.dart';
import 'package:Cuplivo/features/home/services/tool_approval_service.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';

var businessPrefs = BusinessPreferences.memoryForTests();

SettingsProvider _createSettings({required bool fitContent}) {
  SharedPreferences.setMockInitialValues({});
  businessPrefs = BusinessPreferences.memoryForTests({
    'display_chat_message_background_style_v1': 'solid',
    if (fitContent) 'display_assistant_bubble_fit_content_v1': true,
  });
  return SettingsProvider(preferences: businessPrefs);
}

Widget _buildHarness({
  required SettingsProvider settings,
  required Widget child,
}) {
  return MultiProvider(
    providers: [
      Provider<BusinessPreferences>.value(value: businessPrefs),
      ChangeNotifierProvider<SettingsProvider>.value(value: settings),
      ChangeNotifierProvider(
        create: (_) => TtsProvider(preferences: businessPrefs),
      ),
      ChangeNotifierProvider(create: (_) => ToolApprovalService()),
      ChangeNotifierProvider(create: (_) => AskUserInteractionService()),
    ],
    child: MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: SingleChildScrollView(child: child)),
    ),
  );
}

Future<double> _bubbleWidth(
  WidgetTester tester, {
  required bool fitContent,
  bool waiting = false,
}) async {
  final settings = _createSettings(fitContent: fitContent);
  final message = ChatMessage(
    role: 'assistant',
    content: waiting ? '' : 'OK',
    conversationId: 'conversation-fit-content',
    isStreaming: waiting,
  );
  await tester.pumpWidget(
    _buildHarness(
      settings: settings,
      child: ChatMessageWidget(message: message, showModelIcon: false),
    ),
  );
  if (waiting) {
    await tester.pump();
    return tester
        .getSize(
          find
              .ancestor(
                of: find.byType(LoadingIndicator),
                matching: find.byType(DecoratedBox),
              )
              .first,
        )
        .width;
  }
  await tester.pumpAndSettle();
  return tester.getSize(find.byKey(ValueKey('assistant_${message.id}'))).width;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final fitContent in [false, true]) {
    for (final entry in {
      // The incremental blocks path needs streaming text of 512+ chars; the
      // short entry only proves the streaming->completed hand-off is stable.
      'short': 'OK',
      'paragraphs':
          '${'First paragraph with enough text to engage incremental blocks. ' * 10}\n\nSecond paragraph.',
      'wrapped': 'Long text that wraps across lines. ' * 30,
      // Many short single-line paragraphs stay under the available width, so
      // with fit-content enabled the streaming bubble genuinely hugs instead
      // of being stretched by the block column. A regression back to
      // full-width stretch breaks the equality assertion below.
      'many paragraphs': List.generate(
        17,
        (i) => 'Hug ${i + 1} sized to a single line.',
      ).join('\n\n'),
    }.entries) {
      testWidgets(
        '${entry.key} bubble keeps its size through streaming (fitContent=$fitContent)',
        (tester) async {
          final settings = _createSettings(fitContent: fitContent);
          final streaming = ValueNotifier(false);
          final identity = ValueNotifier(0);
          addTearDown(streaming.dispose);
          addTearDown(identity.dispose);
          await tester.pumpWidget(
            _buildHarness(
              settings: settings,
              child: ListenableBuilder(
                listenable: Listenable.merge([streaming, identity]),
                builder: (_, _) => ChatMessageWidget(
                  key: ValueKey(identity.value),
                  message: ChatMessage(
                    id: 'streaming-fit-content',
                    role: 'assistant',
                    content: entry.value,
                    conversationId: 'conversation-fit-content',
                    isStreaming: streaming.value,
                  ),
                  showModelIcon: false,
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          final content = find.byKey(
            const ValueKey('assistant_streaming-fit-content'),
          );
          final completedSize = tester.getSize(content);
          void expectCompletedSize() {
            final size = tester.getSize(content);
            // Separate paragraphs can omit the trailing letter spacing of
            // an inline newline; allow that subpixel difference only.
            expect(size.width, closeTo(completedSize.width, 0.1));
            expect(size.height, closeTo(completedSize.height, 0.1));
          }

          // Start a new widget so it takes the streaming path from frame one.
          identity.value++;
          streaming.value = true;
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 300));
          expectCompletedSize();

          streaming.value = false;
          await tester.pumpAndSettle();
          expectCompletedSize();
        },
      );
    }
  }

  testWidgets('fit-content option shrinks the assistant bubble to its text', (
    tester,
  ) async {
    final spanning = await _bubbleWidth(tester, fitContent: false);
    final hugging = await _bubbleWidth(tester, fitContent: true);
    expect(hugging, lessThan(spanning));
  });

  testWidgets('waiting bubble hugs the indicator too', (tester) async {
    final spanning = await _bubbleWidth(
      tester,
      fitContent: false,
      waiting: true,
    );
    final hugging = await _bubbleWidth(tester, fitContent: true, waiting: true);
    expect(hugging, lessThan(spanning));
  });
}
