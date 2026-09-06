import 'dart:convert';

import 'package:Cuplivo/core/database/business_preferences.dart';
import 'package:Cuplivo/core/database/business_preferences_store.dart';
import 'package:Cuplivo/core/database/business_repository.dart';
import 'package:Cuplivo/core/models/quick_instruction.dart';
import 'package:Cuplivo/core/models/quick_phrase.dart';
import 'package:Cuplivo/core/models/workspace.dart';
import 'package:Cuplivo/core/services/quick_instruction_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('QuickInstructionStore legacy migration', () {
    test('upgrades legacy injections and materializes empty titles', () async {
      final preferences = BusinessPreferences.memoryForTests({
        QuickInstructionStore.builtInPlanSeedReceiptKey: true,
        QuickInstructionStore.itemsKey: jsonEncode([
          {
            'id': 'legacy-learning',
            'title': '   ',
            'prompt': 'learning prompt',
            'group': '',
          },
          {
            'id': 'legacy-empty',
            'title': '',
            'prompt': 'other prompt',
            'group': 'Legacy',
          },
        ]),
      });
      final store = QuickInstructionStore(preferences);

      final items = await store.getAll();

      expect(items.map((item) => item.title), ['Learning Mode', 'Untitled']);
      expect(
        items.map((item) => item.placement),
        everyElement(QuickInstructionPlacement.systemPrompt),
      );
      expect(items.map((item) => item.toolPolicy.enabled), everyElement(false));
    });

    test(
      'merges global and assistant phrases with deterministic suffixes',
      () async {
        final preferences = BusinessPreferences.memoryForTests({
          QuickInstructionStore.builtInPlanSeedReceiptKey: true,
          QuickInstructionStore.itemsKey: jsonEncode([
            {
              'id': 'injection-1',
              'title': 'Focus',
              'prompt': 'system prompt',
              'group': 'Original',
            },
          ]),
          QuickInstructionStore.legacyQuickPhrasesKey: jsonEncode([
            const QuickPhrase(
              id: 'phrase-global',
              title: ' Focus ',
              content: 'global phrase',
            ).toJson(),
            const QuickPhrase(
              id: 'phrase-assistant',
              title: 'Focus',
              content: 'assistant phrase',
              isGlobal: false,
              assistantId: 'assistant-1',
            ).toJson(),
            const QuickPhrase(
              id: 'phrase-case-sensitive',
              title: 'focus',
              content: 'case-sensitive phrase',
            ).toJson(),
          ]),
        });
        final store = QuickInstructionStore(preferences);

        await store.migrateLegacyQuickPhrases(
          assistantNames: const {'assistant-1': 'Writer'},
        );
        final items = await store.getAll();

        expect(items.map((item) => item.title), [
          'Focus-Instruction Injection',
          'Focus-Global Quick Phrase',
          'Focus-(Writer) Quick Phrase',
          'focus',
        ]);
        expect(items.first.group, 'Original');
        expect(
          items.skip(1).map((item) => item.group),
          everyElement(QuickInstructionStore.migratedQuickPhraseGroup),
        );
        expect(
          items.skip(1).map((item) => item.placement),
          everyElement(QuickInstructionPlacement.inputBox),
        );
        expect(
          preferences.getBool(QuickInstructionStore.migrationReceiptKey),
          isTrue,
        );
        expect(
          preferences.getString(QuickInstructionStore.legacyQuickPhrasesKey),
          isNull,
        );

        final migratedIds = items.map((item) => item.id).toList();
        store.invalidateCache();
        await store.migrateLegacyQuickPhrases(
          assistantNames: const {'assistant-1': 'Writer'},
        );
        expect((await store.getAll()).map((item) => item.id), migratedIds);
      },
    );

    test(
      'failed source removal keeps legacy data and retry does not duplicate',
      () async {
        final backend = _FailingRemoveStore({
          QuickInstructionStore.builtInPlanSeedReceiptKey: true,
          QuickInstructionStore.itemsKey: jsonEncode([
            {
              'id': 'injection-1',
              'title': 'System',
              'prompt': 'system prompt',
              'group': '',
              'placement': QuickInstructionPlacement.systemPrompt.name,
            },
          ]),
          QuickInstructionStore.legacyQuickPhrasesKey: jsonEncode([
            const QuickPhrase(
              id: 'phrase-1',
              title: 'Insert',
              content: 'insert me',
            ).toJson(),
          ]),
        })..failedKey = QuickInstructionStore.legacyQuickPhrasesKey;
        final preferences = BusinessPreferences.open(backend);
        await preferences.load();
        final store = QuickInstructionStore(preferences);

        await expectLater(
          store.migrateLegacyQuickPhrases(),
          throwsA(isA<StateError>()),
        );
        expect(
          preferences.getString(QuickInstructionStore.legacyQuickPhrasesKey),
          isNotNull,
        );
        final firstAttempt = await store.getAll();
        expect(firstAttempt, hasLength(2));

        backend.failedKey = null;
        store.invalidateCache();
        await store.migrateLegacyQuickPhrases();
        final retry = await store.getAll();

        expect(retry, hasLength(2));
        expect(retry.map((item) => item.id).toSet(), {
          'injection-1',
          firstAttempt.last.id,
        });
        expect(
          preferences.getString(QuickInstructionStore.legacyQuickPhrasesKey),
          isNull,
        );
      },
    );

    test(
      'an old backup migrates again even when a prior receipt remains',
      () async {
        final preferences = BusinessPreferences.memoryForTests({
          QuickInstructionStore.builtInPlanSeedReceiptKey: true,
          QuickInstructionStore.migrationReceiptKey: true,
          QuickInstructionStore.itemsKey: jsonEncode([
            {
              'id': 'restored-injection',
              'title': 'Review',
              'prompt': 'restored system prompt',
              'group': 'Restored',
            },
          ]),
          QuickInstructionStore.legacyQuickPhrasesKey: jsonEncode([
            const QuickPhrase(
              id: 'restored-phrase',
              title: 'Review',
              content: 'restored phrase',
            ).toJson(),
          ]),
        });
        final store = QuickInstructionStore(preferences);

        await store.migrateLegacyQuickPhrases();

        expect((await store.getAll()).map((item) => item.title), [
          'Review-Instruction Injection',
          'Review-Global Quick Phrase',
        ]);
        expect(
          preferences.getString(QuickInstructionStore.legacyQuickPhrasesKey),
          isNull,
        );
      },
    );
  });

  group('QuickInstructionStore built-in plan', () {
    test('seeds a new user once with the complete read-only policy', () async {
      final preferences = BusinessPreferences.memoryForTests();
      final store = QuickInstructionStore(preferences);

      final items = await store.getAll();
      final plan = items.singleWhere(
        (item) => item.id == QuickInstructionStore.builtInPlanId,
      );

      expect(items.last.id, QuickInstructionStore.builtInPlanId);
      expect(plan.title, 'plan');
      expect(plan.group, 'Modes');
      expect(
        plan.prompt,
        'You are now in Plan Mode. Investigate the request and produce a '
        'decision-complete, implementation-ready plan; do not implement it. '
        'Use read-only inspection to resolve repository and environment facts '
        'before asking questions. Ask only questions whose answers materially '
        'change the design. Do not edit files, change configuration, install '
        'dependencies, run commands that mutate local or external state, '
        'create commits or pull requests, or claim that work is complete. The '
        'final response must clearly state the objective, scope and '
        'exclusions, affected components and interfaces, data flow and '
        'persistence implications, compatibility and migration behavior, edge '
        'cases and failure handling, and verification criteria, in an ordered '
        'plan that another engineer can execute without making further product '
        'or architecture decisions.',
      );
      expect(plan.placement, QuickInstructionPlacement.beforeUserMessage);
      expect(plan.triggerMode, QuickInstructionTriggerMode.persistent);
      expect(plan.retainInHistory, isTrue);
      expect(plan.toolPolicy.enabled, isTrue);
      expect(plan.toolPolicy.shellDisabled, isFalse);
      expect(plan.toolPolicy.disabledLocalToolIds, isEmpty);
      expect(plan.toolPolicy.disabledMcpServerIds, isEmpty);
      expect(plan.toolPolicy.disabledFilesystemToolNames.toSet(), {
        WorkspaceToolNames.write,
        WorkspaceToolNames.patch,
        WorkspaceToolNames.delete,
        WorkspaceToolNames.mkdir,
        WorkspaceToolNames.move,
        WorkspaceToolNames.zip,
        WorkspaceToolNames.unzip,
        WorkspaceToolNames.download,
      });
      expect(
        plan.toolPolicy.disabledFilesystemToolNames.toSet().intersection({
          WorkspaceToolNames.read,
          WorkspaceToolNames.glob,
          WorkspaceToolNames.grep,
          WorkspaceToolNames.outline,
          WorkspaceToolNames.shell,
        }),
        isEmpty,
      );
      expect(plan.toolPolicy.shellBlockPatterns, contains('rm *'));
      expect(plan.toolPolicy.shellBlockPatterns, contains('* >*'));
      expect(
        preferences.getBool(QuickInstructionStore.builtInPlanSeedReceiptKey),
        isTrue,
      );
      expect(await store.getActiveIds(), isEmpty);

      store.invalidateCache();
      expect(
        (await store.getAll()).where(
          (item) => item.id == QuickInstructionStore.builtInPlanId,
        ),
        hasLength(1),
      );
    });

    test('appends to existing data and keeps same-title user items', () async {
      final preferences = BusinessPreferences.memoryForTests({
        QuickInstructionStore.itemsKey: jsonEncode([
          QuickInstruction(
            id: 'user-plan',
            title: 'plan',
            prompt: 'my plan prompt',
          ).toJson(),
        ]),
      });
      final store = QuickInstructionStore(preferences);

      final items = await store.getAll();

      expect(items.map((item) => item.id), [
        'user-plan',
        QuickInstructionStore.builtInPlanId,
      ]);
      expect(items.map((item) => item.title), ['plan', 'plan']);
      expect(items.first.prompt, 'my plan prompt');
    });

    test('does not overwrite an existing deterministic ID', () async {
      final preferences = BusinessPreferences.memoryForTests({
        QuickInstructionStore.itemsKey: jsonEncode([
          QuickInstruction(
            id: QuickInstructionStore.builtInPlanId,
            title: 'edited plan',
            prompt: 'user edited prompt',
          ).toJson(),
        ]),
      });
      final store = QuickInstructionStore(preferences);

      final items = await store.getAll();

      expect(items, hasLength(1));
      expect(items.single.title, 'edited plan');
      expect(items.single.prompt, 'user edited prompt');
      expect(
        preferences.getBool(QuickInstructionStore.builtInPlanSeedReceiptKey),
        isTrue,
      );
    });

    test('a receipt respects deletion and receipt-bearing backups', () async {
      final preferences = BusinessPreferences.memoryForTests();
      final store = QuickInstructionStore(preferences);
      await store.getAll();

      await store.delete(QuickInstructionStore.builtInPlanId);
      store.invalidateCache();

      expect(
        (await store.getAll()).map((item) => item.id),
        isNot(contains(QuickInstructionStore.builtInPlanId)),
      );

      final restoredPreferences = BusinessPreferences.memoryForTests({
        QuickInstructionStore.builtInPlanSeedReceiptKey: true,
        QuickInstructionStore.itemsKey: jsonEncode(<Object>[]),
      });
      final restoredStore = QuickInstructionStore(restoredPreferences);
      expect(await restoredStore.getAll(), isEmpty);
    });

    test(
      'an old backup without a receipt receives the built-in plan',
      () async {
        final preferences = BusinessPreferences.memoryForTests({
          QuickInstructionStore.itemsKey: jsonEncode([
            QuickInstruction(
              id: 'restored',
              title: 'Restored',
              prompt: 'restored prompt',
            ).toJson(),
          ]),
        });

        final items = await QuickInstructionStore(preferences).getAll();

        expect(items.map((item) => item.id), [
          'restored',
          QuickInstructionStore.builtInPlanId,
        ]);
      },
    );

    test('a failed receipt write retries without duplicating plan', () async {
      final backend = _FailingRemoveStore({
        QuickInstructionStore.itemsKey: jsonEncode([
          QuickInstruction(
            id: 'existing',
            title: 'Existing',
            prompt: 'existing prompt',
          ).toJson(),
        ]),
      })..failedWriteKey = QuickInstructionStore.builtInPlanSeedReceiptKey;
      final preferences = BusinessPreferences.open(backend);
      await preferences.load();
      final store = QuickInstructionStore(preferences);

      await expectLater(store.getAll(), throwsA(isA<StateError>()));

      backend.failedWriteKey = null;
      store.invalidateCache();
      final items = await store.getAll();
      expect(
        items.where((item) => item.id == QuickInstructionStore.builtInPlanId),
        hasLength(1),
      );
      expect(
        preferences.getBool(QuickInstructionStore.builtInPlanSeedReceiptKey),
        isTrue,
      );
    });

    test('legacy name collisions never rename the built-in plan', () async {
      final preferences = BusinessPreferences.memoryForTests({
        QuickInstructionStore.itemsKey: jsonEncode([
          QuickInstructionStore.builtInPlan.toJson(),
        ]),
        QuickInstructionStore.legacyQuickPhrasesKey: jsonEncode([
          const QuickPhrase(
            id: 'phrase-plan',
            title: 'plan',
            content: 'legacy plan phrase',
          ).toJson(),
        ]),
      });
      final store = QuickInstructionStore(preferences);

      await store.migrateLegacyQuickPhrases();

      expect((await store.getAll()).map((item) => item.title), [
        'plan',
        'plan-Global Quick Phrase',
      ]);
    });
  });
}

final class _FailingRemoveStore implements BusinessPreferencesStore {
  _FailingRemoveStore(Map<String, Object> seed)
    : _values = Map<String, Object>.of(seed);

  final Map<String, Object> _values;
  String? failedKey;
  String? failedWriteKey;

  @override
  Future<List<BusinessPreferenceEntry>> readAll() async {
    return <BusinessPreferenceEntry>[
      for (final entry in _values.entries)
        BusinessPreferenceEntry(
          key: entry.key,
          value: entry.value,
          updatedAt: 1,
        ),
    ];
  }

  @override
  Future<void> write(String key, Object value, {required int updatedAt}) async {
    if (key == failedWriteKey) throw StateError('simulated write failure');
    _values[key] = value;
  }

  @override
  Future<void> remove(String key) async {
    if (key == failedKey) throw StateError('simulated remove failure');
    _values.remove(key);
  }

  @override
  Future<void> clear() async => _values.clear();
}
