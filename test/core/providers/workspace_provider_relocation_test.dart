import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:Cuplivo/core/database/business_preferences.dart';
import 'package:Cuplivo/core/providers/workspace_provider.dart';
import 'package:Cuplivo/core/services/workspace/linux_sandbox_service.dart';
import 'package:Cuplivo/core/services/workspace/workspace_terminal_native_bridge.dart';
import 'package:Cuplivo/utils/app_directories.dart';

class _FakePathProviderPlatform extends PathProviderPlatform {
  _FakePathProviderPlatform(this.supportPath, this.documentsPath);

  final String supportPath;
  final String documentsPath;

  @override
  Future<String?> getApplicationSupportPath() async => supportPath;

  @override
  Future<String?> getApplicationDocumentsPath() async => documentsPath;
}

/// Relocation never touches terminals, but the provider requires a port;
/// every method throws so an unexpected call fails loudly.
class _NoopTerminal implements WorkspaceTerminalPort {
  @override
  Future<WorkspaceTerminalSessionState> startSession({
    required String workspaceId,
    required String workspaceHostPath,
    required SandboxPtyLaunchSpec launchSpec,
    required bool durable,
    required bool autoStarted,
    required WorkspaceTerminalNotificationStrings notificationStrings,
  }) => throw UnimplementedError();

  @override
  Future<WorkspaceTerminalSessionState> getSessionState(String workspaceId) {
    return Future<WorkspaceTerminalSessionState>.value(
      WorkspaceTerminalSessionState.absent(workspaceId),
    );
  }

  @override
  Future<WorkspaceTerminalSessionState> setDurable(
    String workspaceId,
    bool durable, {
    required WorkspaceTerminalNotificationStrings notificationStrings,
  }) => throw UnimplementedError();

  @override
  Future<void> stopSession(String workspaceId) => throw UnimplementedError();

  @override
  Future<void> stopSessionForWorkspacePath(String workspaceHostPath) =>
      throw UnimplementedError();

  @override
  Future<void> stopAutoSessionIfDetached(String workspaceId) =>
      throw UnimplementedError();

