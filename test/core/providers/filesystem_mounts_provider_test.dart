import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:Cuplivo/core/database/business_preferences.dart';
import 'package:Cuplivo/core/providers/filesystem_mounts_provider.dart';
import 'package:Cuplivo/core/services/mcp/kelivo_filesystem/kelivo_filesystem_server.dart';

class _FakePathProviderPlatform extends PathProviderPlatform {
  _FakePathProviderPlatform(this.supportPath, this.documentsPath);

  final String supportPath;
  final String documentsPath;

  @override
  Future<String?> getApplicationSupportPath() async => supportPath;

  @override
  Future<String?> getApplicationDocumentsPath() async => documentsPath;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('validateMountConfig', () {
    late Directory tmp;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('kelivo_mounts_test_');
    });

    tearDown(() {
      try {
        tmp.deleteSync(recursive: true);
      } catch (_) {}
    });

    test('reserved alias workspaces returns errorAliasReserved', () {
      final err = validateMountConfig(
        alias: 'workspaces',
        path: tmp.path,
        existing: const [],
      );
      expect(err, FilesystemMountsProvider.errorAliasReserved);
    });

    test('syntax-invalid alias returns errorAliasInvalid', () {
      for (final bad in ['UPPER', 'has space', 'a/b', 'a..', '-x']) {
        final err = validateMountConfig(
          alias: bad,
          path: tmp.path,
          existing: const [],
        );
        expect(err, FilesystemMountsProvider.errorAliasInvalid, reason: bad);
      }
    });

    test('duplicate alias returns errorAliasDuplicate', () {
      final err = validateMountConfig(
        alias: 'docs',
        path: tmp.path,
        existing: const [
          FilesystemMount(alias: 'docs', path: '/x', readOnly: true),
        ],
      );
      expect(err, FilesystemMountsProvider.errorAliasDuplicate);
    });

    test('relative path returns errorPathInvalid', () {
      final err = validateMountConfig(
        alias: 'docs',
        path: 'relative/path',
        existing: const [],
      );
      expect(err, FilesystemMountsProvider.errorPathInvalid);
    });

    test('UNC path is accepted as absolute (Windows)', () {
      final err = validateMountConfig(
        alias: 'share',
        path: r'\\server\share',
        existing: const [],
      );
      // Accepts the syntax; existence check is platform-dependent.
      expect(
        err == FilesystemMountsProvider.errorPathInvalid,
        isFalse,
        reason: 'UNC paths are absolute on Windows',
      );
    });

    test('non-existent directory returns errorPathNotFound', () {
      final err = validateMountConfig(
        alias: 'docs',
        path: '${tmp.path}/missing_dir',
        existing: const [],
      );
      expect(err, FilesystemMountsProvider.errorPathNotFound);
    });

    test('mount inside a sync root returns errorSyncOverlap', () {
      final syncRoot = Directory('${tmp.path}/sync')..createSync();
      final inside = Directory('${syncRoot.path}/sub')..createSync();
      final err = validateMountConfig(
        alias: 'docs',
        path: inside.path,
        existing: const [],
        syncRoots: [syncRoot.path],
      );
      expect(err, FilesystemMountsProvider.errorSyncOverlap);
    });

    test('mount containing a sync root returns errorSyncOverlap', () {
      final outer = Directory('${tmp.path}/outer')..createSync();
      final syncRoot = Directory('${outer.path}/sync')..createSync();
      final err = validateMountConfig(
        alias: 'docs',
        path: outer.path,
        existing: const [],
        syncRoots: [syncRoot.path],
      );
      expect(err, FilesystemMountsProvider.errorSyncOverlap);
    });

    test('mount at a drive root overlapping a sync root returns '
        'errorSyncOverlap', () {
      final err = validateMountConfig(
        alias: 'docs',
        path: 'C:/',
        existing: const [],
        syncRoots: ['C:/appdata/upload'],
      );
      // The overlap check runs before the existence check, so this is
      // platform-neutral even where C:/ does not exist.
      expect(err, FilesystemMountsProvider.errorSyncOverlap);
    });

    test('mount adjacent to a sync root is accepted', () {
      final syncRoot = Directory('${tmp.path}/sync')..createSync();
      final sibling = Directory('${tmp.path}/sibling')..createSync();
      final err = validateMountConfig(
        alias: 'docs',
        path: sibling.path,
        existing: const [],
        syncRoots: [syncRoot.path],
      );
      expect(err, isNull);
    });

    test('valid config returns null', () {
      final err = validateMountConfig(
        alias: 'docs',
        path: tmp.path,
        existing: const [],
      );
      expect(err, isNull);
    });
  });

  group('legacy persisted mounts at load', () {
    late Directory tmp;
    late String support;
    late BusinessPreferences businessPrefs;

    setUp(() async {
      tmp = Directory.systemTemp.createTempSync('kelivo_mounts_load_test_');
      support = '${tmp.path}/support';
      Directory(support).createSync();
      PathProviderPlatform.instance = _FakePathProviderPlatform(support, '');
      SharedPreferences.setMockInitialValues({});
      businessPrefs = BusinessPreferences.memoryForTests();
      // Mount loading is a desktop behavior.
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    });

    tearDown(() {
      debugDefaultTargetPlatformOverride = null;
      try {
        tmp.deleteSync(recursive: true);
      } catch (_) {}
    });

    Future<FilesystemMountsProvider> makeProvider() async {
      final provider = FilesystemMountsProvider(preferences: businessPrefs);
      await provider.init();
      return provider;
    }

    test(
      'mount overlapping the sync scope is skipped but kept in prefs',
      () async {
        businessPrefs = BusinessPreferences.memoryForTests({
          FilesystemMountsProvider.prefsKey: jsonEncode([
            FilesystemMount(
              alias: 'photos',
              path: '$support/workspaces/photos',
              readOnly: true,
            ).toJson(),
          ]),
        });
        final provider = await makeProvider();
        expect(provider.externalMounts, isEmpty);
        expect(
          businessPrefs.getString(FilesystemMountsProvider.prefsKey),
          isNotNull,
          reason: 'the config is preserved — only the mount is skipped',
        );
      },
    );

    test('non-overlapping legacy mount still loads', () async {
      businessPrefs = BusinessPreferences.memoryForTests({
        FilesystemMountsProvider.prefsKey: jsonEncode([
          FilesystemMount(
            alias: 'photos',
            path: '${tmp.path}/data/photos',
            readOnly: true,
          ).toJson(),
        ]),
      });
      final provider = await makeProvider();
      expect(provider.externalMounts, hasLength(1));
      expect(provider.externalMounts.first.alias, 'photos');
    });
  });
}
