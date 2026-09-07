import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:Cuplivo/core/database/business_preferences.dart';

import '../services/mcp/kelivo_filesystem/kelivo_filesystem_server.dart';
import '../../utils/app_directories.dart';
import '../../utils/platform_utils.dart';

/// Owns the global filesystem mount configuration for `@kelivo/filesystem`.
///
/// The built-in `@workspaces` mount (rw sandbox; host location owned and
/// relocated by `WorkspaceProvider` on desktop via
/// [AppDirectories.workspacesDirPrefsKey]) is always present and is the only
/// mount on mobile. External mounts are desktop-only, never sync, and live in
/// SharedPreferences (`filesystem_mounts_v1`), which means they ride
/// `settings.json` in backups automatically — but they are loaded ONLY on
/// desktop, so a backup restored on a phone can never surface a foreign host
/// path (see CONTEXT.md "Filesystem MCP").
class FilesystemMountsProvider extends ChangeNotifier {
  final BusinessPreferences _preferences;
  static const String prefsKey = 'filesystem_mounts_v1';
  static const String workspacesAlias = 'workspaces';

  static const String errorAliasInvalid = 'alias_invalid';
  static const String errorAliasReserved = 'alias_reserved';
  static const String errorAliasDuplicate = 'alias_duplicate';
  static const String errorPathInvalid = 'path_invalid';
  static const String errorPathNotFound = 'path_not_found';
  static const String errorSyncOverlap = 'sync_overlap';

  final List<FilesystemMount> _external = <FilesystemMount>[];
  String? _workspacesPath;
  bool _loaded = false;

  bool get loaded => _loaded;

  FilesystemMount? get workspaces {
    final path = _workspacesPath;
    if (path == null) return null;
    return FilesystemMount(alias: workspacesAlias, path: path, readOnly: false);
  }

  List<FilesystemMount> get externalMounts => List.unmodifiable(_external);

  /// [workspaces] first, then external mounts.
  List<FilesystemMount> get allMounts => [
    if (workspaces != null) workspaces!,
    ..._external,
  ];

  FilesystemMountsProvider({required this._preferences}) {
    unawaited(init());
  }

  Future<void> init() async {
    if (_loaded) return;
    final prefs = _preferences;
    if (PlatformUtils.isDesktopTarget) {
      final raw = prefs.getString(prefsKey);
      if (raw != null && raw.isNotEmpty) {
        try {
          final list = (jsonDecode(raw) as List)
              .whereType<Map>()
              .map((e) => FilesystemMount.fromJson(e.cast<String, dynamic>()))
              .toList();
          // Re-validate persisted mounts against the sync scope: a legacy
          // mount created before the overlap check existed must not stay
          // mounted — its host content would silently be swept into backup
          // packs. The config stays in prefs (no data loss); the user can
          // re-add an intentional mount elsewhere.
          final syncRoots = await AppDirectories.getSyncRootPaths();
          _external.clear();
          for (final m in list) {
            if (syncRoots.any((r) => AppDirectories.pathsOverlap(m.path, r))) {
              debugPrint(
                'FilesystemMountsProvider: skipping mount @${m.alias} '
                'overlapping the sync scope: ${m.path}',
              );
              continue;
            }
            _external.add(m);
          }
        } catch (e) {
          debugPrint('FilesystemMountsProvider: failed to load mounts: $e');
        }
      }
    } else {
      // External mounts are desktop-only. The config may still ride a backup's
      // settings.json onto a phone — keep it persisted but never mounted.
      _external.clear();
    }
    final wsDir = await AppDirectories.getWorkspacesDirectory();
    try {
      await wsDir.create(recursive: true);
    } catch (e) {
      debugPrint(
        'FilesystemMountsProvider: failed to create '
        'workspaces dir: $e',
      );
    }
    _workspacesPath = wsDir.path;
    _loaded = true;
    notifyListeners();
  }

