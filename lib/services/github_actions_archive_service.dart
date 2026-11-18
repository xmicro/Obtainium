import 'dart:io';

import 'package:archive/archive.dart' hide ZipFile;
import 'package:flutter_archive/flutter_archive.dart';
import 'package:obtainium/app_sources/github_actions.dart';

/// Apply the same first-level file selection in preview and installation.
/// [filenamePattern] matches file BASENAMES inside the Actions upload, never
/// the GitHub artifact upload name and never a parent directory name.
/// Only one nested ZIP layer is supported.
Future<void> prepareActionsArchive(
  Directory contents, {
  required String filenamePattern,
  bool preview = false,
  Future<void> Function(File, Directory)? extract,
}) async {
  // Snapshot BEFORE extracting nested ZIPs to prevent recursive extraction.
  final files = contents.listSync(recursive: true, followLinks: false)
      .whereType<File>().toList();
  for (final file in files) {
    final basename = file.uri.pathSegments.last;
    final selected = actionsFileMatches(filenamePattern, basename);
    final lower = basename.toLowerCase();
    if (actionsIsInstallableFile(basename)) {
      // Preview keeps rejected APKs visible in red. Installation must remove
      // them, or Obtainium's normal discovery would install them anyway.
      if (!selected && !preview) await file.delete();
    } else if (lower.endsWith('.zip') && (selected || preview)) {
      final destination = Directory('${file.path}-contents');
      if (extract != null) {
        await extract(file, destination);
      } else {
        await ZipFile.extractToDirectory(
          zipFile: file, destinationDir: destination);
      }
    }
  }
}

const _actionsInstallableExtensions = <String>{
  '.apk', '.xapk', '.apkm', '.apks',
};

bool actionsIsInstallableFile(String name) => _actionsInstallableExtensions
    .any(name.toLowerCase().endsWith);

/// The full paths are for display; match only individual file basenames.
List<String> actionsArchiveFilePaths(Directory contents) => contents
    .listSync(recursive: true, followLinks: false)
    .whereType<File>()
    .map((file) => file.path.substring(contents.path.length + 1))
    .toList()..sort();

/// Returns true for APKs extracted from a matching inner ZIP, or selected
/// directly from the outer artifact. A parent ZIP's name must not cause an
/// unrelated APK to match the APK filename filter.
bool actionsApkMatches(String pattern, String relativePath) =>
    actionsIsInstallableFile(relativePath) &&
    actionsFileMatches(pattern, Uri.file(relativePath).pathSegments.last);

/// Preview selection mirrors [prepareActionsArchive] plus the APK filename
/// filter applied by Obtainium's installer after extraction.
bool actionsPreviewFileIsSelected(
    String relativePath, String filePattern, String apkPattern) {
  final path = relativePath.replaceAll('\\', '/');
  final basename = path.split('/').last;
  final lower = basename.toLowerCase();
  final nestedIndex = path.indexOf('.zip-contents/');
  if (lower.endsWith('.zip')) {
    // ZIPs inside a nested ZIP are deliberately not expanded further.
    return nestedIndex < 0 && actionsFileMatches(filePattern, basename);
  }
  if (!actionsIsInstallableFile(basename)) return false;
  if (!actionsFileMatches(apkPattern, basename)) return false;
  if (nestedIndex >= 0) {
    final parentZip = path.substring(0, nestedIndex + 4).split('/').last;
    return actionsFileMatches(filePattern, parentZip);
  }
  return actionsFileMatches(filePattern, basename);
}

/// Inspects ZIP directory entries without extracting APK payloads. For each
/// nested ZIP, only that nested ZIP is streamed to a temporary file so its
/// filename index can be read. APK bytes are never unpacked during setup.
Future<List<String>> inspectActionsArtifact(
    File outerZip, Directory scratchDirectory) async {
  final entries = <String>[];
  final input = InputFileStream(outerZip.path);
  try {
    final archive = ZipDecoder().decodeStream(input);
    var zipNumber = 0;
    for (final entry in archive) {
      if (!entry.isFile || entry.isSymbolicLink) continue;
      final name = entry.name.replaceAll('\\', '/');
      entries.add(name);
      if (!name.toLowerCase().endsWith('.zip')) continue;
      final nestedZip = File('${scratchDirectory.path}/nested-${zipNumber++}.zip');
      final output = OutputFileStream(nestedZip.path);
      try {
        // Streams this nested ZIP to disk; no large readBytes()/bodyBytes.
        entry.writeContent(output);
      } finally {
        output.closeSync();
      }
      final nestedInput = InputFileStream(nestedZip.path);
      try {
        final innerArchive = ZipDecoder().decodeStream(nestedInput);
        for (final inside in innerArchive) {
          if (!inside.isFile || inside.isSymbolicLink) continue;
          entries.add('$name-contents/${inside.name.replaceAll('\\', '/')}');
        }
      } finally {
        nestedInput.closeSync();
        await nestedZip.delete();
      }
    }
  } finally {
    input.closeSync();
  }
  return entries..sort();
}
