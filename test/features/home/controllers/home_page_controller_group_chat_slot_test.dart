import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:Cuplivo/core/database/app_database.dart';
import 'package:Cuplivo/core/database/business_preferences.dart';
import 'package:Cuplivo/core/database/chat_database_repository.dart';
import 'package:Cuplivo/core/models/conversation.dart';
import 'package:Cuplivo/core/providers/assistant_provider.dart';
import 'package:Cuplivo/core/providers/group_chat_provider.dart';
import 'package:Cuplivo/core/providers/mcp_provider.dart';
import 'package:Cuplivo/core/providers/quick_instruction_provider.dart';
import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/core/services/chat/chat_service.dart';
import 'package:Cuplivo/core/services/generation_engine.dart';
import 'package:Cuplivo/desktop/group_chat_navigation_bus.dart';
import 'package:Cuplivo/features/home/controllers/home_page_controller.dart';
import 'package:Cuplivo/features/home/widgets/chat_input_bar.dart';
import 'package:Cuplivo/features/home/widgets/quick_instruction_editing_controller.dart';

/// A [ChatService] backed by an in-memory database (same pattern as
/// desktop_group_chat_create_regression_test.dart). Drift on
/// [NativeDatabase.memory] executes on the calling isolate, so queries
/// settle within the microtask pumps of `testWidgets`.
///
/// Only the members the group-creation / deletion flow touches are
/// overridden: the base [ChatService._saveConversation] and the delete path
/// read the private `_repo` field directly (virtual dispatch does not
/// apply), and the base implementations would call `_doInit`
/// (path_provider) which has no plugin implementation under test.
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
    return conversation;
  }

  @override
  Future<void> deleteConversation(String id, {bool allowGroup = false}) async {
    await _testRepo.deleteConversation(id);
  }

  Future<void> closeDb() async {
    await _testRepo.close();
  }
}

class _ControllerHost extends StatefulWidget {
  const _ControllerHost({required this.onReady});

  final ValueChanged<HomePageController> onReady;

  @override
  State<_ControllerHost> createState() => _ControllerHostState();
}

class _ControllerHostState extends State<_ControllerHost>
    with SingleTickerProviderStateMixin {
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  final GlobalKey _inputBarKey = GlobalKey();
  final FocusNode _inputFocus = FocusNode();
  final QuickInstructionEditingController _inputController =
      QuickInstructionEditingController();
  final ChatInputBarController _mediaController = ChatInputBarController();
  final ScrollController _scrollController = ScrollController();
  late final HomePageController _controller;

  @override
  void initState() {
    super.initState();
    _controller = HomePageController(
      context: context,
      vsync: this,
      scaffoldKey: _scaffoldKey,
      inputBarKey: _inputBarKey,
      inputFocus: _inputFocus,
      inputController: _inputController,
      mediaController: _mediaController,
      scrollController: _scrollController,
    );
    widget.onReady(_controller);
  }

  @override
  Widget build(BuildContext context) => Scaffold(key: _scaffoldKey);

  @override
  void dispose() {
    _controller.dispose();
    _inputFocus.dispose();
    _inputController.dispose();
    _scrollController.dispose();
    super.dispose();
  }
}

class _Harness {
  _Harness({
    required this.controller,
    required this.chatService,
    required this.settings,
    required this.assistants,
    required this.quickInstructions,
    required this.mcp,
    required this.engine,
    required this.groupChats,
  });

  final HomePageController controller;
  final _InMemoryChatService chatService;
  final SettingsProvider settings;
  final AssistantProvider assistants;
  final QuickInstructionProvider quickInstructions;
  final McpProvider mcp;
  final GenerationEngine engine;
  final GroupChatProvider groupChats;

  Future<void> dispose(WidgetTester tester) async {
    await tester.pump(const Duration(milliseconds: 150));
    await tester.pumpWidget(const SizedBox.shrink());
    engine.dispose();
    mcp.dispose();
    quickInstructions.dispose();
    assistants.dispose();
    settings.dispose();
    groupChats.dispose();
    await chatService.closeDb();
  }
}

