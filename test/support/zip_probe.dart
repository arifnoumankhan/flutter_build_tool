// Prints the sha256 of the golden web zip. The web zip test starts this as a
// process with TZ set, because a time zone cannot be changed inside a running
// Dart process: it proves the bytes do not depend on the machine's zone.
import 'package:path/path.dart' as p;

import 'package:flutter_build_tools/src/sha256.dart';
import 'package:flutter_build_tools/src/web_zip.dart';
import 'web_zip_fixture.dart';

void main() {
  // The same instant as a local DateTime, whatever TZ this process runs in.
  final local = DateTime.fromMillisecondsSinceEpoch(
    webZipMoment.millisecondsSinceEpoch,
  );
  final bytes = buildWebZip(
    fs: webZipFixture(),
    path: p.Context(style: p.Style.posix),
    webDir: '/repo/build/web',
    modified: local,
  );
  print(Sha256.hex(bytes));
}
