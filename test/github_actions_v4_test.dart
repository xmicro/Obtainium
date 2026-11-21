import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:obtainium/app_sources/github_actions.dart';
import 'package:obtainium/services/github_actions_archive_service.dart';

void main() {
  test('upload name is exact, not a regex or a file filter', () {
    expect(actionsArtifactNameMatches('artifact', 'artifact'), isTrue);
    expect(actionsArtifactNameMatches('art', 'artifact'), isFalse);
    expect(actionsArtifactNameMatches('.*', 'artifact'), isFalse);
    expect(actionsArtifactNameMatches('signed.zip', 'artifact'), isFalse);
  });

  test('simple text matches literal filename fragments in order', () {
    final pattern = actionsLiteralFilenamePattern(['release-', 'arm64']);
    expect(actionsFileMatches(pattern, 'release-v3-arm64.apk'), isTrue);
    expect(actionsFileMatches(pattern, 'release-arm32.apk'), isFalse);
    expect(actionsFileMatches(pattern, 'arm64-release.apk'), isFalse);
    final literal = actionsLiteralFilenamePattern(['a+b[', 'signed']);
    expect(actionsFileMatches(literal, 'a+b[.zip-signed.zip'), isTrue);
    expect(actionsFileMatches(literal, 'aaab.zip-signed.zip'), isFalse);
  });

  test('anywhere matches APK basenames regardless of containing ZIP', () {
    const selection = ActionsFileSelection(apkPattern: 'arm64');
    expect(selection.matchesApk('arm64.apk'), isTrue);
    expect(selection.matchesApk('arm64.apk', parentZip: 'signed.zip'), isTrue);
    expect(selection.matchesApk('arm64.apk', parentZip: 'debug.ZIP'), isTrue);
    expect(selection.matchesApk('app.apk', parentZip: 'arm64.zip'), isFalse);
    expect(selection.matchesApk('arm64/app.apk'), isFalse);
    expect(selection.matchesApk('arm64.apkm'), isTrue);
    expect(selection.matchesApk('arm64.txt'), isFalse);
    expect(selection.matchesEntry(const ActionsArchiveEntry('second.zip',
        parentZip: 'first.zip')), isFalse);
  });

  test('directory location modes and ZIP names are independent', () {
    const direct = ActionsFileSelection(location: ActionsApkLocation.direct,
        apkPattern: 'arm64', zipPattern: '[');
    expect(direct.matchesApk('arm64.apk'), isTrue);
    expect(direct.matchesApk('arm64.apk', parentZip: 'release.zip'), isFalse);
    expect(direct.allowsZip('release.zip'), isFalse);
    const nested = ActionsFileSelection(location: ActionsApkLocation.nested,
        apkPattern: 'arm64', zipPattern: 'release');
    expect(nested.matchesApk('arm64.apk'), isFalse);
    expect(nested.matchesApk('arm64.apk', parentZip: 'release.ZIP'), isTrue);
    expect(nested.matchesApk('arm64.apk', parentZip: 'debug.zip'), isFalse);
    expect(nested.matchesApk('universal.apk', parentZip: 'release.zip'), isFalse);
    expect(nested.allowsZip('release.zip'), isTrue);
    expect(nested.allowsZip('release.apk'), isFalse);
    expect(nested.matchesApk('arm64.apk', parentZip: 'release/debug.zip'), isFalse);
    const anyNested = ActionsFileSelection(location: ActionsApkLocation.nested);
    expect(anyNested.matchesApk('app.apk', parentZip: 'debug.zip'), isTrue);
    expect(anyNested.matchesApk('app.apk'), isFalse);
  });

  test('ZIP inspection lists inner APKs without extracting APK payloads', () async {
    final scratch = await Directory.systemTemp.createTemp('actions-v4-index-');
    try {
      final inside = Archive()
        ..addFile(ArchiveFile.bytes('arm64.apk', [1, 2, 3]))
        ..addFile(ArchiveFile.bytes('nested-again.zip', [4, 5]));
      final nested = ZipEncoder().encodeBytes(inside);
      final outside = Archive()
        ..addFile(ArchiveFile.bytes('signed-release.zip', nested))
        ..addFile(ArchiveFile.bytes('direct.apk', [6, 7]));
      final path = File('${scratch.path}/outer.zip');
      await path.writeAsBytes(ZipEncoder().encodeBytes(outside));
      final listed = await inspectActionsArtifact(path, scratch);
      final paths = listed.map((entry) => (entry.path, entry.parentZip)).toList();
      expect(paths, [
        ('direct.apk', null),
        ('signed-release.zip', null),
        ('arm64.apk', 'signed-release.zip'),
        ('nested-again.zip', 'signed-release.zip'),
      ]);
      expect(File('${scratch.path}/arm64.apk').existsSync(), isFalse);
      const selection = ActionsFileSelection(location: ActionsApkLocation.nested,
          zipPattern: 'signed-', apkPattern: 'arm64');
      expect(listed.where((e) => e.isInstallable && selection.matchesEntry(e))
          .map((e) => e.path), ['arm64.apk']);
    } finally {
      await scratch.delete(recursive: true);
    }
  });

  test('default events include manual but exclude PR and chained runs', () {
    final events = githubActionsSelectedEvents({});
    expect(events, contains('workflow_dispatch'));
    expect(events, isNot(contains('pull_request')));
    expect(events, isNot(contains('workflow_run')));
    expect(githubActionsRunIsEligible(
      {'conclusion': 'success', 'event': 'workflow_dispatch'}, events), isTrue);
    expect(githubActionsRunIsEligible(
      {'conclusion': 'success', 'event': 'pull_request'}, events), isFalse);
    expect(githubActionsRunIsEligible(
      {'conclusion': 'failure', 'event': 'workflow_dispatch'}, events), isFalse);
  });

  test('newest eligible successful run with exact upload is selected', () async {
    final calls = <String>[];
    final api = GitHubActionsApi('https://api.github.com/repos/test/repo', (url) async {
      calls.add(url);
      final uri = Uri.parse(url);
      if (uri.path.endsWith('/runs')) {
        return http.Response(jsonEncode({'workflow_runs': [
          {'id': 4, 'run_number': 304, 'run_attempt': 1,
           'conclusion': 'success', 'event': 'pull_request',
           'run_started_at': '2026-11-16T11:00:00Z'},
          {'id': 3, 'run_number': 303, 'run_attempt': 2,
           'conclusion': 'success', 'event': 'push',
           'run_started_at': '2026-11-16T10:00:00Z'},
          {'id': 2, 'run_number': 302, 'run_attempt': 1,
           'conclusion': 'success', 'event': 'push',
           'run_started_at': '2026-11-16T09:00:00Z'},
        ]}), 200);
      }
      final id = int.parse(uri.path.split('/').reversed.skip(1).first);
      return http.Response(jsonEncode({'artifacts': [
        {'id': id * 10, 'name': id == 3 ? 'debug' : 'artifact', 'expired': false}
      ]}), 200);
    });
    final result = await api.latestBuild(
      workflow: '123', branch: 'main', artifactName: 'artifact',
      allowedEvents: githubActionsDefaultEvents,
    );
    expect(result?.version, '302.1');
    expect(result?.artifacts.single['id'], 20);
    expect(calls.where((s) => s.contains('/runs/4/artifacts')), isEmpty);
  });

  for (final location in ActionsApkLocation.values) {
    test('preview and extraction agree in $location mode with mixed files', () async {
      final scratch = await Directory.systemTemp.createTemp('actions-v4-parity-');
      try {
        final root = await Directory('${scratch.path}/contents').create();
        await File('${root.path}/release.ZIP').writeAsBytes([]);
        await File('${root.path}/debug.zip').writeAsBytes([]);
        await File('${root.path}/direct-arm64.apk').writeAsBytes([]);
        await File('${root.path}/direct-x86.apk').writeAsBytes([]);
        final entries = <ActionsArchiveEntry>[
          const ActionsArchiveEntry('direct-arm64.apk'),
          const ActionsArchiveEntry('direct-x86.apk'),
          for (final zip in ['release.ZIP', 'debug.zip']) ...[
            ActionsArchiveEntry(zip),
            ActionsArchiveEntry('$zip-arm64.apk', parentZip: zip),
            ActionsArchiveEntry('$zip-x86.apk', parentZip: zip),
            ActionsArchiveEntry('deeper.zip', parentZip: zip),
          ],
        ];
        final selection = ActionsFileSelection(location: location,
            zipPattern: 'release', apkPattern: 'arm64');
        final expanded = <String>[];
        await prepareActionsArchive(root, selection: selection,
          extract: (file, target) async {
            final name = file.uri.pathSegments.last;
            expanded.add(name);
            await File('${target.path}/$name-arm64.apk').writeAsBytes([]);
            await File('${target.path}/$name-x86.apk').writeAsBytes([]);
            await File('${target.path}/deeper.zip').writeAsBytes([]);
          });
        final actual = root.listSync(recursive: true).whereType<File>()
            .where((file) => actionsIsInstallableFile(file.path))
            .map((file) => file.uri.pathSegments.last).toList()..sort();
        final expected = entries.where((e) => e.isInstallable && selection.matchesEntry(e))
            .map((e) => e.path).toList()..sort();
        expect(actual, expected);
        expect(expanded.toSet(), entries.where((e) => e.isOuterZip && selection.matchesEntry(e))
            .map((e) => e.path).toSet());
        expect(expanded, isNot(contains('deeper.zip')));
        if (location == ActionsApkLocation.direct) {
          expect(actual, ['direct-arm64.apk']);
        } else if (location == ActionsApkLocation.nested) {
          expect(actual, ['release.ZIP-arm64.apk']);
        } else {
          expect(actual, ['debug.zip-arm64.apk', 'direct-arm64.apk', 'release.ZIP-arm64.apk']);
        }
      } finally {
        await scratch.delete(recursive: true);
      }
    });
  }
}