  /// Adds an external mount. Returns `null` on success or an error code
  /// (one of the `error*` constants) for the UI to localize.
  Future<String?> addExternalMount({
    required String alias,
    required String path,
    bool readOnly = true,
  }) async {
    await init(); // serialize with the constructor-triggered load
    final syncRoots = await AppDirectories.getSyncRootPaths();
    final err = validateMountConfig(
      alias: alias,
      path: path,
      existing: _external,
      syncRoots: syncRoots,
    );
    if (err != null) return err;
    _external.add(
      FilesystemMount(alias: alias, path: path, readOnly: readOnly),
    );
    await _persist();
    notifyListeners();
    return null;
  }

  Future<String?> updateExternalMount({
    required String alias,
    String? path,
    bool? readOnly,
  }) async {
    await init();
    final idx = _external.indexWhere((m) => m.alias == alias);
    if (idx < 0) return errorAliasInvalid;
    final current = _external[idx];
    final newPath = path ?? current.path;
    final newReadOnly = readOnly ?? current.readOnly;
    final syncRoots = await AppDirectories.getSyncRootPaths();
    final err = validateMountConfig(
      alias: current.alias,
      path: newPath,
      existing: _external.where((m) => m.alias != alias).toList(),
      syncRoots: syncRoots,
    );
    if (err != null) return err;
    _external[idx] = current.copyWith(path: newPath, readOnly: newReadOnly);
    await _persist();
    notifyListeners();
    return null;
  }

  Future<void> removeExternalMount(String alias) async {
    await init();
    _external.removeWhere((m) => m.alias == alias);
    await _persist();
    notifyListeners();
  }

  Future<void> _persist() async {
    final prefs = _preferences;
    await prefs.setString(
      prefsKey,
      jsonEncode(_external.map((e) => e.toJson()).toList()),
    );
  }
}

/// Validates an external mount config. Returns `null` on success or an error
/// code (one of the `FilesystemMountsProvider.error*` constants).
///
/// [syncRoots] are the backup/LAN-sync packed directories; a mount inside or
/// containing one would silently enter the sync scope despite "external
/// mounts never sync" (see CONTEXT.md "Filesystem MCP").
String? validateMountConfig({
  required String alias,
  required String path,
  required List<FilesystemMount> existing,
  List<String> syncRoots = const [],
}) {
  if (alias == FilesystemMountsProvider.workspacesAlias) {
    return FilesystemMountsProvider.errorAliasReserved;
  }
  if (!isValidMountAlias(alias)) {
    return FilesystemMountsProvider.errorAliasInvalid;
  }
  if (existing.any((m) => m.alias == alias)) {
    return FilesystemMountsProvider.errorAliasDuplicate;
  }
  final trimmed = path.trim();
  final isUnc = trimmed.startsWith('\\\\');
  if (trimmed.isEmpty ||
      !(trimmed.startsWith('/') || isUnc || _hasDrivePrefix(trimmed))) {
    return FilesystemMountsProvider.errorPathInvalid;
  }
  for (final r in syncRoots) {
    if (AppDirectories.pathsOverlap(trimmed, r)) {
      return FilesystemMountsProvider.errorSyncOverlap;
    }
  }
  bool exists = false;
  try {
    // Unreachable UNC shares and permission errors make existsSync THROW
    // rather than return false — treat any failure as "not found".
    exists = Directory(trimmed).existsSync();
  } catch (_) {}
  if (!exists) {
    return FilesystemMountsProvider.errorPathNotFound;
  }
  return null;
}

bool _hasDrivePrefix(String s) {
  if (s.length < 3) return false;
  final c0 = s.codeUnitAt(0);
  final isLetter = (c0 >= 0x41 && c0 <= 0x5a) || (c0 >= 0x61 && c0 <= 0x7a);
  return isLetter && s[1] == ':' && (s[2] == '/' || s[2] == '\\');
}