  @override
  Future<void> stopAllSessions() => throw UnimplementedError();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late String support;
  late String docs;
  late WorkspaceProvider provider;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('kelivo_reloc_test_');
    support = '${tmp.path}/support';
    docs = '${tmp.path}/documents';
    Directory(support).createSync();
    Directory(docs).createSync();
    PathProviderPlatform.instance = _FakePathProviderPlatform(support, docs);
    // Physical mock is required: workspaces_dir_v1 stays on SharedPreferences
    // and several tests also read it through AppDirectories.
    SharedPreferences.setMockInitialValues({});
    // Relocation is a desktop feature: force the desktop target so the
    // workspaces_dir_v1 pref is honored and the support dir is used.
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    provider = WorkspaceProvider(
      preferences: BusinessPreferences.memoryForTests(),
      terminal: _NoopTerminal(),
    );
    await provider.init();
  });

  tearDown(() async {
    provider.dispose();
    debugDefaultTargetPlatformOverride = null;
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  group('AppDirectories path helpers', () {
    test('root parents match children (drive root / POSIX root)', () {
      expect(AppDirectories.isPathInside('C:/appdata/x', 'C:/'), isTrue);
      expect(AppDirectories.isPathInside('/appdata/x', '/'), isTrue);
      expect(AppDirectories.isPathInside('C:/appdata2', 'C:/appdata'), isFalse);
      expect(AppDirectories.isPathInside('C:/', 'C:/appdata'), isFalse);
      expect(AppDirectories.pathsOverlap('C:/', 'C:/appdata/upload'), isTrue);
      expect(AppDirectories.pathsOverlap('D:/', 'C:/appdata/upload'), isFalse);
    });

    test('isFilesystemRootPath recognizes roots in both canonical forms', () {
      // 'C:/' — the Windows-normalized drive root (trailing slash kept).
      // 'C:'  — the same path after POSIX normalization (slash stripped).
      // The load-time guard must reject both or a restored pref slips
      // through on the other platform.
      expect(AppDirectories.isFilesystemRootPath('C:/'), isTrue);
      expect(AppDirectories.isFilesystemRootPath('C:'), isTrue);
      expect(AppDirectories.isFilesystemRootPath('c:'), isTrue);
      expect(AppDirectories.isFilesystemRootPath('/'), isTrue);
      expect(AppDirectories.isFilesystemRootPath('C:/Users'), isFalse);
      expect(AppDirectories.isFilesystemRootPath('/tmp/x'), isFalse);
    });
  });

  group('setWorkspacesRootLocation validation', () {
    test(
      'relocating to the app-data root (contains the sandbox) is rejected',
      () async {
        final err = await provider.setWorkspacesRootLocation(
          support,
          moveFiles: false,
        );
        expect(err, WorkspaceProvider.errorSyncOverlap);
      },
    );

    test('relocating into a sync tree (upload) is rejected', () async {
      final err = await provider.setWorkspacesRootLocation(
        '$support/upload',
        moveFiles: false,
      );
      expect(err, WorkspaceProvider.errorSyncOverlap);
    });

    test('relocating inside the current sandbox is rejected', () async {
      final err = await provider.setWorkspacesRootLocation(
        '$support/workspaces/sub',
        moveFiles: false,
      );
      expect(err, WorkspaceProvider.errorInsideWorkspaces);
    });

    test('relocating to a filesystem root is rejected', () async {
      final err = await provider.setWorkspacesRootLocation(
        'C:/',
        moveFiles: false,
      );
      expect(err, WorkspaceProvider.errorPathInvalid);
    });

    test('relocating to a relative path is rejected', () async {
      final err = await provider.setWorkspacesRootLocation(
        'relative/workspaces',
        moveFiles: false,
      );
      expect(err, WorkspaceProvider.errorPathInvalid);
    });

    test('relocating to the same path is a no-op success', () async {
      final err = await provider.setWorkspacesRootLocation(
        '$support/workspaces',
        moveFiles: true,
      );
      expect(err, isNull);
    });
  });

  group('setWorkspacesRootLocation move', () {
    test('non-empty destination with moveFiles is rejected', () async {
      final dst = Directory('${tmp.path}/newhome')..createSync();
      File('${dst.path}/keep.txt').writeAsStringSync('x');
      final err = await provider.setWorkspacesRootLocation(
        dst.path,
        moveFiles: true,
      );
      expect(err, WorkspaceProvider.errorDestinationNotEmpty);
      // Nothing changed.
      expect(provider.rootPath, '$support/workspaces');
    });

    test('non-empty destination without moveFiles is allowed', () async {
      final dst = Directory('${tmp.path}/newhome')..createSync();
      File('${dst.path}/keep.txt').writeAsStringSync('x');
      final err = await provider.setWorkspacesRootLocation(
        dst.path,
        moveFiles: false,
      );
      expect(err, isNull);
      expect(provider.rootPath, dst.path);
    });

    test('successful relocation moves files, persists the pref, and updates '
        'the single resolution point', () async {
      final ws = Directory('$support/workspaces');
      ws.createSync(recursive: true);
      File('${ws.path}/a.txt').writeAsStringSync('hello');
      final dst = Directory('${tmp.path}/newhome2')..createSync();

      final err = await provider.setWorkspacesRootLocation(
        dst.path,
        moveFiles: true,
      );
      expect(err, isNull);

      expect(provider.rootPath, dst.path);
      expect(File('${dst.path}/a.txt').readAsStringSync(), 'hello');
      expect(
        ws.existsSync(),
        isFalse,
        reason: 'same-volume rename moves the dir',
      );
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(AppDirectories.workspacesDirPrefsKey), dst.path);
      final resolved = await AppDirectories.getWorkspacesDirectory();
      expect(resolved.path, dst.path);
    });

    test(
      'destination with a missing parent forces the copy fallback: nested '
      'directories land intact, mtimes are preserved, source is removed',
      () async {
        final ws = Directory('$support/workspaces');
        ws.createSync(recursive: true);
        Directory('${ws.path}/nested/deep').createSync(recursive: true);
        File('${ws.path}/top.txt').writeAsStringSync('t');
        final nested = File('${ws.path}/nested/deep/f.txt');
        nested.writeAsStringSync('f');
        final oldMtime = nested.lastModifiedSync();
        // Parent of the destination does not exist: rename throws on every
        // platform, so this deterministically exercises the copy fallback
        // (the same code path a cross-volume move takes).
        final dst = '${tmp.path}/not-there/dest';

        final err = await provider.setWorkspacesRootLocation(
          dst,
          moveFiles: true,
        );
        expect(err, isNull);

        expect(File('$dst/top.txt').readAsStringSync(), 't');
        final movedNested = File('$dst/nested/deep/f.txt');
        expect(movedNested.readAsStringSync(), 'f');
        expect(
          movedNested.lastModifiedSync().difference(oldMtime).inSeconds.abs(),
          lessThan(2),
          reason: 'relocation is a physical move — mtimes survive the copy',
        );
        expect(ws.existsSync(), isFalse);
        expect(provider.rootPath, dst);
      },
    );
  });

  group('workspaces_dir_v1 load-time validation', () {
    test(
      'restored drive-root pref falls back to the default location',
      () async {
        SharedPreferences.setMockInitialValues({
          AppDirectories.workspacesDirPrefsKey: 'C:/',
        });
        final resolved = await AppDirectories.getWorkspacesDirectory();
        expect(resolved.path, '$support/workspaces');
      },
    );

    test(
      'restored sync-tree pref falls back to the default location',
      () async {
        SharedPreferences.setMockInitialValues({
          AppDirectories.workspacesDirPrefsKey: '$support/upload',
        });
        final resolved = await AppDirectories.getWorkspacesDirectory();
        expect(resolved.path, '$support/workspaces');
      },
    );

    test('restored relative pref falls back to the default location', () async {
      SharedPreferences.setMockInitialValues({
        AppDirectories.workspacesDirPrefsKey: 'relative/workspaces',
      });
      final resolved = await AppDirectories.getWorkspacesDirectory();
      expect(resolved.path, '$support/workspaces');
    });

    test('restored valid pref is honored', () async {
      SharedPreferences.setMockInitialValues({
        AppDirectories.workspacesDirPrefsKey: '${tmp.path}/elsewhere',
      });
      final resolved = await AppDirectories.getWorkspacesDirectory();
      expect(resolved.path, '${tmp.path}/elsewhere');
    });
  });
}
