/// Packages `build/web` as a zip with the files at the zip root, so it extracts
/// straight into the site folder.
library;

import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;

import 'package:flutter_build_tools/src/fs.dart';
import 'package:flutter_build_tools/src/model.dart';

/// Same exclusions as the old `zip -x '*.DS_Store' '__MACOSX/*' '.last_build_id'
/// '*.zip'`: macOS litter, Flutter's build marker, and stray hand-made archives
/// left inside build/web. [relativePath] uses '/' separators.
bool isExcludedFromWebZip(String relativePath) =>
    relativePath.endsWith('.DS_Store') ||
    relativePath.startsWith('__MACOSX/') ||
    relativePath == '.last_build_id' ||
    relativePath.endsWith('.zip');

/// Zip bytes of every non-excluded file under [webDir], sorted by path.
List<int> buildWebZip({
  required BuildFs fs,
  required p.Context path,
  required String webDir,
  required DateTime modified,
}) {
  final entries = <String, String>{
    for (final file in fs.listFiles(webDir, recursive: true))
      path.split(path.relative(file, from: webDir)).join('/'): file,
  }..removeWhere((relative, _) => isExcludedFromWebZip(relative));
  if (entries.isEmpty) {
    throw BuildException(
      'Nothing to zip under $webDir. Run without --no-build.',
    );
  }
  final archive = Archive();
  final seconds = modified.toUtc().millisecondsSinceEpoch ~/ 1000;
  for (final relative in entries.keys.toList()..sort()) {
    final bytes = Uint8List.fromList(fs.readBytes(entries[relative]!));
    archive.addFile(
      ArchiveFile(relative, bytes.length, bytes)..lastModTime = seconds,
    );
  }
  final encoded = ZipEncoder().encode(archive);
  if (encoded == null) {
    throw BuildException('Could not create the zip for $webDir.');
  }
  return encoded;
}

/// The `<base href>` that web/index.html hardcodes (`$FLUTTER_BASE_HREF` is
/// commented out there, so `flutter build web --base-href` has no effect).
/// Lines containing `<!--` are skipped, like the old build_web.sh did.
String? parseBaseHref(String indexHtml) {
  for (final line in indexHtml.split('\n')) {
    if (line.contains('<!--')) continue;
    final match = RegExp(r'<base href="([^"]*)"').firstMatch(line);
    if (match != null) return match.group(1);
  }
  return null;
}
