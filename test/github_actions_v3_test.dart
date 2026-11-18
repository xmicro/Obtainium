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

  test('APK matches use basename, never parent ZIP names', () {
    expect(actionsApkMatches('sign', 'signed.zip-contents/app.apk'), isFalse);
    expect(actionsApkMatches('app', 'signed.zip-contents/app.apk'), isTrue);
    expect(actionsApkMatches('sign', 'unsigned.zip-contents/sign.apk'), isTrue);
    expect(actionsApkMatches('sign', 'signed.zip-contents/readme.txt'), isFalse);
    expect(actionsApkMatches('arm64', 'signed.zip-contents/app-arm64.apkm'), isTrue);
    expect(actionsPreviewFileIsSelected('signed.zip-contents/base.apks',
        'signed', 'base'), isTrue);
  });

  test('first filename field selects an inner ZIP, never upload metadata', () {
    // GitHub calls the upload "artifact"; the user's text is about files.
    expect(actionsArtifactNameMatches('artifact', 'artifact'), isTrue);
    expect(actionsPreviewFileIsSelected('signed-build.zip', 'sign', ''), isTrue);
    expect(actionsPreviewFileIsSelected(
        'signed-build.zip-contents/app.apk', 'sign', ''), isTrue);
    expect(actionsPreviewFileIsSelected('other-build.zip', 'sign', ''), isFalse);
    expect(actionsPreviewFileIsSelected(
        'signed-build.zip-contents/app.apk', 'sign', 'arm64'), isFalse);
    expect(actionsPreviewFileIsSelected(
        'signed-build.zip-contents/arm64.apk', 'sign', 'arm64'), isTrue);
  });

  test('ZIP inspection lists inner APKs without extracting APK payloads', () async {
    final scratch = await Directory.systemTemp.createTemp('actions-v3-index-');
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
      expect(listed, contains('signed-release.zip'));
      expect(listed, contains('signed-release.zip-contents/arm64.apk'));
      expect(listed, contains('signed-release.zip-contents/nested-again.zip'));
      expect(listed, contains('direct.apk'));
      expect(File('${scratch.path}/arm64.apk').existsSync(), isFalse);
      expect(actionsPreviewFileIsSelected(
          'signed-release.zip-contents/arm64.apk', 'signed-', 'arm64'), isTrue);
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

  test('only one nested ZIP level is extracted and only matching names', () async {
    final root = await Directory.systemTemp.createTemp('actions-v3-test-');
    try {
      await File('${root.path}/signed-release.zip').writeAsBytes([]);
      await File('${root.path}/other.zip').writeAsBytes([]);
      await File('${root.path}/ignored.apk').writeAsBytes([]);
      final expanded = <String>[];
      Future<void> fakeExtract(File source, Directory target) async {
        expanded.add(source.uri.pathSegments.last);
        await target.create(recursive: true);
        await File('${target.path}/app-arm64.apk').writeAsBytes([]);
        await File('${target.path}/another.zip').writeAsBytes([]);
      }
      await prepareActionsArchive(root,
        filenamePattern: 'signed-release', extract: fakeExtract);
      expect(expanded, ['signed-release.zip']);
      expect(File('${root.path}/ignored.apk').existsSync(), isFalse);
      expect(File('${root.path}/signed-release.zip-contents/app-arm64.apk')
          .existsSync(), isTrue);
      expect(Directory('${root.path}/another.zip-contents').existsSync(), isFalse);
    } finally {
      await root.delete(recursive: true);
    }
  });

  test('preview retains nonmatches and expands available nested ZIPs', () async {
    final root = await Directory.systemTemp.createTemp('actions-v3-preview-');
    try {
      await File('${root.path}/signed.zip').writeAsBytes([]);
      await File('${root.path}/unsigned.zip').writeAsBytes([]);
      await File('${root.path}/other.apk').writeAsBytes([]);
      await prepareActionsArchive(root,
        filenamePattern: 'signed.zip', preview: true,
        extract: (zip, target) async {
          await target.create(recursive: true);
          await File('${target.path}/app.apk').writeAsBytes([]);
        });
      final files = actionsArchiveFilePaths(root);
      expect(files, contains('other.apk'));
      expect(files, contains('signed.zip-contents/app.apk'));
      expect(files, contains('unsigned.zip-contents/app.apk'));
    } finally {
      await root.delete(recursive: true);
    }
  });
}
