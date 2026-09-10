import 'dart:async';

import 'package:Cuplivo/core/database/app_database.dart';
import 'package:Cuplivo/core/database/business_preferences.dart';
import 'package:Cuplivo/core/database/chat_database_repository.dart';
import 'package:Cuplivo/core/models/chat_input_data.dart';
import 'package:Cuplivo/core/models/chat_message.dart';
import 'package:Cuplivo/core/models/conversation.dart';
import 'package:Cuplivo/core/models/group_chat.dart';
import 'package:Cuplivo/core/providers/asr_provider.dart';
import 'package:Cuplivo/core/providers/assistant_provider.dart';
import 'package:Cuplivo/core/providers/group_chat_provider.dart';
import 'package:Cuplivo/core/providers/input_status_provider.dart';
import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/core/providers/user_provider.dart';
import 'package:Cuplivo/core/services/chat/chat_service.dart';
import 'package:Cuplivo/core/services/generation_engine.dart';
import 'package:Cuplivo/features/group_chat/widgets/group_chat_view.dart';
import 'package:Cuplivo/features/home/services/ask_user_interaction_service.dart';
import 'package:Cuplivo/features/home/services/input_draft_persistence.dart';
import 'package:Cuplivo/features/home/services/tool_approval_service.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

/// An initialized [ChatService] backed by an in-memory database.
///
/// The base [ChatService] methods read the private `_repo` field directly
/// (virtual dispatch does not apply), so the methods the flows under test
/// touch are overridden to write through the repository, mirroring the
/// desktop group-creation regression test. Conversations are also kept in a
/// memory map because the repository's sync connection (`getConversationSync`)
/// is unavailable for `NativeDatabase.memory()`; the map keeps
/// `getConversation`/`getCompleteConversation` faithful so the group
/// short-circuits (e.g. quick-instruction freeze) are exercised.
/// [gateQueue] deterministically holds `addMessage` calls (the user-message
/// persist of a send) so a test can stage the busy state; an empty queue
/// passes through immediately.
class _InMemoryChatService extends ChatService {
  late final AppDatabase db = AppDatabase(NativeDatabase.memory());
  late final ChatDatabaseRepository _testRepo = ChatDatabaseRepository(db);

  /// Conversations created through [createConversation]. The sync repo
  /// connection is null for in-memory databases, so these reads are served
  /// from the map instead.
  final Map<String, Conversation> _conversations = <String, Conversation>{};

  /// Consumed FIFO by [addMessage]. Enqueue a completer to hold the next
  /// user-message persist (a send reaches busy while it is pending).
  final List<Completer<void>> gateQueue = <Completer<void>>[];

  @override
  bool get initialized => true;

  @override
  ChatDatabaseRepository get repo => _testRepo;

  @override
  Future<Conversation> createConversation({
    String? title,
    String? assistantId,
    List<String>? mcpServerIds,
    String? parentConversationId,
    String conversationKind = Conversation.kindNormal,
    bool setAsCurrent = true,
    List<String>? persistentQuickInstructionIds,
  }) async {
    final conversation = Conversation(
      title: title ?? 'New Chat',
      assistantId: assistantId,
      mcpServerIds: mcpServerIds,
      parentConversationId: parentConversationId,
      conversationKind: conversationKind,
      persistentQuickInstructionIds: persistentQuickInstructionIds,
    );
    await _testRepo.putConversation(conversation);
    _conversations[conversation.id] = conversation;
    return conversation;
  }

  @override
  Conversation? getConversation(String id) {
    if (id.isEmpty) return null;
    return _conversations[id];
  }

  @override
  Conversation? getCompleteConversation(String id) {
    return _conversations[id];
  }

  @override
  Future<ChatMessage> addMessage({
    required String conversationId,
    required String role,
    required String content,
    String? modelId,
    String? providerId,
    int? totalTokens,
    bool isStreaming = false,
    String? reasoningText,
    DateTime? reasoningStartAt,
    DateTime? reasoningFinishedAt,
    String? groupId,
    String? subgroupId,
    int? version,
    bool isPreset = false,
    String? speakerAssistantId,
    String? quoteJson,
    String? quickInstructionInvocationsJson,
  }) async {
    if (gateQueue.isNotEmpty) {
      await gateQueue.removeAt(0).future;
    }
    final message = ChatMessage(
      role: role,
      content: content,
      conversationId: conversationId,
      modelId: modelId,
      providerId: providerId,
      totalTokens: totalTokens,
      isStreaming: isStreaming,
      reasoningText: reasoningText,
      reasoningStartAt: reasoningStartAt,
      reasoningFinishedAt: reasoningFinishedAt,
      groupId: groupId,
      subgroupId: subgroupId,
      version: version,
      isPreset: isPreset,
      speakerAssistantId: speakerAssistantId,
      quoteJson: quoteJson,
      quickInstructionInvocationsJson: quickInstructionInvocationsJson,
    );
    await _testRepo.putMessage(
      message,
      messageOrder: await _testRepo.getMessageCount(conversationId),
    );
    return message;
  }

