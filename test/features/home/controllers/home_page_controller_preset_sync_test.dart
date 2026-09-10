import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import 'package:Cuplivo/core/database/business_preferences.dart';
import 'package:Cuplivo/core/models/assistant.dart';
import 'package:Cuplivo/core/models/preset_message.dart';
import 'package:Cuplivo/core/providers/assistant_provider.dart';
import 'package:Cuplivo/core/providers/group_chat_provider.dart';
import 'package:Cuplivo/core/providers/mcp_provider.dart';
import 'package:Cuplivo/core/providers/quick_instruction_provider.dart';
import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/core/services/chat/chat_service.dart';
import 'package:Cuplivo/core/services/generation_engine.dart';
import 'package:Cuplivo/features/home/controllers/home_page_controller.dart';
import 'package:Cuplivo/features/home/widgets/chat_input_bar.dart';
import 'package:Cuplivo/features/home/widgets/quick_instruction_editing_controller.dart';

class _FakePathProviderPlatform extends PathProviderPlatform {
  _FakePathProviderPlatform(this.path);

  final String path;

  @override
  Future<String?> getApplicationDocumentsPath() async => path;

  @override
  Future<String?> getApplicationSupportPath() async => path;

  @override
  Future<String?> getApplicationCachePath() async => '$path/cache';

  @override
  Future<String?> getTemporaryPath() async => '$path/tmp';
}

/// Lets a test force the next preset rewrite to throw, exercising the
/// banner's failure-restore path.
class _FailingPresetSyncService extends ChatService {
  bool failPresetSync = false;

  @override
  Future<bool> syncPresetMessages({
    required String conversationId,
    required List<Map<String, String>> presets,
  }) {
    if (failPresetSync) {
      throw StateError('preset sync failure (test)');
    }
    return super.syncPresetMessages(
      conversationId: conversationId,
      presets: presets,
    );
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
    required this.tempDir,
  });

  final HomePageController controller;
  final ChatService chatService;
  final SettingsProvider settings;
  final AssistantProvider assistants;
  final QuickInstructionProvider quickInstructions;
  final McpProvider mcp;
  final GenerationEngine engine;
  final GroupChatProvider groupChats;
  final Directory tempDir;

  /// The chat service is backed by a real file database whose queries do not
  /// settle inside testWidgets' fake-async zone, so every scenario body that
  /// touches it must run through [WidgetTester.runAsync] (see main()).
  Future<void> dispose(WidgetTester tester) async {
    await tester.runAsync(() async {
      await chatService.close();
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });
    await tester.pump(const Duration(milliseconds: 150));
    await tester.pumpWidget(const SizedBox.shrink());
    engine.dispose();
    mcp.dispose();
    quickInstructions.dispose();
    assistants.dispose();
    settings.dispose();
    groupChats.dispose();
  }

  /// Real-time condition poll so the controller's unawaited
  /// AssistantProvider listener (repo I/O included) settles before
  /// assertions. Only valid inside a `tester.runAsync` body.
  Future<void> settleFor(
    bool Function() condition, {
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (condition()) return;
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    fail('condition not met within ${timeout.inMilliseconds}ms');
  }
}

Future<_Harness> _pumpHarness(
  WidgetTester tester, {
  ChatService Function()? createService,
}) async {
  SharedPreferences.setMockInitialValues(const <String, Object>{});
  final preferences = BusinessPreferences.memoryForTests();

  late final Directory tempDir;
  late final ChatService chatService;
  late final SettingsProvider settings;
  late final QuickInstructionProvider quickInstructions;
  late final GroupChatProvider groupChats;
  await tester.runAsync(() async {
    tempDir = await Directory.systemTemp.createTemp('preset_sync_ctrl_');
    PathProviderPlatform.instance = _FakePathProviderPlatform(tempDir.path);
    chatService = (createService ?? ChatService.new)();
    await chatService.init();
    settings = SettingsProvider(preferences: preferences);
    await settings.loaded;
    quickInstructions = QuickInstructionProvider(preferences: preferences);
    await quickInstructions.initialize();
    groupChats = GroupChatProvider(chatService: chatService);
    await groupChats.load();
  });

  // chatService is wired so the cold-start load path (`ensureLoaded` →
  // `notifyListeners`) exercises the preset-change listener like production.
  final assistants = AssistantProvider(
    preferences: preferences,
    chatService: chatService,
  );

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
    tempDir: tempDir,
  );
}

Future<String> _addAssistant(
  _Harness harness,
  String name,
  List<PresetMessage> presets,
) async {
  final id = await harness.assistants.addAssistant(name: name);
  final assistant = harness.assistants.getById(id)!;
  await harness.assistants.updateAssistant(
    assistant.copyWith(presetMessages: presets),
  );
  return id;
}

