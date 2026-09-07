import 'package:Cuplivo/core/models/chat_message.dart';
import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/core/services/streaming_content_notifier.dart';
import 'package:Cuplivo/features/chat/widgets/chat_message_widget.dart';
import 'package:Cuplivo/features/home/services/ask_user_interaction_service.dart';
import 'package:Cuplivo/features/home/services/tool_approval_service.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import '../../../support/business_test_harness.dart';

void main() {
  testWidgets(
    'retry countdown renders and announces the correct placeholder order '
    '("{seconds}s until retry ({attempt}/{maxRetries})")',
    (tester) async {
      final settings = await createBusinessTestPreferences();
      addTearDown(settings.dispose);

      await tester.pumpWidget(
        _buildHarness(
          settings,
          StatusInjectingMessage(
            message: ChatMessage(
              role: 'assistant',
              content: '',
              conversationId: 'c1',
              isStreaming: true,
            ),
            status: _status(attempt: 1, maxRetries: 3, seconds: 5),
          ),
        ),
      );

      // A few frames only: the 5s tween must stay at its begin value; do NOT
      // pumpAndSettle (that advances the countdown to zero).
      await tester.pump(const Duration(milliseconds: 10));
      await tester.pump(const Duration(milliseconds: 10));

      // Rendered countdown: 5s until retry (1/3) — args passed as
      // (attempt, maxRetries, seconds) matching the generated l10n signature.
      expect(find.text('5s until retry (1/3)'), findsOneWidget);
      // Accessibility announcement uses the same string (and the same
      // argument order) on the wrapping Semantics node.
      final sem = tester.widget<Semantics>(
        find
            .ancestor(
              of: find.text('5s until retry (1/3)'),
              matching: find.byType(Semantics),
            )
            .first,
      );
      expect(sem.properties.label, '5s until retry (1/3)');
    },
  );

  testWidgets('an empty streaming bubble shows the retry countdown', (
    tester,
  ) async {
    final settings = await createBusinessTestPreferences();
    addTearDown(settings.dispose);

    await tester.pumpWidget(
      _buildHarness(
        settings,
        StatusInjectingMessage(
          message: ChatMessage(
            role: 'assistant',
            content: '',
            conversationId: 'c1',
            isStreaming: true,
          ),
          status: _status(attempt: 2, maxRetries: 3, seconds: 5),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 10));

    expect(find.textContaining('until retry (2/3)'), findsOneWidget);
  });

  testWidgets('a retry after the first round keeps the countdown visible', (
    tester,
  ) async {
    final settings = await createBusinessTestPreferences();
    addTearDown(settings.dispose);

    await tester.pumpWidget(
      _buildHarness(
        settings,
        StatusInjectingMessage(
          message: ChatMessage(
            role: 'assistant',
            content: 'partial answer',
            conversationId: 'c1',
            isStreaming: true,
          ),
          status: _status(attempt: 2, maxRetries: 3, seconds: 5),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 10));

    expect(find.textContaining('partial answer'), findsOneWidget);
    expect(find.textContaining('until retry (2/3)'), findsOneWidget);
  });

  testWidgets('a retry between tool rounds keeps the countdown visible', (
    tester,
  ) async {
    final settings = await createBusinessTestPreferences();
    addTearDown(settings.dispose);

    await tester.pumpWidget(
      _buildHarness(
        settings,
        StatusInjectingMessage(
          message: ChatMessage(
            role: 'assistant',
            content: 'partial answer',
            conversationId: 'c1',
            isStreaming: true,
          ),
          status: _status(attempt: 2, maxRetries: 3, seconds: 5),
          reasoningSegments: const [
            ReasoningSegment(text: 'plan', expanded: true, loading: false),
          ],
          contentSplitOffsets: const [0],
          reasoningCountAtSplit: const [1],
          toolCountAtSplit: const [0],
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 10));

    expect(find.textContaining('partial answer'), findsOneWidget);
    expect(find.textContaining('until retry (2/3)'), findsOneWidget);
  });

  testWidgets('a tool-only round still shows the retry countdown', (
    tester,
  ) async {
    final settings = await createBusinessTestPreferences();
    addTearDown(settings.dispose);

    await tester.pumpWidget(
      _buildHarness(
        settings,
        StatusInjectingMessage(
          message: ChatMessage(
            role: 'assistant',
            content: '',
            conversationId: 'c1',
            isStreaming: true,
          ),
          status: _status(attempt: 2, maxRetries: 3, seconds: 5),
          toolParts: const [
            ToolUIPart(
              id: 'c1',
              toolName: 'lookup',
              arguments: {},
              content: 'ok',
            ),
          ],
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 10));

    expect(find.textContaining('lookup'), findsWidgets);
    expect(find.textContaining('until retry (2/3)'), findsOneWidget);
  });

  testWidgets('no countdown renders while the stream is healthy', (
    tester,
  ) async {
    final settings = await createBusinessTestPreferences();
    addTearDown(settings.dispose);

    await tester.pumpWidget(
      _buildHarness(
        settings,
        StatusInjectingMessage(
          message: ChatMessage(
            role: 'assistant',
            content: 'partial answer',
            conversationId: 'c1',
            isStreaming: true,
          ),
          status: null,
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 10));

    expect(find.textContaining('until retry'), findsNothing);
  });

  testWidgets('countdown disappears when the retry clears mid-stream', (
    tester,
  ) async {
    final settings = await createBusinessTestPreferences();
    addTearDown(settings.dispose);
    final message = ChatMessage(
      role: 'assistant',
      content: 'partial answer',
      conversationId: 'c1',
      isStreaming: true,
    );

    await tester.pumpWidget(
      _buildHarness(
        settings,
        StatusInjectingMessage(
          message: message,
          status: _status(attempt: 2, maxRetries: 3, seconds: 5),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 10));
    expect(find.textContaining('until retry (2/3)'), findsOneWidget);

    await tester.pumpWidget(
      _buildHarness(
        settings,
        StatusInjectingMessage(message: message, status: null),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 10));
    expect(find.textContaining('until retry'), findsNothing);
  });

  testWidgets('hideStreamingIndicator suppresses the countdown while retry '
      'waits', (tester) async {
    final settings = await createBusinessTestPreferences();
    addTearDown(settings.dispose);

    await tester.pumpWidget(
      _buildHarness(
        settings,
        StatusInjectingMessage(
          message: ChatMessage(
            role: 'assistant',
            content: 'partial answer',
            conversationId: 'c1',
            isStreaming: true,
          ),
          status: _status(attempt: 2, maxRetries: 3, seconds: 5),
          hideStreamingIndicator: true,
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 10));

    expect(find.textContaining('partial answer'), findsOneWidget);
    expect(find.textContaining('until retry'), findsNothing);
    expect(find.byType(LoadingIndicator), findsNothing);
  });
}

/// Injects the live [RetryStatus] into an otherwise minimal streaming message
/// (RetryStatus holds a mutable DateTime, so the outer tree stays const where
/// possible).
class StatusInjectingMessage extends StatelessWidget {
  const StatusInjectingMessage({
    super.key,
    required this.message,
    required this.status,
    this.reasoningSegments,
    this.contentSplitOffsets,
    this.reasoningCountAtSplit,
    this.toolCountAtSplit,
    this.toolParts,
    this.hideStreamingIndicator = false,
  });

  final ChatMessage message;
  final RetryStatus? status;
  final List<ReasoningSegment>? reasoningSegments;
  final List<int>? contentSplitOffsets;
  final List<int>? reasoningCountAtSplit;
  final List<int>? toolCountAtSplit;
  final List<ToolUIPart>? toolParts;
  final bool hideStreamingIndicator;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SingleChildScrollView(
        child: ChatMessageWidget(
          message: message,
          retryStatus: status,
          reasoningSegments: reasoningSegments,
          contentSplitOffsets: contentSplitOffsets,
          reasoningCountAtSplit: reasoningCountAtSplit,
          toolCountAtSplit: toolCountAtSplit,
          toolParts: toolParts,
          hideStreamingIndicator: hideStreamingIndicator,
        ),
      ),
    );
  }
}

RetryStatus _status({
  required int attempt,
  required int maxRetries,
  required int seconds,
}) {
  return RetryStatus(
    attempt: attempt,
    maxRetries: maxRetries,
    retryAt: DateTime.now().add(Duration(seconds: seconds)),
  );
}

Widget _buildHarness(SettingsProvider settings, Widget child) {
  return MultiProvider(
    providers: [
      ChangeNotifierProvider<SettingsProvider>.value(value: settings),
      ChangeNotifierProvider(create: (_) => ToolApprovalService()),
      ChangeNotifierProvider(create: (_) => AskUserInteractionService()),
    ],
    child: MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: child,
    ),
  );
}