  @override
  Future<void> updateMessage(
    String messageId, {
    String? content,
    int? totalTokens,
    int? contextTokens,
    bool? isStreaming,
    String? reasoningText,
    DateTime? reasoningStartAt,
    DateTime? reasoningFinishedAt,
    Object? translation = ChatMessage.sentinel,
    String? reasoningSegmentsJson,
    int? promptTokens,
    int? completionTokens,
    int? cachedTokens,
    int? durationMs,
    Object? groupId = ChatMessage.sentinel,
    Object? subgroupId = ChatMessage.sentinel,
    Object? version = ChatMessage.sentinel,
    Object? requestAllowImagesApiRouting = ChatMessage.sentinel,
    Object? requestExtraBody = ChatMessage.sentinel,
    Object? quickInstructionInvocationsJson = ChatMessage.sentinel,
  }) async {
    // Routing metadata only; irrelevant to the assertions here.
  }

  @override
  Future<void> bumpConversationUpdatedAt(String conversationId) async {}

  @override
  Future<void> deleteConversation(String id, {bool allowGroup = false}) async {
    await _testRepo.deleteConversation(id);
  }

  Future<void> closeDb() async {
    await _testRepo.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('GroupChatProvider pending queued input stash', () {
    test('stash and take round-trip per group', () {
      final provider = GroupChatProvider(chatService: ChatService());
      const input = ChatInputData(text: 'hello');
      const other = ChatInputData(text: 'other');

      provider.stashQueuedInput('group-1', input);
      provider.stashQueuedInput('group-2', other);

      expect(provider.takeQueuedInput('group-1')?.text, 'hello');
      // Take removes: a second take drains nothing.
      expect(provider.takeQueuedInput('group-1'), isNull);
      // Other groups are untouched.
      expect(provider.takeQueuedInput('group-2')?.text, 'other');
      expect(provider.takeQueuedInput('unknown'), isNull);
    });

    test('load() clears the in-memory stash', () async {
      final service = _InMemoryChatService();
      addTearDown(service.closeDb);
      final provider = GroupChatProvider(chatService: service);
      provider.stashQueuedInput('group-1', const ChatInputData(text: 'x'));

      await provider.load();

      expect(provider.takeQueuedInput('group-1'), isNull);
    });

    test('deleteGroup clears the stash of the deleted group', () async {
      final service = _InMemoryChatService();
      addTearDown(service.closeDb);
      final provider = GroupChatProvider(chatService: service);
      await provider.load();
      final group = await provider.createGroup(name: 'G');
      provider.stashQueuedInput(group.id, const ChatInputData(text: 'lost'));

      await provider.deleteGroup(group.id);

      expect(provider.takeQueuedInput(group.id), isNull);
    });
  });

  group('GroupChatView queued input session lifecycle', () {
    late _InMemoryChatService chatService;
    late GroupChatProvider provider;
    late GroupChat group;

    setUp(() async {
      chatService = _InMemoryChatService();
      addTearDown(chatService.closeDb);
      provider = GroupChatProvider(chatService: chatService);
      await provider.load();
      group = await provider.createGroup(name: 'G');
      // No assistants: a drained send reaches the round and ends with the
      // groupChatNoAssistants feedback - a deterministic, brief "round".
    });

    Future<void> imeSend(WidgetTester tester, String text) async {
      await tester.enterText(find.byType(TextField), text);
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await tester.pump();
      await tester.pump();
    }

    Future<void> pumpGroupView(WidgetTester tester) async {
      final businessPrefs = BusinessPreferences.memoryForTests();
      final settings = SettingsProvider(preferences: businessPrefs);
      await tester.runAsync(waitForSettingsLoad);
      addTearDown(settings.dispose);
      // Force the IME return key to submit (mobile default is newline) so
      // the busy-queue entry path (keyboard send while a round runs) is
      // drivable in the test.
      await tester.runAsync(() => settings.setEnterToSendOnMobile(true));

      await tester.pumpWidget(
        MultiProvider(
          providers: [
            Provider<BusinessPreferences>.value(value: businessPrefs),
            ChangeNotifierProvider<SettingsProvider>.value(value: settings),
            ChangeNotifierProvider<AssistantProvider>(
              create: (_) => AssistantProvider(preferences: businessPrefs),
            ),
            ChangeNotifierProvider<UserProvider>(
              create: (_) => UserProvider(preferences: businessPrefs),
            ),
            ChangeNotifierProvider<GroupChatProvider>.value(value: provider),
            ChangeNotifierProvider<ChatService>.value(value: chatService),
            ChangeNotifierProvider<GenerationEngine>(
              create: (_) => GenerationEngine(chatService: chatService),
            ),
            ChangeNotifierProvider<ToolApprovalService>(
              create: (_) => ToolApprovalService(),
            ),
            ChangeNotifierProvider<AskUserInteractionService>(
              create: (_) => AskUserInteractionService(),
            ),
            ChangeNotifierProvider<AsrProvider>(
              create: (_) => AsrProvider(settingsProvider: settings),
            ),
            ChangeNotifierProvider<InputStatusProvider>(
              create: (_) => InputStatusProvider(),
            ),
            Provider<InputDraftPersistence>(
              create: (_) => InputDraftPersistence(null),
            ),
          ],
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(body: GroupChatView(groupChatId: group.id)),
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets('a stashed send drains automatically on remount '
        '(issue #680 happy path)', (tester) async {
      await pumpGroupView(tester);

      // Leave (dispose the view, no queued input → no stash) and then stash
      // while no view is mounted: the fresh mount takes the stash and
      // auto-sends it.
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            Provider<BusinessPreferences>.value(
              value: BusinessPreferences.memoryForTests(),
            ),
          ],
          child: const MaterialApp(home: Scaffold(body: SizedBox())),
        ),
      );
      await tester.pump();
      provider.stashQueuedInput(group.id, const ChatInputData(text: 'B'));
      await pumpGroupView(tester);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(provider.takeQueuedInput(group.id), isNull);
      final messages = await chatService.repo.getMessagesRange(
        group.conversationId,
        start: 0,
        limit: 100,
      );
      expect(
        messages.any((m) => m.role == 'user' && m.content == 'B'),
        isTrue,
        reason: 'the stashed queued send must be sent after remount',
      );
      // The drained round ends with the groupChatNoAssistants feedback
      // snackbar; advance fake time past its timer and exit animation so
      // nothing is pending when the test tears the tree down.
      await tester.pump(const Duration(seconds: 3));
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets('a late stash from the disposing view is picked up while '
        'mounted (pop-animation race)', (tester) async {
      await pumpGroupView(tester);

      // The disposing route can outlive the new route's first frame during
      // the pop animation: the new view mounted first (mount-time take found
      // nothing) and the stash lands afterwards. The provider notification
      // must trigger a pickup in the already-mounted view.
      provider.stashQueuedInput(group.id, const ChatInputData(text: 'D'));
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pump(const Duration(milliseconds: 50));

      expect(provider.takeQueuedInput(group.id), isNull);
      final messages = await chatService.repo.getMessagesRange(
        group.conversationId,
        start: 0,
        limit: 100,
      );
      expect(
        messages.any((m) => m.role == 'user' && m.content == 'D'),
        isTrue,
        reason: 'a stash that lands after mount must still drain',
      );
      await tester.pump(const Duration(seconds: 3));
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets('a queued send is stashed on dispose instead of being '
        'silently dropped (issue #680)', (tester) async {
      await pumpGroupView(tester);

      // Gate the first send's user-message persist so the view stays busy.
      final gateA = Completer<void>();
      chatService.gateQueue.add(gateA);
      await imeSend(tester, 'A');
      expect(
        chatService.gateQueue,
        isEmpty,
        reason: 'A consumed the gate and is held',
      );

      // While busy, a second keyboard send enters the page-level slot.
      await imeSend(tester, 'B');

      // Release the gate while still mounted: A finishes, the drain hook
      // fires _send(B) which is held by the next gate. A's user message is
      // now persisted; B is in flight.
      final gateB = Completer<void>();
      chatService.gateQueue.add(gateB);
      gateA.complete();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      final messagesA = await chatService.repo.getMessagesRange(
        group.conversationId,
        start: 0,
        limit: 100,
      );
      expect(
        messagesA.any((m) => m.role == 'user' && m.content == 'A'),
        isTrue,
      );
      // A's round ended with the groupChatNoAssistants feedback snackbar;
      // advance fake time past its timer and exit animation before
      // queueing further sends.
      await tester.pump(const Duration(seconds: 3));
      await tester.pump(const Duration(seconds: 1));

      // Leave the page (route pop → dispose) while B runs and C is queued:
      // C must be stashed at session level instead of silently dropped.
      await imeSend(tester, 'C');
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();

      expect(
        provider.takeQueuedInput(group.id)?.text,
        'C',
        reason: 'dispose must stash the queued send',
      );
    });
  });
}

Future<void> waitForSettingsLoad() async {
  for (var i = 0; i < 25; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}