Future<String> _newConversation(
  _Harness harness,
  String title,
  String assistantId, {
  String? presetContent,
  String? realContent,
}) async {
  final convo = await harness.chatService.createConversation(
    title: title,
    assistantId: assistantId,
  );
  if (presetContent != null) {
    await harness.chatService.addMessage(
      conversationId: convo.id,
      role: 'user',
      content: presetContent,
      isPreset: true,
    );
  }
  if (realContent != null) {
    await harness.chatService.addMessage(
      conversationId: convo.id,
      role: 'user',
      content: realContent,
    );
  }
  return convo.id;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('preset change on a fresh current conversation self-syncs', (
    tester,
  ) async {
    final harness = await _pumpHarness(tester);
    addTearDown(() => harness.dispose(tester));

    await tester.runAsync(() async {
      final a1 = await _addAssistant(harness, 'A1', [
        PresetMessage(role: 'user', content: 'v1'),
      ]);
      final convoId = await _newConversation(harness, 'Fresh', a1);
      harness.controller.chatController.setCurrentConversation(
        harness.chatService.getConversation(convoId),
      );
      await harness.settleFor(
        () =>
            harness.chatService.getMessages(convoId).isEmpty &&
            harness.controller.currentConversation?.id == convoId,
      );

      final assistant = harness.assistants.getById(a1)!;
      await harness.assistants.updateAssistant(
        assistant.copyWith(
          presetMessages: [PresetMessage(role: 'user', content: 'v2')],
        ),
      );
      await harness.settleFor(
        () => harness.chatService
            .getMessages(convoId)
            .any((m) => m.content == 'v2'),
      );

      expect(harness.chatService.getMessages(convoId).map((m) => m.content), [
        'v2',
      ]);
      expect(harness.controller.showPresetSyncBanner, isFalse);
    });
  });

  testWidgets('preset change on a conversation with history raises the banner; '
      'apply-here rewrites presets at the top', (tester) async {
    final harness = await _pumpHarness(tester);
    addTearDown(() => harness.dispose(tester));

    await tester.runAsync(() async {
      final a1 = await _addAssistant(harness, 'A1', [
        PresetMessage(role: 'user', content: 'v1'),
      ]);
      final convoId = await _newConversation(
        harness,
        'History',
        a1,
        presetContent: 'old preset',
        realContent: 'hello',
      );
      harness.controller.chatController.setCurrentConversation(
        harness.chatService.getConversation(convoId),
      );
      await harness.settleFor(
        () => harness.controller.currentConversation?.id == convoId,
      );

      final assistant = harness.assistants.getById(a1)!;
      await harness.assistants.updateAssistant(
        assistant.copyWith(
          presetMessages: [PresetMessage(role: 'user', content: 'v2')],
        ),
      );
      await harness.settleFor(() => harness.controller.showPresetSyncBanner);

      expect(harness.controller.showPresetSyncBanner, isTrue);
      // Nothing written until the user acts.
      expect(harness.chatService.getMessages(convoId).map((m) => m.content), [
        'old preset',
        'hello',
      ]);

      await harness.controller.applyPresetsToCurrentConversation();
      await harness.settleFor(
        () =>
            harness.chatService
                .getMessages(convoId)
                .map((m) => m.content)
                .toString() ==
            '(v2, hello)',
      );

      final messages = harness.chatService.getMessages(convoId);
      expect(messages.map((m) => m.content), ['v2', 'hello']);
      expect(messages.first.isPreset, isTrue);
      expect(messages.last.isPreset, isFalse);
      expect(harness.controller.showPresetSyncBanner, isFalse);
    });
  });

  testWidgets('apply-to-all rewrites every conversation of the assistant', (
    tester,
  ) async {
    final harness = await _pumpHarness(tester);
    addTearDown(() => harness.dispose(tester));

    await tester.runAsync(() async {
      final a1 = await _addAssistant(harness, 'A1', [
        PresetMessage(role: 'user', content: 'v1'),
      ]);
      final a2 = await _addAssistant(harness, 'A2', const <PresetMessage>[]);
      final historyId = await _newConversation(
        harness,
        'History',
        a1,
        presetContent: 'old preset',
        realContent: 'hello',
      );
      final freshId = await _newConversation(harness, 'Fresh', a1);
      final foreignId = await _newConversation(
        harness,
        'Foreign',
        a2,
        realContent: 'do not touch',
      );
      harness.controller.chatController.setCurrentConversation(
        harness.chatService.getConversation(historyId),
      );
      await harness.settleFor(
        () => harness.controller.currentConversation?.id == historyId,
      );

      final assistant = harness.assistants.getById(a1)!;
      await harness.assistants.updateAssistant(
        assistant.copyWith(
          presetMessages: [PresetMessage(role: 'user', content: 'v2')],
        ),
      );
      await harness.settleFor(() => harness.controller.showPresetSyncBanner);
      expect(harness.controller.showPresetSyncBanner, isTrue);

      final result = await harness.controller.applyPresetsToAllConversations();
      await harness.settleFor(
        () =>
            harness.chatService
                .getMessages(historyId)
                .map((m) => m.content)
                .toString() ==
            '(v2, hello)',
      );

      expect(result.touched, 2);
      expect(result.failed, 0);
      expect(harness.chatService.getMessages(historyId).map((m) => m.content), [
        'v2',
        'hello',
      ]);
      expect(harness.chatService.getMessages(freshId).map((m) => m.content), [
        'v2',
      ]);
      expect(harness.chatService.getMessages(foreignId).map((m) => m.content), [
        'do not touch',
      ]);
      expect(harness.controller.showPresetSyncBanner, isFalse);
    });
  });

  testWidgets('dismiss clears the banner without writing anything', (
    tester,
  ) async {
    final harness = await _pumpHarness(tester);
    addTearDown(() => harness.dispose(tester));

    await tester.runAsync(() async {
      final a1 = await _addAssistant(harness, 'A1', [
        PresetMessage(role: 'user', content: 'v1'),
      ]);
      final convoId = await _newConversation(
        harness,
        'History',
        a1,
        presetContent: 'old preset',
        realContent: 'hello',
      );
      harness.controller.chatController.setCurrentConversation(
        harness.chatService.getConversation(convoId),
      );
      await harness.settleFor(
        () => harness.controller.currentConversation?.id == convoId,
      );

      final assistant = harness.assistants.getById(a1)!;
      await harness.assistants.updateAssistant(
        assistant.copyWith(
          presetMessages: [PresetMessage(role: 'user', content: 'v2')],
        ),
      );
      await harness.settleFor(() => harness.controller.showPresetSyncBanner);
      expect(harness.controller.showPresetSyncBanner, isTrue);

      harness.controller.dismissPresetSyncBanner();
      await harness.settleFor(() => !harness.controller.showPresetSyncBanner);

      expect(harness.controller.showPresetSyncBanner, isFalse);
      expect(harness.chatService.getMessages(convoId).map((m) => m.content), [
        'old preset',
        'hello',
      ]);
    });
  });

  testWidgets('banner never shows on temporary conversations', (tester) async {
    final harness = await _pumpHarness(tester);
    addTearDown(() => harness.dispose(tester));

    await tester.runAsync(() async {
      final a1 = await _addAssistant(harness, 'A1', [
        PresetMessage(role: 'user', content: 'v1'),
      ]);
      final historyId = await _newConversation(
        harness,
        'History',
        a1,
        presetContent: 'old preset',
        realContent: 'hello',
      );
      harness.controller.chatController.setCurrentConversation(
        harness.chatService.getConversation(historyId),
      );
      await harness.settleFor(
        () => harness.controller.currentConversation?.id == historyId,
      );

      final assistant = harness.assistants.getById(a1)!;
      await harness.assistants.updateAssistant(
        assistant.copyWith(
          presetMessages: [PresetMessage(role: 'user', content: 'v2')],
        ),
      );
      await harness.settleFor(() => harness.controller.showPresetSyncBanner);

      // Move to a temporary conversation of the same assistant that holds a
      // real message: the assistant-scoped pending marker must not leak in.
      final temp = await harness.chatService.createDraftConversation(
        title: 'Temporary',
        assistantId: a1,
        temporary: true,
      );
      await harness.chatService.addMessage(
        conversationId: temp.id,
        role: 'user',
        content: 'temp hello',
      );
      harness.controller.chatController.setCurrentConversation(
        harness.chatService.getConversation(temp.id),
      );
      await harness.settleFor(
        () => harness.controller.currentConversation?.id == temp.id,
      );

      expect(harness.controller.showPresetSyncBanner, isFalse);
    });
  });

  testWidgets(
    'edits to a non-current assistant surface the banner on a later visit',
    (tester) async {
      final harness = await _pumpHarness(tester);
      addTearDown(() => harness.dispose(tester));

      await tester.runAsync(() async {
        final a1 = await _addAssistant(harness, 'A1', [
          PresetMessage(role: 'user', content: 'a v1'),
        ]);
        final a2 = await _addAssistant(harness, 'A2', [
          PresetMessage(role: 'user', content: 'b v1'),
        ]);
        final a1History = await _newConversation(
          harness,
          'A1 History',
          a1,
          presetContent: 'a old preset',
          realContent: 'a hello',
        );
        final a2History = await _newConversation(
          harness,
          'A2 History',
          a2,
          presetContent: 'b old preset',
          realContent: 'b hello',
        );

        // Chat with A1 while editing A2's presets.
        harness.controller.chatController.setCurrentConversation(
          harness.chatService.getConversation(a1History),
        );
        await harness.settleFor(
          () => harness.controller.currentConversation?.id == a1History,
        );
        final a2Assistant = harness.assistants.getById(a2)!;
        await harness.assistants.updateAssistant(
          a2Assistant.copyWith(
            presetMessages: [PresetMessage(role: 'user', content: 'b v2')],
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 50));

        // No banner in A1's conversation, and nothing written yet.
        expect(harness.controller.showPresetSyncBanner, isFalse);
        expect(
          harness.chatService.getMessages(a2History).map((m) => m.content),
          ['b old preset', 'b hello'],
        );

        // Visiting A2's history conversation surfaces the pending change.
        harness.controller.chatController.setCurrentConversation(
          harness.chatService.getConversation(a2History),
        );
        await harness.settleFor(() => harness.controller.showPresetSyncBanner);
        expect(harness.controller.showPresetSyncBanner, isTrue);
        expect(
          harness.chatService.getMessages(a2History).map((m) => m.content),
          ['b old preset', 'b hello'],
        );
      });
    },
  );

  testWidgets('cold-start assistant load does not raise the preset banner', (
    tester,
  ) async {
    final harness = await _pumpHarness(tester);
    addTearDown(() => harness.dispose(tester));

    await tester.runAsync(() async {
      // Seed the assistant + a history conversation in the repository
      // BEFORE the provider loads, mirroring production: the controller
      // attaches its listener to an empty AssistantProvider, then the DB
      // load notifies. A null previous fingerprint is not an edit.
      final seeded = Assistant(
        id: 'seeded-a1',
        name: 'Seeded',
        presetMessages: [PresetMessage(role: 'user', content: 's v1')],
      );
      await harness.chatService.repo.putAssistant(seeded);
      final convo = await harness.chatService.createConversation(
        title: 'Seeded History',
        assistantId: seeded.id,
      );
      await harness.chatService.addMessage(
        conversationId: convo.id,
        role: 'user',
        content: 'old preset',
        isPreset: true,
      );
      await harness.chatService.addMessage(
        conversationId: convo.id,
        role: 'user',
        content: 'hello',
      );

      await harness.assistants.ensureLoaded();
      harness.controller.chatController.setCurrentConversation(
        harness.chatService.getConversation(convo.id),
      );
      await harness.settleFor(
        () => harness.controller.currentConversation?.id == convo.id,
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(harness.controller.showPresetSyncBanner, isFalse);
      expect(harness.chatService.getMessages(convo.id).map((m) => m.content), [
        'old preset',
        'hello',
      ]);
    });
  });

  testWidgets('a failed apply restores the banner and reports the error', (
    tester,
  ) async {
    final harness = await _pumpHarness(
      tester,
      createService: _FailingPresetSyncService.new,
    );
    addTearDown(() => harness.dispose(tester));

    await tester.runAsync(() async {
      final failing = harness.chatService as _FailingPresetSyncService;
      final a1 = await _addAssistant(harness, 'A1', [
        PresetMessage(role: 'user', content: 'v1'),
      ]);
      final convoId = await _newConversation(
        harness,
        'History',
        a1,
        presetContent: 'old preset',
        realContent: 'hello',
      );
      harness.controller.chatController.setCurrentConversation(
        harness.chatService.getConversation(convoId),
      );
      await harness.settleFor(
        () => harness.controller.currentConversation?.id == convoId,
      );

      final assistant = harness.assistants.getById(a1)!;
      await harness.assistants.updateAssistant(
        assistant.copyWith(
          presetMessages: [PresetMessage(role: 'user', content: 'v2')],
        ),
      );
      await harness.settleFor(() => harness.controller.showPresetSyncBanner);

      failing.failPresetSync = true;
      await harness.controller.applyPresetsToCurrentConversation();
      await harness.settleFor(() => harness.controller.showPresetSyncBanner);

      // The banner is restored and nothing was written.
      expect(harness.controller.showPresetSyncBanner, isTrue);
      expect(harness.chatService.getMessages(convoId).map((m) => m.content), [
        'old preset',
        'hello',
      ]);
    });
  });
}
