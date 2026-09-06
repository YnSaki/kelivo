import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:Cuplivo/core/models/conversation.dart';
import 'package:Cuplivo/core/services/chat/chat_service.dart';

/// Regression tests for the conversation model binding write outlet and the
/// creation-time snapshot path (ADR-0055 "conversation model independence").
///
/// Bug shapes covered:
/// - switching the model right after creating a new chat wrote the empty
///   draft to SQLite via `_saveConversation` (drafts are memory-only for
///   every other write path), materializing a bogus empty conversation in the
///   sidebar;
/// - the snapshot resolver was never installed in tests, so deleting the
///   `createConversation`/`createDraftConversation` snapshot calls would not
///   have been caught.
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late ChatService service;
  // Mutable snapshot result the tests install via setCreationModelSnapshotResolver.
  ({String? providerKey, String? modelId})? snapshotResult;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('cuplivo_binding_test_');
    PathProviderPlatform.instance = _FakePathProviderPlatform(tempDir.path);
    snapshotResult = null;
    service = ChatService();
    // Always installed: the closure reads the mutable `snapshotResult` at call
    // time, so each test flips it (or leaves it null) inside its own body.
    service.setCreationModelSnapshotResolver((_) async => snapshotResult);
    await service.init();
  });

  tearDown(() async {
    await service.close();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('creation-time snapshot (ADR-0055)', () {
    test('createConversation snapshots the effective model', () async {
      snapshotResult = (providerKey: 'SnapProv', modelId: 'snap-1');
      final convo = await service.createConversation(assistantId: 'a1');

      expect(convo.chatModelProvider, 'SnapProv');
      expect(convo.chatModelId, 'snap-1');
      final rows = service.repo.getAllCompleteConversationsSync();
      expect(rows, hasLength(1));
      expect(rows.first.chatModelProvider, 'SnapProv');
      expect(rows.first.chatModelId, 'snap-1');
    });

    test('the snapshot binding survives a reload from disk', () async {
      snapshotResult = (providerKey: 'SnapProv', modelId: 'snap-1');
      final convo = await service.createConversation(assistantId: 'a1');
      await service.close();

      final service2 = ChatService();
      await service2.init();
      try {
        final revived = service2.repo.getConversationSync(
          convo.id,
          includeMessageIds: false,
        );
        expect(revived, isNotNull);
        expect(revived!.chatModelProvider, 'SnapProv');
        expect(revived.chatModelId, 'snap-1');
      } finally {
        await service2.close();
      }
    });

    test(
      'createDraftConversation snapshots in memory and rides promotion',
      () async {
        snapshotResult = (providerKey: 'SnapProv', modelId: 'snap-1');
        final draft = await service.createDraftConversation(
          title: 'New Chat',
          assistantId: 'a1',
        );
        expect(draft.chatModelProvider, 'SnapProv');
        expect(
          service.repo.getAllCompleteConversationsSync(),
          isEmpty,
          reason: 'the draft must not be persisted yet',
        );

        await service.addMessage(
          conversationId: draft.id,
          role: 'user',
          content: 'hello',
        );

        final rows = service.repo.getAllCompleteConversationsSync();
        expect(rows, hasLength(1));
        expect(rows.first.chatModelProvider, 'SnapProv');
        expect(rows.first.chatModelId, 'snap-1');
      },
    );

    test('group conversations never take a snapshot binding', () async {
      snapshotResult = (providerKey: 'SnapProv', modelId: 'snap-1');
      final group = await service.createConversation(
        assistantId: 'a1',
        conversationKind: Conversation.kindGroup,
      );
      expect(group.chatModelProvider, isNull);
      expect(group.chatModelId, isNull);
    });

    test('unresolvable snapshot leaves the conversation unbound', () async {
      snapshotResult = null;
      final convo = await service.createConversation(assistantId: 'a1');
      expect(convo.chatModelProvider, isNull);
      expect(convo.chatModelId, isNull);
    });

    test('a partial snapshot (provider only) stays unbound', () async {
      snapshotResult = (providerKey: 'SnapProv', modelId: null);
      final convo = await service.createConversation(assistantId: 'a1');
      expect(convo.chatModelProvider, isNull);
      expect(convo.chatModelId, isNull);
    });
  });

  group('write outlet + clear (ADR-0055)', () {
    test(
      'draft model switch stays in memory: no empty conversation persists',
      () async {
        final draft = await service.createDraftConversation(
          title: 'New Chat',
          assistantId: 'a1',
        );

        expect(
          service.repo.getAllCompleteConversationsSync(),
          isEmpty,
          reason: 'a brand-new draft must not be in the DB yet',
        );

        await service.setConversationModelBinding(
          conversationId: draft.id,
          providerKey: 'OpenAI',
          modelId: 'gpt-5',
        );

        // Binding applied in memory, not persisted.
        final draftNow = service.getConversation(draft.id);
        expect(draftNow?.chatModelProvider, 'OpenAI');
        expect(draftNow?.chatModelId, 'gpt-5');
        expect(
          service.repo.getAllCompleteConversationsSync(),
          isEmpty,
          reason: 'switching the model on an empty draft must not persist it',
        );
      },
    );

    test('binding rides the draft promotion on first message', () async {
      final draft = await service.createDraftConversation(
        title: 'New Chat',
        assistantId: 'a1',
      );
      await service.setConversationModelBinding(
        conversationId: draft.id,
        providerKey: 'Claude',
        modelId: 'claude-4',
      );

      await service.addMessage(
        conversationId: draft.id,
        role: 'user',
        content: 'hello',
      );

      final rows = service.repo.getAllCompleteConversationsSync();
      expect(rows, hasLength(1));
      final persisted = service.getConversation(draft.id);
      expect(persisted?.chatModelProvider, 'Claude');
      expect(persisted?.chatModelId, 'claude-4');
    });

    test('persisted conversations write the binding immediately', () async {
      final convo = await service.createConversation(assistantId: 'a1');
      await service.setConversationModelBinding(
        conversationId: convo.id,
        providerKey: 'Gemini',
        modelId: 'gemini-3',
      );

      final rows = service.repo.getAllCompleteConversationsSync();
      expect(rows, hasLength(1));
      expect(rows.first.chatModelProvider, 'Gemini');
      expect(rows.first.chatModelId, 'gemini-3');
    });

    test(
      'clearConversationModelBinding removes the binding (persisted)',
      () async {
        final convo = await service.createConversation(assistantId: 'a1');
        await service.setConversationModelBinding(
          conversationId: convo.id,
          providerKey: 'Gemini',
          modelId: 'gemini-3',
        );
        await service.clearConversationModelBinding(conversationId: convo.id);

        final rows = service.repo.getAllCompleteConversationsSync();
        expect(rows.first.chatModelProvider, isNull);
        expect(rows.first.chatModelId, isNull);
      },
    );

    test(
      'clearConversationModelBinding on a draft stays in memory only',
      () async {
        final draft = await service.createDraftConversation(assistantId: 'a1');
        await service.setConversationModelBinding(
          conversationId: draft.id,
          providerKey: 'Gemini',
          modelId: 'gemini-3',
        );
        await service.clearConversationModelBinding(conversationId: draft.id);

        expect(service.repo.getAllCompleteConversationsSync(), isEmpty);
        expect(service.getConversation(draft.id)?.chatModelProvider, isNull);
        expect(service.getConversation(draft.id)?.chatModelId, isNull);
      },
    );
  });
}
