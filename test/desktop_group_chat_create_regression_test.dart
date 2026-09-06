import 'package:Cuplivo/core/database/app_database.dart';
import 'package:Cuplivo/core/database/business_preferences.dart';
import 'package:Cuplivo/core/database/chat_database_repository.dart';
import 'package:Cuplivo/core/models/conversation.dart';
import 'package:Cuplivo/core/providers/assistant_provider.dart';
import 'package:Cuplivo/core/providers/group_chat_provider.dart';
import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/core/providers/user_provider.dart';
import 'package:Cuplivo/core/services/chat/chat_service.dart';
import 'package:Cuplivo/desktop/desktop_settings_page.dart';
import 'package:Cuplivo/features/group_chat/pages/group_chat_settings_page.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

var businessPrefs = BusinessPreferences.memoryForTests();

/// A [ChatService] backed by an in-memory database. Drift on
/// [NativeDatabase.memory] executes on the calling isolate, so every query
/// settles within the microtask pumps of `testWidgets` (no `runAsync` needed
/// for the group-creation flow).
///
/// Only the members the desktop group-creation flow touches are overridden:
/// the base [ChatService._saveConversation] reads the private `_repo` field
/// directly (virtual dispatch does not apply), so `createConversation` is
/// also overridden to write through the repository.
class _InMemoryChatService extends ChatService {
  late final AppDatabase db = AppDatabase(NativeDatabase.memory());
  late final ChatDatabaseRepository _testRepo = ChatDatabaseRepository(db);

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
  }) async {
    final conversation = Conversation(
      title: title ?? 'New Chat',
      assistantId: assistantId,
      mcpServerIds: mcpServerIds,
      parentConversationId: parentConversationId,
      conversationKind: conversationKind,
    );
    await _testRepo.putConversation(conversation);
    return conversation;
  }

  Future<void> closeDb() async {
    await _testRepo.close();
  }
}

Future<void> _waitForSettingsLoad() async {
  for (var i = 0; i < 25; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

Widget _harness(SettingsProvider settings, _InMemoryChatService chatService) {
  return MultiProvider(
    providers: [
      Provider<BusinessPreferences>.value(value: businessPrefs),
      ChangeNotifierProvider<SettingsProvider>.value(value: settings),
      ChangeNotifierProvider<AssistantProvider>(
        create: (_) => AssistantProvider(preferences: businessPrefs),
      ),
      ChangeNotifierProvider<UserProvider>(
        create: (_) => UserProvider(preferences: businessPrefs),
      ),
      ChangeNotifierProvider<GroupChatProvider>(
        create: (_) => GroupChatProvider(chatService: chatService),
      ),
    ],
    child: MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: const Scaffold(body: DesktopSettingsPage()),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('desktop group chat creation completes without controller '
      'use-after-dispose (issue #698)', (tester) async {
    businessPrefs = BusinessPreferences.memoryForTests();
    final settings = SettingsProvider(preferences: businessPrefs);
    await tester.runAsync(_waitForSettingsLoad);
    addTearDown(settings.dispose);

    final chatService = _InMemoryChatService();
    addTearDown(chatService.closeDb);

    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(_harness(settings, chatService));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();

    final l10n = AppLocalizations.of(
      tester.element(find.byType(DesktopSettingsPage)),
    )!;

    // Open the assistants / group-chats pane.
    await tester.tap(find.text(l10n.settingsPageAssistant));
    await tester.pumpAndSettle();

    // Open the create group-chat dialog, type a name, confirm.
    await tester.tap(find.byTooltip(l10n.groupChatCreate));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.descendant(
        of: find.byType(Dialog),
        matching: find.byType(TextField),
      ),
      'Automated Group',
    );
    await tester.pump();

    await tester.tap(find.text(l10n.groupChatConfirm));
    // Pump through the dialog dismissal AND the settings-page push:
    // the pre-fix code disposed the TextEditingController as soon as the
    // dialog future completed, throwing a use-after-dispose during the
    // exit transition (plus a null return that skipped createGroup).
    await tester.pumpAndSettle();

    // 1) No framework exception — in particular no use-after-dispose.
    expect(tester.takeException(), isNull);

    // 2) The group was created exactly once with the entered name.
    final groups = await chatService.repo.getAllGroupChats();
    expect(groups, hasLength(1));
    expect(groups.single.name, 'Automated Group');
    // Async lookup via the Drift connection; the sync connection path
    // requires a file-backed database (in-memory repos have none).
    final conversation = await chatService.repo.getConversation(
      groups.single.conversationId,
    );
    expect(conversation, isNotNull);
    expect(conversation!.title, 'Automated Group');
    expect(conversation.conversationKind, Conversation.kindGroup);

    // 3) The group settings destination was reached.
    expect(find.byType(GroupChatSettingsPage), findsOneWidget);
  });
}