Future<_Harness> _pumpHarness(WidgetTester tester) async {
  SharedPreferences.setMockInitialValues(const <String, Object>{});
  final preferences = BusinessPreferences.memoryForTests();
  final chatService = _InMemoryChatService();

  late final SettingsProvider settings;
  late final QuickInstructionProvider quickInstructions;
  late final GroupChatProvider groupChats;
  await tester.runAsync(() async {
    settings = SettingsProvider(preferences: preferences);
    await settings.loaded;
    quickInstructions = QuickInstructionProvider(preferences: preferences);
    await quickInstructions.initialize();
    groupChats = GroupChatProvider(chatService: chatService);
    await groupChats.load();
  });

  final assistants = AssistantProvider(preferences: preferences);

  late BuildContext providerContext;
  final mcp = McpProvider(
    preferences: preferences,
    contextProvider: () => providerContext,
  );
  final engine = GenerationEngine(chatService: chatService);

  HomePageController? controller;
  await tester.pumpWidget(
    MaterialApp(
      home: MultiProvider(
        providers: [
          Provider<BusinessPreferences>.value(value: preferences),
          ChangeNotifierProvider<ChatService>.value(value: chatService),
          ChangeNotifierProvider<SettingsProvider>.value(value: settings),
          ChangeNotifierProvider<AssistantProvider>.value(value: assistants),
          ChangeNotifierProvider<QuickInstructionProvider>.value(
            value: quickInstructions,
          ),
          ChangeNotifierProvider<McpProvider>.value(value: mcp),
          ChangeNotifierProvider<GenerationEngine>.value(value: engine),
          ChangeNotifierProvider<GroupChatProvider>.value(value: groupChats),
        ],
        child: Builder(
          builder: (context) {
            providerContext = context;
            return _ControllerHost(onReady: (value) => controller = value);
          },
        ),
      ),
    ),
  );
  await tester.pump();
  return _Harness(
    controller: controller!,
    chatService: chatService,
    settings: settings,
    assistants: assistants,
    quickInstructions: quickInstructions,
    mcp: mcp,
    engine: engine,
    groupChats: groupChats,
  );
}

