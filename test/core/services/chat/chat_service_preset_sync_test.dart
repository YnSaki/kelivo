import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import 'package:Cuplivo/core/models/conversation.dart';
import 'package:Cuplivo/core/services/chat/chat_service.dart';

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

Map<String, String> _preset(String role, String content) => <String, String>{
  'role': role,
  'content': content,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late ChatService service;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('preset_sync_');
    PathProviderPlatform.instance = _FakePathProviderPlatform(tempDir.path);
    service = ChatService();
    await service.init();
  });

  tearDown(() async {
    await service.close();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  Future<Conversation> newConversation(String id, {String? assistantId}) async {
    return service.createConversation(title: id, assistantId: assistantId);
  }

  group('ChatService.syncPresetMessages', () {
    test(
      'inserts presets into an empty conversation, normalizing roles',
      () async {
        final convo = await newConversation('empty', assistantId: 'a1');
        final changed = await service.syncPresetMessages(
          conversationId: convo.id,
          presets: [
            _preset('user', '  hello  '),
            _preset('weird-role', 'normalized'),
            _preset('assistant', '   '),
            _preset('assistant', 'greeting reply'),
          ],
        );
        expect(changed, isTrue);

        final messages = service.getMessages(convo.id);
        expect(messages.map((m) => (m.role, m.content)), [
          ('user', 'hello'),
          ('user', 'normalized'),
          ('assistant', 'greeting reply'),
        ]);
        expect(messages.every((m) => m.isPreset), isTrue);
        expect(await service.hasNoRealMessages(convo.id), isTrue);
      },
    );

    test('replaces the preset list of a preset-only conversation', () async {
      final convo = await newConversation('preset-only', assistantId: 'a1');
      final oldFirst = await service.addMessage(
        conversationId: convo.id,
        role: 'user',
        content: 'old v1',
        isPreset: true,
      );
      await service.addMessage(
        conversationId: convo.id,
        role: 'assistant',
        content: 'old v2',
        isPreset: true,
      );

      final changed = await service.syncPresetMessages(
        conversationId: convo.id,
        presets: [_preset('user', 'new v1'), _preset('user', 'new v2')],
      );
      expect(changed, isTrue);

      final messages = service.getMessages(convo.id);
      expect(messages.map((m) => m.content), ['new v1', 'new v2']);
      expect(
        messages.any((m) => m.id == oldFirst.id),
        isFalse,
        reason: 'stale preset rows must be removed, not reused',
      );
      expect(
        await service.isRecyclablePresetOnlyConversation(convo.id),
        isTrue,
        reason: 'a synced preset-only conversation stays preset-only',
      );

      // A second identical sync is a no-op.
      final again = await service.syncPresetMessages(
        conversationId: convo.id,
        presets: [_preset('user', 'new v1'), _preset('user', 'new v2')],
      );
      expect(again, isFalse);
    });

    test(
      'inserts new presets at the top of a conversation with history',
      () async {
        final convo = await newConversation('history', assistantId: 'a1');
        await service.addMessage(
          conversationId: convo.id,
          role: 'user',
          content: 'old preset',
          isPreset: true,
        );
        final r1 = await service.addMessage(
          conversationId: convo.id,
          role: 'user',
          content: 'real 1',
        );
        final r2 = await service.addMessage(
          conversationId: convo.id,
          role: 'assistant',
          content: 'real 2',
        );

        final changed = await service.syncPresetMessages(
          conversationId: convo.id,
          presets: [
            _preset('user', 'q1'),
            _preset('assistant', 'q2'),
            _preset('user', 'q3'),
          ],
        );
        expect(changed, isTrue);

        final messages = service.getMessages(convo.id);
        expect(messages.map((m) => m.content), [
          'q1',
          'q2',
          'q3',
          'real 1',
          'real 2',
        ]);
        expect(messages.map((m) => m.isPreset), [
          true,
          true,
          true,
          false,
          false,
        ]);
        expect(
          messages.map((m) => m.id),
          containsAllInOrder(<String>[r1.id, r2.id]),
        );
        // messageOrder stays contiguous after the replacement.
        for (var i = 0; i < messages.length; i++) {
          expect(
            await service.repo.getMessageIndex(convo.id, messages[i].id),
            i,
          );
        }
        expect(await service.hasNoRealMessages(convo.id), isFalse);
      },
    );

    test(
      'shifts truncateIndex by (added - removed) on history conversations',
      () async {
        final convo = await newConversation('trunc', assistantId: 'a1');
        await service.addMessage(
          conversationId: convo.id,
          role: 'user',
          content: 'old preset',
          isPreset: true,
        );
        for (var i = 1; i <= 4; i++) {
          await service.addMessage(
            conversationId: convo.id,
            role: 'user',
            content: 'real $i',
          );
        }
        // [P1, R1..R4]: split at 4 keeps only R4 in context.
        final cached = service.getConversation(convo.id)!;
        cached.truncateIndex = 4;
        await service.repo.putConversation(cached);

        // removed=1, added=3 → 4 - 1 + 3 = 6; [Q1..Q3, R1..R4] keeps only R4.
        await service.syncPresetMessages(
          conversationId: convo.id,
          presets: [
            _preset('user', 'q1'),
            _preset('assistant', 'q2'),
            _preset('user', 'q3'),
          ],
        );

        final messages = service.getMessages(convo.id);
        expect(messages, hasLength(7));
        expect(service.getConversation(convo.id)!.truncateIndex, 6);
        // The same real message stays inside the truncated context.
        expect(messages.sublist(6).single.content, 'real 4');
      },
    );

    test('keeps truncateIndex when preset count is unchanged', () async {
      final convo = await newConversation('trunc-same', assistantId: 'a1');
      await service.addMessage(
        conversationId: convo.id,
        role: 'user',
        content: 'p1',
        isPreset: true,
      );
      await service.addMessage(
        conversationId: convo.id,
        role: 'user',
        content: 'real 1',
      );
      final cached = service.getConversation(convo.id)!;
      cached.truncateIndex = 1;
      await service.repo.putConversation(cached);

      await service.syncPresetMessages(
        conversationId: convo.id,
        presets: [_preset('user', 'p1-replaced')],
      );

      // removed=1, added=1 → index stays at the first real row.
      expect(service.getConversation(convo.id)!.truncateIndex, 1);
      final messages = service.getMessages(convo.id);
      expect(messages.map((m) => m.content), ['p1-replaced', 'real 1']);
    });

    test(
      'keeps a cleared context when a preset-only conversation is resynced',
      () async {
        final convo = await newConversation('fresh-trunc', assistantId: 'a1');
        await service.addMessage(
          conversationId: convo.id,
          role: 'user',
          content: 'p1',
          isPreset: true,
        );
        // Simulate "clear context" at the tail of a preset-only conversation:
        // toggleTruncateAtTail sets the index to the full message count.
        final cached = service.getConversation(convo.id)!;
        cached.truncateIndex = 1;
        await service.repo.putConversation(cached);

        await service.syncPresetMessages(
          conversationId: convo.id,
          presets: [
            _preset('user', 'q1'),
            _preset('assistant', 'q2'),
            _preset('user', 'q3'),
          ],
        );

        // The replacement excludes all new presets, so the context stays empty.
        expect(service.getConversation(convo.id)!.truncateIndex, 3);
        final messages = service.getMessages(convo.id);
        expect(messages.map((m) => m.content), ['q1', 'q2', 'q3']);
        expect(messages.sublist(3), isEmpty);
      },
    );

    test(
      'preserves a no-op truncate marker on an empty conversation',
      () async {
        final convo = await newConversation('fresh-zero', assistantId: 'a1');
        final cached = service.getConversation(convo.id)!;
        cached.truncateIndex = 0;
        await service.repo.putConversation(cached);

        await service.syncPresetMessages(
          conversationId: convo.id,
          presets: [_preset('user', 'q1')],
        );

        expect(service.getConversation(convo.id)!.truncateIndex, 0);
        expect(service.getMessages(convo.id).map((m) => m.content), ['q1']);
      },
    );

    test(
      'does not shift a no-op truncate marker on a history conversation',
      () async {
        final convo = await newConversation('trunc-zero', assistantId: 'a1');
        await service.addMessage(
          conversationId: convo.id,
          role: 'user',
          content: 'p1',
          isPreset: true,
        );
        await service.addMessage(
          conversationId: convo.id,
          role: 'user',
          content: 'real 1',
        );
        final cached = service.getConversation(convo.id)!;
        cached.truncateIndex = 0; // excludes nothing
        await service.repo.putConversation(cached);

        await service.syncPresetMessages(
          conversationId: convo.id,
          presets: [
            _preset('user', 'q1'),
            _preset('assistant', 'q2'),
            _preset('user', 'q3'),
          ],
        );

        expect(service.getConversation(convo.id)!.truncateIndex, 0);
        final messages = service.getMessages(convo.id);
        expect(messages.map((m) => m.content), ['q1', 'q2', 'q3', 'real 1']);
      },
    );

    test(
      'clearing the preset list removes preset rows and preserves history',
      () async {
        final convo = await newConversation('clear-presets', assistantId: 'a1');
        await service.addMessage(
          conversationId: convo.id,
          role: 'user',
          content: 'p1',
          isPreset: true,
        );
        await service.addMessage(
          conversationId: convo.id,
          role: 'assistant',
          content: 'p2',
          isPreset: true,
        );
        await service.addMessage(
          conversationId: convo.id,
          role: 'user',
          content: 'real 1',
        );
        final cached = service.getConversation(convo.id)!;
        cached.truncateIndex = 3; // excludes p1, p2 and real 1
        await service.repo.putConversation(cached);

        final changed = await service.syncPresetMessages(
          conversationId: convo.id,
          presets: const [],
        );

        expect(changed, isTrue);
        final messages = service.getMessages(convo.id);
        expect(messages.map((m) => m.content), ['real 1']);
        expect(messages.single.isPreset, isFalse);
        // removed=2, added=0 → index shifts from 3 to 1 (context stays empty).
        expect(service.getConversation(convo.id)!.truncateIndex, 1);
        expect(await service.hasNoRealMessages(convo.id), isFalse);
      },
    );

    test(
      'overlapping syncs for one conversation do not duplicate rows',
      () async {
        final convo = await newConversation('overlap', assistantId: 'a1');
        final results = await Future.wait([
          service.syncPresetMessages(
            conversationId: convo.id,
            presets: [_preset('user', 'q1'), _preset('assistant', 'q2')],
          ),
          service.syncPresetMessages(
            conversationId: convo.id,
            presets: [_preset('user', 'q1'), _preset('assistant', 'q2')],
          ),
        ]);

        // The first call writes; the queued second one re-checks and no-ops.
        expect(results, [true, false]);
        expect(service.getMessages(convo.id).map((m) => m.content), [
          'q1',
          'q2',
        ]);
      },
    );

    test('skips temporary conversations', () async {
      final convo = await service.createDraftConversation(
        title: 'Temporary',
        assistantId: 'a1',
        temporary: true,
      );
      await service.addMessage(
        conversationId: convo.id,
        role: 'user',
        content: 'real 1',
      );

      final changed = await service.syncPresetMessages(
        conversationId: convo.id,
        presets: [_preset('user', 'q1')],
      );

      expect(changed, isFalse);
      expect(service.getMessages(convo.id).map((m) => m.content), ['real 1']);
    });

    test('skips group conversations', () async {
      final convo = await newConversation('group-conv', assistantId: 'a1');
      final cached = service.getConversation(convo.id)!;
      cached.conversationKind = Conversation.kindGroup;
      await service.repo.putConversation(cached);

      final changed = await service.syncPresetMessages(
        conversationId: convo.id,
        presets: [_preset('user', 'q1')],
      );

      expect(changed, isFalse);
    });

    test('returns false for unknown conversation ids', () async {
      final changed = await service.syncPresetMessages(
        conversationId: 'does-not-exist',
        presets: [_preset('user', 'q1')],
      );
      expect(changed, isFalse);
    });

    test('records removed preset rows in the trash store', () async {
      final convo = await newConversation('trash', assistantId: 'a1');
      final oldPreset = await service.addMessage(
        conversationId: convo.id,
        role: 'user',
        content: 'old preset',
        isPreset: true,
      );

      await service.syncPresetMessages(
        conversationId: convo.id,
        presets: [_preset('user', 'new preset')],
      );

      final records = await service.deletedRecordsStore!.listDeletedRecords();
      expect(records.map((r) => r.id), contains(oldPreset.id));
    });

    test(
      'removes tool events and gemini signatures of replaced presets',
      () async {
        final convo = await newConversation('fidelity', assistantId: 'a1');
        final oldPreset = await service.addMessage(
          conversationId: convo.id,
          role: 'assistant',
          content: 'old preset',
          isPreset: true,
        );
        await service.repo.setToolEvents(oldPreset.id, [
          <String, dynamic>{
            'name': 'test_tool',
            'arguments': const <String, dynamic>{},
            'content': 'ok',
          },
        ]);
        await service.repo.setGeminiThoughtSignature(oldPreset.id, 'sig-1');

        await service.syncPresetMessages(
          conversationId: convo.id,
          presets: [_preset('assistant', 'new preset')],
        );

        expect(await service.repo.getToolEvents(oldPreset.id), isEmpty);
        expect(service.getGeminiThoughtSignature(oldPreset.id), isNull);
      },
    );
  });

  group('ChatService.syncPresetMessagesForAssistant', () {
    test('syncs only conversations owned by the assistant', () async {
      final ownedFresh = await newConversation('a1-fresh', assistantId: 'a1');
      final ownedHistory = await newConversation(
        'a1-history',
        assistantId: 'a1',
      );
      await service.addMessage(
        conversationId: ownedHistory.id,
        role: 'user',
        content: 'real 1',
      );
      final foreign = await newConversation('a2-fresh', assistantId: 'a2');
      final unowned = await newConversation('unowned');

      final result = await service.syncPresetMessagesForAssistant(
        assistantId: 'a1',
        presets: [_preset('user', 'q1')],
      );

      expect(result.touched, 2);
      expect(result.failed, 0);
      expect(service.getMessages(ownedFresh.id).map((m) => m.content), ['q1']);
      expect(service.getMessages(ownedHistory.id).map((m) => m.content), [
        'q1',
        'real 1',
      ]);
      expect(service.getMessages(foreign.id), isEmpty);
      expect(service.getMessages(unowned.id), isEmpty);
    });

    test('returns 0 for an assistant without conversations', () async {
      final result = await service.syncPresetMessagesForAssistant(
        assistantId: 'nobody',
        presets: [_preset('user', 'q1')],
      );
      expect(result.touched, 0);
      expect(result.failed, 0);
    });
  });

  group('ChatService.presetPayloadFingerprint', () {
    test('is stable across equal payloads and distinct across changes', () {
      final a = ChatService.presetPayloadFingerprint([
        _preset('user', 'hi'),
        _preset('assistant', 'yo'),
      ]);
      final b = ChatService.presetPayloadFingerprint([
        _preset('user', 'hi'),
        _preset('assistant', 'yo'),
      ]);
      final c = ChatService.presetPayloadFingerprint([
        _preset('assistant', 'yo'),
        _preset('user', 'hi'),
      ]);
      final d = ChatService.presetPayloadFingerprint([
        _preset('user', 'hi '),
        _preset('assistant', 'yo'),
      ]);
      final empty = ChatService.presetPayloadFingerprint(const []);
      final emptyWithNoise = ChatService.presetPayloadFingerprint([
        _preset('user', '   '),
      ]);
      expect(a, b);
      expect(a, isNot(c));
      expect(a, d, reason: 'payload normalization trims content');
      expect(
        empty,
        emptyWithNoise,
        reason: 'blank-only entries are dropped before fingerprinting',
      );
    });
  });
}
