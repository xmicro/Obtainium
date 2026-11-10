import 'dart:io';

import 'package:flutter_archive/flutter_archive.dart';

List<File> findNestedActionZips(Directory directory) => directory
    .listSync(recursive: true, followLinks: false)
    .whereType<File>()
    .where((file) => file.path.toLowerCase().endsWith('.zip'))
    .toList();

Future<void> extractOneNestedActionZipLevel(
  Directory directory, {
  Future<void> Function(File, Directory)? extract,
}) async {
  final zipFiles = findNestedActionZips(directory);
  for (final file in zipFiles) {
    final destination = Directory('${file.path}-contents');
    if (extract != null) {
      await extract(file, destination);
    } else {
      await ZipFile.extractToDirectory(
        zipFile: file,
        destinationDir: destination,
      );
    }
  }
}

List<String> actionArchiveFilePaths(Directory directory) => directory
    .listSync(recursive: true, followLinks: false)
    .whereType<File>()
    .map((file) => file.path.substring(directory.path.length + 1))
    .toList()..sort();