/// Sets the debug platform override for the duration of [body] and restores
/// it before the body returns (flutter_test verifies foundation debug vars
/// right after the test body, before addTearDown callbacks run).
Future<void> _withPlatform(
  TargetPlatform platform,
  Future<void> Function() body,
) async {
  debugDefaultTargetPlatformOverride = platform;
  try {
    await body();
  } finally {
    debugDefaultTargetPlatformOverride = null;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('desktop: bus open shows the slot, exit hides but retains the '
      'selected group (background round keeps running)', (tester) async {
    await _withPlatform(TargetPlatform.macOS, () async {
      final harness = await _pumpHarness(tester);
      addTearDown(() => harness.dispose(tester));

      GroupChatNavigationBus.instance.openGroupChat('group-a');
      await tester.pump();
      expect(harness.controller.activeGroupChatId, 'group-a');
      expect(harness.controller.isGroupChatMode, isTrue);

      GroupChatNavigationBus.instance.exitGroupChat();
      await tester.pump();
      expect(harness.controller.isGroupChatMode, isFalse);
      expect(harness.controller.activeGroupChatId, 'group-a');

      // Re-entering shows the retained (still mounted) view again.
      GroupChatNavigationBus.instance.openGroupChat('group-a');
      await tester.pump();
      expect(harness.controller.isGroupChatMode, isTrue);
      expect(harness.controller.activeGroupChatId, 'group-a');
    });
  });

  testWidgets('desktop: opening a different group keeps the first alive and '
      'switches back and forth', (tester) async {
    await _withPlatform(TargetPlatform.macOS, () async {
      final harness = await _pumpHarness(tester);
      addTearDown(() => harness.dispose(tester));

      GroupChatNavigationBus.instance.openGroupChat('group-a');
      await tester.pump();
      GroupChatNavigationBus.instance.openGroupChat('group-b');
      await tester.pump();
      expect(harness.controller.activeGroupChatId, 'group-b');
      expect(harness.controller.isGroupChatMode, isTrue);
      // Both stay mounted (rounds keep running in the background).
      expect(harness.controller.openedGroupChatIds, ['group-a', 'group-b']);

      // Switching back to the previously opened group reuses its live view.
      GroupChatNavigationBus.instance.openGroupChat('group-a');
      await tester.pump();
      expect(harness.controller.activeGroupChatId, 'group-a');
      expect(harness.controller.isGroupChatMode, isTrue);
      expect(harness.controller.openedGroupChatIds, ['group-a', 'group-b']);
    });
  });

  testWidgets('desktop: entering global search leaves the group slot', (
    tester,
  ) async {
    await _withPlatform(TargetPlatform.macOS, () async {
      final harness = await _pumpHarness(tester);
      addTearDown(() => harness.dispose(tester));

      GroupChatNavigationBus.instance.openGroupChat('group-a');
      await tester.pump();
      expect(harness.controller.isGroupChatMode, isTrue);

      harness.controller.enterGlobalSearchMode(preserveQuery: false);
      await tester.pump();
      expect(harness.controller.isGroupChatMode, isFalse);
    });
  });

  testWidgets('desktop: deleting the active group drops the whole slot', (
    tester,
  ) async {
    await _withPlatform(TargetPlatform.macOS, () async {
      final harness = await _pumpHarness(tester);
      addTearDown(() => harness.dispose(tester));

      final group = (await tester.runAsync(
        () => harness.groupChats.createGroup(name: 'Doomed Group'),
      ))!;
      await tester.pump();

      GroupChatNavigationBus.instance.openGroupChat(group.id);
      await tester.pump();
      expect(harness.controller.activeGroupChatId, group.id);

      await tester.runAsync(() => harness.groupChats.deleteGroup(group.id));
      await tester.pump();
      expect(harness.controller.activeGroupChatId, isNull);
      expect(harness.controller.isGroupChatMode, isFalse);
      expect(harness.controller.openedGroupChatIds, isEmpty);
    });
  });

  testWidgets('desktop: deleting a background group drops only that group', (
    tester,
  ) async {
    await _withPlatform(TargetPlatform.macOS, () async {
      final harness = await _pumpHarness(tester);
      addTearDown(() => harness.dispose(tester));

      final doomed = (await tester.runAsync(
        () => harness.groupChats.createGroup(name: 'Doomed Background'),
      ))!;
      final current = (await tester.runAsync(
        () => harness.groupChats.createGroup(name: 'Current Group'),
      ))!;
      await tester.pump();

      GroupChatNavigationBus.instance.openGroupChat(doomed.id);
      await tester.pump();
      GroupChatNavigationBus.instance.openGroupChat(current.id);
      await tester.pump();
      expect(harness.controller.activeGroupChatId, current.id);

      await tester.runAsync(() => harness.groupChats.deleteGroup(doomed.id));
      await tester.pump();
      expect(harness.controller.activeGroupChatId, current.id);
      expect(harness.controller.isGroupChatMode, isTrue);
      expect(harness.controller.openedGroupChatIds, hasLength(1));
    });
  });

  testWidgets('non-desktop: bus events never activate the slot', (
    tester,
  ) async {
    await _withPlatform(TargetPlatform.android, () async {
      final harness = await _pumpHarness(tester);
      addTearDown(() => harness.dispose(tester));

      GroupChatNavigationBus.instance.openGroupChat('group-a');
      await tester.pump();
      expect(harness.controller.activeGroupChatId, isNull);
      expect(harness.controller.isGroupChatMode, isFalse);
    });
  });
}
