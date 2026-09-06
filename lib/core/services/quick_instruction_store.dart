import 'dart:convert';

import 'package:Cuplivo/core/database/business_preferences.dart';
import 'package:Cuplivo/core/models/quick_instruction.dart';
import 'package:Cuplivo/core/models/quick_phrase.dart';
import 'package:Cuplivo/core/models/workspace.dart';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import 'learning_mode_store.dart';

class QuickInstructionStore {
  QuickInstructionStore(this._preferences)
    : _learningMode = LearningModeStore(_preferences);

  static const String itemsKey = 'instruction_injections_v1';
  static const String legacyQuickPhrasesKey = 'quick_phrases_v1';
  static const String migrationReceiptKey =
      'quick_instructions_legacy_migration_v1';
  static const String migratedQuickPhraseGroup = 'Quick Phrases';
  static const String instructionInjectionGroup = 'Instruction Injections';
  static const String builtInPlanId = 'quick_instruction_builtin_plan_v1';
  static const String builtInPlanSeedReceiptKey =
      'quick_instruction_builtin_plan_seeded_v1';
  static const String builtInPlanPrompt =
      'You are now in Plan Mode. Investigate the request and produce a '
      'decision-complete, implementation-ready plan; do not implement it. '
      'Use read-only inspection to resolve repository and environment facts '
      'before asking questions. Ask only questions whose answers materially '
      'change the design. Do not edit files, change configuration, install '
      'dependencies, run commands that mutate local or external state, create '
      'commits or pull requests, or claim that work is complete. The final '
      'response must clearly state the objective, scope and exclusions, '
      'affected components and interfaces, data flow and persistence '
      'implications, compatibility and migration behavior, edge cases and '
      'failure handling, and verification criteria, in an ordered plan that '
      'another engineer can execute without making further product or '
      'architecture decisions.';
  static const List<String> builtInPlanShellBlockPatterns = <String>[
    '* >*',
    '* 2>*',
    '* &>*',
    'rm *',
    'rmdir *',
    'mv *',
    'cp *',
    'mkdir *',
    'touch *',
    'truncate *',
    'install *',
    'ln *',
    'chmod *',
    'chown *',
    'tee *',
    'dd *',
    'patch *',
    'apply_patch *',
    'rsync *',
    'scp *',
    'zip *',
    'unzip *',
    'tar *',
    'wget *',
    'sh *',
    'bash *',
    'zsh *',
    'python *',
    'python3 *',
    'node *',
    'ruby *',
    'perl *',
    'php *',
    'lua *',
    'eval *',
    'source *',
    '. *',
    'sudo *',
    'env *',
    'xargs *',
    'vim *',
    'vi *',
    'nano *',
    'ed *',
    'sed -i *',
    'sed --in-place *',
    'git add *',
    'git am *',
    'git apply *',
    'git branch *',
    'git checkout *',
    'git cherry-pick *',
    'git clean *',
    'git clone *',
    'git commit *',
    'git config *',
    'git fetch *',
    'git merge *',
    'git mv *',
    'git pull *',
    'git push *',
    'git rebase *',
    'git remote *',
    'git reset *',
    'git restore *',
    'git revert *',
    'git rm *',
    'git stash *',
    'git submodule *',
    'git switch *',
    'git tag *',
    'git worktree *',
    'git * add *',
    'git * am *',
    'git * apply *',
    'git * branch *',
    'git * checkout *',
    'git * cherry-pick *',
    'git * clean *',
    'git * clone *',
    'git * commit *',
    'git * config *',
    'git * fetch *',
    'git * merge *',
    'git * mv *',
    'git * pull *',
    'git * push *',
    'git * rebase *',
    'git * remote *',
    'git * reset *',
    'git * restore *',
    'git * revert *',
    'git * rm *',
    'git * stash *',
    'git * submodule *',
    'git * switch *',
    'git * tag *',
    'git * worktree *',
    'apt *',
    'apt-get *',
    'apk *',
    'brew *',
    'dnf *',
    'yum *',
    'pacman *',
    'pip install *',
    'pip3 install *',
    'npm install *',
    'npm i *',
    'npm add *',
    'npm remove *',
    'npm uninstall *',
    'npm update *',
    'npm publish *',
    'npm run *',
    'npm exec *',
    'npx *',
    'pnpm install *',
    'pnpm add *',
    'pnpm remove *',
    'pnpm update *',
    'pnpm publish *',
    'pnpm run *',
    'pnpm exec *',
    'yarn install *',
    'yarn add *',
    'yarn remove *',
    'yarn upgrade *',
    'yarn publish *',
    'yarn run *',
    'dart pub *',
    'dart run build_runner *',
    'dart format *',
    'flutter pub *',
    'flutter build *',
    'flutter gen-l10n *',
    'cargo build *',
    'cargo run *',
    'cargo install *',
    'cargo update *',
    'cargo fmt *',
    'go build *',
    'go install *',
    'go generate *',
    'go fmt *',
    'make *',
    'cmake *',
    'ninja *',
    'gradle *',
    './gradlew *',
    'gh * create *',
    'gh * edit *',
    'gh * merge *',
    'gh release *',
    'docker *',
    'podman *',
    'terraform *',
    'ansible *',
    'ansible-playbook *',
    'kubectl apply *',
    'kubectl annotate *',
    'kubectl create *',
    'kubectl delete *',
    'kubectl edit *',
    'kubectl exec *',
    'kubectl label *',
    'kubectl patch *',
    'kubectl replace *',
    'kubectl rollout *',
    'kubectl run *',
    'kubectl scale *',
    'kubectl set *',
    'kubectl taint *',
    'curl -o *',
    'curl --output *',
    'curl -O *',
    'curl --remote-name *',
    'curl -T *',
    'curl --upload-file *',
    'curl * -o *',
    'curl * --output *',
    'curl * -O *',
    'curl * --remote-name *',
    'curl * -T *',
    'curl * --upload-file *',
  ];
  static const String activeIdKey = 'instruction_injections_active_id_v1';
  static const String activeIdsKey = 'instruction_injections_active_ids_v1';
  static const String activeIdsByAssistantKey =
      'instruction_injections_active_ids_by_assistant_v1';
  static const String defaultAssistantKey = '__global__';

