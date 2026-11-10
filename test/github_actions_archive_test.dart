import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:obtainium/services/github_actions_archive_service.dart';

void main() {
  test('extracts exactly one nested ZIP level and lists its APKs', () async {
    final root = await Directory.systemTemp.createTemp('actions-archive-test-');
    try {
      final zip = File('${root.path}/release.zip');
      await zip.writeAsBytes([1, 2, 3]);
      await extractOneNestedActionZipLevel(
        root,
        extract: (file, destination) async {
          await destination.create(recursive: true);
          await File('${destination.path}/base.apk').writeAsBytes([4, 5]);
          await File('${destination.path}/untouched.zip').writeAsBytes([6]);
        },
      );
      final paths = actionArchiveFilePaths(root);
      expect(paths, contains('release.zip-contents/base.apk'));
      expect(paths, contains('release.zip-contents/untouched.zip'));
      expect(paths, isNot(contains(
          'release.zip-contents/untouched.zip-contents/base.apk')));
    } finally {
      await root.delete(recursive: true);
    }
  });
}