  static QuickInstructionStore? _shared;
  static QuickInstructionStore shared(BusinessPreferences preferences) {
    final current = _shared;
    if (current == null || !identical(current._preferences, preferences)) {
      return _shared = QuickInstructionStore(preferences);
    }
    return current;
  }

  final BusinessPreferences _preferences;
  final LearningModeStore _learningMode;
  List<QuickInstruction>? _cache;
  Map<String, List<String>>? _activeIdsByAssistantCache;

  static String assistantKey(String? assistantId) {
    final id = (assistantId ?? '').trim();
    return id.isEmpty ? defaultAssistantKey : id;
  }

  static List<String> _cleanIds(Iterable<dynamic> ids) {
    return ids
        .map((item) => item.toString().trim())
        .where((item) => item.isNotEmpty)
        .toSet()
        .toList(growable: false);
  }

  static Map<String, List<String>> _cloneActiveIdsMap(
    Map<String, List<String>> source,
  ) {
    return <String, List<String>>{
      for (final entry in source.entries)
        entry.key: List<String>.from(entry.value),
    };
  }

  Future<List<QuickInstruction>> getAll() async {
    final cached = _cache;
    if (cached != null) return _seedBuiltInPlanIfNeeded(cached);

    final raw = _preferences.getString(itemsKey);
    if (raw == null || raw.isEmpty) {
      final seeded = await _seedDefaultFromLearningMode();
      return _seedBuiltInPlanIfNeeded(seeded);
    }

    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) {
        throw const FormatException('Quick instruction payload is not a list.');
      }
      var upgraded = false;
      final items = <QuickInstruction>[];
      for (var index = 0; index < decoded.length; index++) {
        final value = decoded[index];
        if (value is! Map) {
          throw const FormatException('Quick instruction item is not a map.');
        }
        final json = value.cast<String, dynamic>();
        final legacy = !json.containsKey('placement');
        var item = QuickInstruction.fromJson(json);
        if (item.id.trim().isEmpty) {
          item = item.copyWith(id: const Uuid().v4());
          upgraded = true;
        }
        if (legacy) {
          item = item.copyWith(
            title: item.title.trim().isEmpty
                ? (index == 0 ? 'Learning Mode' : 'Untitled')
                : item.title.trim(),
            placement: QuickInstructionPlacement.systemPrompt,
            triggerMode: QuickInstructionTriggerMode.oneShot,
            retainInHistory: true,
            toolPolicy: QuickInstructionToolPolicy(),
          );
          upgraded = true;
        } else if (item.title.trim().isEmpty) {
          item = item.copyWith(title: 'Untitled');
          upgraded = true;
        }
        items.add(item);
      }
      _cache = items;
      if (upgraded) await save(items);
      // await inside the try: an un-awaited future could let a seed failure
      // slip past the error handling below.
      return await _seedBuiltInPlanIfNeeded(items);
    } catch (error, stackTrace) {
      debugPrint(
        'QuickInstructionStore.getAll: invalid persisted payload: '
        '$error\n$stackTrace',
      );
      rethrow;
    }
  }

  static QuickInstruction get builtInPlan => QuickInstruction(
    id: builtInPlanId,
    title: 'plan',
    prompt: builtInPlanPrompt,
    group: 'Modes',
    placement: QuickInstructionPlacement.beforeUserMessage,
    triggerMode: QuickInstructionTriggerMode.persistent,
    retainInHistory: true,
    toolPolicy: QuickInstructionToolPolicy(
      enabled: true,
      disabledFilesystemToolNames: const <String>[
        WorkspaceToolNames.write,
        WorkspaceToolNames.patch,
        WorkspaceToolNames.delete,
        WorkspaceToolNames.mkdir,
        WorkspaceToolNames.move,
        WorkspaceToolNames.zip,
        WorkspaceToolNames.unzip,
        WorkspaceToolNames.download,
      ],
      shellBlockPatterns: builtInPlanShellBlockPatterns,
    ),
  );

  Future<List<QuickInstruction>> _seedBuiltInPlanIfNeeded(
    List<QuickInstruction> current,
  ) async {
    if (_preferences.getBool(builtInPlanSeedReceiptKey) == true) {
      return List<QuickInstruction>.from(current);
    }

    final next = List<QuickInstruction>.from(current);
    final alreadyPresent = next.any((item) => item.id == builtInPlanId);
    if (!alreadyPresent) {
      next.add(builtInPlan);
      await save(next);
    }

    final persisted = await _decodeItems(_preferences.getString(itemsKey));
    final persistedPlan = persisted
        .where((item) => item.id == builtInPlanId)
        .firstOrNull;
    if (persistedPlan == null) {
      throw StateError('Built-in plan quick instruction was not persisted.');
    }
    if (!alreadyPresent &&
        jsonEncode(persistedPlan.toJson()) !=
            jsonEncode(builtInPlan.toJson())) {
      throw StateError('Built-in plan quick instruction verification failed.');
    }
    if (!await _preferences.setBool(builtInPlanSeedReceiptKey, true)) {
      throw StateError(
        'Could not persist built-in plan quick instruction receipt.',
      );
    }
    _cache = next;
    return List<QuickInstruction>.from(next);
  }

  Future<List<QuickInstruction>> _seedDefaultFromLearningMode() async {
    String prompt;
    bool enabled;
    try {
      prompt = await _learningMode.getPrompt();
    } catch (error) {
      debugPrint(
        'QuickInstructionStore: failed to read Learning Mode prompt: $error',
      );
      prompt = LearningModeStore.defaultPrompt;
    }
    try {
      enabled = await _learningMode.isEnabled();
    } catch (error) {
      debugPrint(
        'QuickInstructionStore: failed to read Learning Mode state: $error',
      );
      enabled = false;
    }
    final item = QuickInstruction(
      id: const Uuid().v4(),
      title: 'Learning Mode',
      prompt: prompt,
      placement: QuickInstructionPlacement.systemPrompt,
    );
    await save(<QuickInstruction>[item]);
    if (enabled) {
      await setActiveIds(<String>[item.id]);
    }
    return <QuickInstruction>[item];
  }

  Future<void> migrateLegacyQuickPhrases({
    Map<String, String> assistantNames = const <String, String>{},
  }) async {
    final raw = _preferences.getString(legacyQuickPhrasesKey);
    if (raw == null || raw.isEmpty) return;

    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) {
        throw const FormatException(
          'Legacy quick phrase payload is not a list.',
        );
      }
      final phrases = <QuickPhrase>[];
      for (final value in decoded) {
        if (value is! Map) {
          throw const FormatException('Legacy quick phrase item is not a map.');
        }
        phrases.add(QuickPhrase.fromJson(value.cast<String, dynamic>()));
      }
      final current = await getAll();
      final existingIds = current.map((item) => item.id).toSet();
      final candidates = <_MigrationCandidate>[
        for (var index = 0; index < current.length; index++)
          _MigrationCandidate(
            item: current[index],
            originSuffix: '-Instruction Injection',
            canRename: current[index].id != builtInPlanId,
          ),
      ];

      for (var index = 0; index < phrases.length; index++) {
        final phrase = phrases[index];
        final assistantId = (phrase.assistantId ?? '').trim();
        final sourceIdentity = <String>[
          'cuplivo-legacy-quick-phrase',
          phrase.isGlobal ? 'global' : 'assistant',
          assistantId,
          phrase.id,
          '$index',
        ].join(':');
        final id = const Uuid().v5(Namespace.url.value, sourceIdentity);
        if (existingIds.contains(id)) continue;
        final assistantName = assistantNames[assistantId]?.trim();
        final suffix = phrase.isGlobal
            ? '-Global Quick Phrase'
            : '-(${assistantName == null || assistantName.isEmpty ? assistantId : assistantName}) Quick Phrase';
        candidates.add(
          _MigrationCandidate(
            item: QuickInstruction(
              id: id,
              title: phrase.title.trim().isEmpty
                  ? 'Untitled'
                  : phrase.title.trim(),
              prompt: phrase.content,
              group: migratedQuickPhraseGroup,
              placement: QuickInstructionPlacement.inputBox,
              triggerMode: QuickInstructionTriggerMode.oneShot,
              retainInHistory: true,
              toolPolicy: QuickInstructionToolPolicy(),
            ),
            originSuffix: suffix,
            canRename: true,
          ),
        );
      }

      final migrated = _resolveMigrationNames(candidates);
      await save(migrated);
      final verify = await _decodeItems(_preferences.getString(itemsKey));
      final expectedIds = migrated.map((item) => item.id).toSet();
      if (!verify.map((item) => item.id).toSet().containsAll(expectedIds)) {
        throw StateError('Quick instruction migration verification failed.');
      }
      if (!await _preferences.setBool(migrationReceiptKey, true)) {
        throw StateError(
          'Could not persist quick instruction migration receipt.',
        );
      }
      if (!await _preferences.remove(legacyQuickPhrasesKey)) {
        throw StateError('Could not remove migrated legacy quick phrases.');
      }
    } catch (error, stackTrace) {
      debugPrint(
        'QuickInstructionStore.migrateLegacyQuickPhrases failed; '
        'legacy data was retained: $error\n$stackTrace',
      );
      rethrow;
    }
  }

  List<QuickInstruction> _resolveMigrationNames(
    List<_MigrationCandidate> candidates,
  ) {
    final baseCounts = <String, int>{};
    for (final candidate in candidates) {
      final base = candidate.item.title.trim();
      baseCounts[base] = (baseCounts[base] ?? 0) + 1;
    }
    final used = <String>{};
    final result = <QuickInstruction>[];
    for (final candidate in candidates) {
      final base = candidate.item.title.trim();
      var name = base;
      if (candidate.canRename && (baseCounts[base] ?? 0) > 1) {
        name = '$base${candidate.originSuffix}';
      }
      final unsuffixed = name;
      var ordinal = 2;
      while (used.contains(name)) {
        name = '$unsuffixed-${ordinal++}';
      }
      used.add(name);
      result.add(candidate.item.copyWith(title: name));
    }
    return result;
  }

  Future<List<QuickInstruction>> _decodeItems(String? raw) async {
    if (raw == null || raw.isEmpty) return const <QuickInstruction>[];
    final decoded = jsonDecode(raw);
    if (decoded is! List) return const <QuickInstruction>[];
    return decoded
        .whereType<Map>()
        .map(
          (value) => QuickInstruction.fromJson(value.cast<String, dynamic>()),
        )
        .toList(growable: false);
  }

  Future<void> save(List<QuickInstruction> items) async {
    final encoded = jsonEncode(
      items.map((item) => item.toJson()).toList(growable: false),
    );
    if (!await _preferences.setString(itemsKey, encoded)) {
      throw StateError('Could not persist quick instructions.');
    }
    _cache = List<QuickInstruction>.from(items);
  }

  /// Drops object-level caches before a provider reload. Backup restore can
  /// replace business-preference rows underneath this long-lived store.
  void invalidateCache() {
    _cache = null;
    _activeIdsByAssistantCache = null;
  }

  Future<void> add(QuickInstruction item) async {
    final all = await getAll();
    all.add(item);
    await save(all);
  }

  Future<void> addMany(List<QuickInstruction> items) async {
    if (items.isEmpty) return;
    final all = await getAll();
    all.addAll(items);
    await save(all);
  }

  Future<void> update(QuickInstruction item) async {
    final all = await getAll();
    final index = all.indexWhere((candidate) => candidate.id == item.id);
    if (index < 0) return;
    all[index] = item;
    await save(all);
    if (!item.isSystem) await removeActiveIdEverywhere(item.id);
  }

  Future<void> delete(String id) async {
    final all = await getAll();
    all.removeWhere((item) => item.id == id);
    await save(all);
    await removeActiveIdEverywhere(id);
  }

  Future<void> clear() async {
    await save(const <QuickInstruction>[]);
    _activeIdsByAssistantCache = const <String, List<String>>{};
    await _preferences.remove(activeIdKey);
    await _preferences.remove(activeIdsKey);
    await _preferences.remove(activeIdsByAssistantKey);
  }

  Future<Map<String, List<String>>> getActiveIdsByAssistant() async {
    final map = await _loadActiveIdsMap();
    return _cloneActiveIdsMap(map);
  }

  Future<List<String>> getActiveIds({String? assistantId}) async {
    final map = await _loadActiveIdsMap();
    final key = assistantKey(assistantId);
    if (map.containsKey(key)) return List<String>.from(map[key]!);
    return List<String>.from(map[defaultAssistantKey] ?? const <String>[]);
  }

  Future<void> setActiveIds(List<String> ids, {String? assistantId}) async {
    final map = await _loadActiveIdsMap();
    map[assistantKey(assistantId)] = _cleanIds(ids);
    await _persistActiveIdsMap(map);
  }

  Future<void> setActiveIdsMap(Map<String, List<String>> map) async {
    await _persistActiveIdsMap(<String, List<String>>{
      for (final entry in map.entries) entry.key: _cleanIds(entry.value),
    });
  }

  Future<List<QuickInstruction>> getActives({String? assistantId}) async {
    final ids = (await getActiveIds(assistantId: assistantId)).toSet();
    if (ids.isEmpty) return const <QuickInstruction>[];
    return (await getAll())
        .where((item) => item.isSystem && ids.contains(item.id))
        .toList(growable: false);
  }

  Future<int> activeAssistantReferenceCount(String id) async {
    final map = await _loadActiveIdsMap();
    return map.values.where((ids) => ids.contains(id)).length;
  }

  Future<void> removeActiveIdEverywhere(String id) async {
    final map = await _loadActiveIdsMap();
    var changed = false;
    for (final entry in map.entries) {
      final next = entry.value.where((item) => item != id).toList();
      if (next.length != entry.value.length) {
        entry.value
          ..clear()
          ..addAll(next);
        changed = true;
      }
    }
    if (changed) await _persistActiveIdsMap(map);
  }

  Future<Map<String, List<String>>> _loadActiveIdsMap() async {
    final cached = _activeIdsByAssistantCache;
    if (cached != null) return _cloneActiveIdsMap(cached);
    var map = <String, List<String>>{};
    final raw = _preferences.getString(activeIdsByAssistantKey);
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          decoded.forEach((key, value) {
            map[key.toString()] = _cleanIds(value is List ? value : const []);
          });
        }
      } catch (error) {
        debugPrint('QuickInstructionStore: invalid active map: $error');
      }
    }
    if (map.isEmpty) {
      final legacy = _loadLegacyActiveIds();
      if (legacy.isNotEmpty) map[defaultAssistantKey] = legacy;
    }
    _activeIdsByAssistantCache = map;
    return _cloneActiveIdsMap(map);
  }

  List<String> _loadLegacyActiveIds() {
    final raw = _preferences.getString(activeIdsKey);
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is List) return _cleanIds(decoded);
      } catch (error) {
        debugPrint('QuickInstructionStore: invalid legacy active IDs: $error');
      }
    }
    final single = _preferences.getString(activeIdKey);
    return single == null ? const <String>[] : _cleanIds(<String>[single]);
  }

  Future<void> _persistActiveIdsMap(Map<String, List<String>> map) async {
    final clean = <String, List<String>>{
      for (final entry in map.entries) entry.key: _cleanIds(entry.value),
    };
    if (!await _preferences.setString(
      activeIdsByAssistantKey,
      jsonEncode(clean),
    )) {
      throw StateError('Could not persist quick instruction bindings.');
    }
    _activeIdsByAssistantCache = _cloneActiveIdsMap(clean);
    final defaults = clean[defaultAssistantKey] ?? const <String>[];
    if (defaults.isEmpty) {
      await _preferences.remove(activeIdKey);
      await _preferences.remove(activeIdsKey);
    } else {
      await _preferences.setString(activeIdKey, defaults.first);
      await _preferences.setString(activeIdsKey, jsonEncode(defaults));
    }
  }
}

class _MigrationCandidate {
  const _MigrationCandidate({
    required this.item,
    required this.originSuffix,
    required this.canRename,
  });

  final QuickInstruction item;
  final String originSuffix;
  final bool canRename;
}
