/// Packages `build/web` as a zip with the files at the zip root, so it extracts
/// straight into the site folder.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart' show Deflate, getCrc32;
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

/// The zip of every non-excluded file under [webDir], sorted by path, with
/// the files at the zip root.
///
/// The bytes are a pure function of the file names, their content and
/// [modified]: entry times are [modified] in UTC (not the machine's local
/// time), permissions are fixed, entries are sorted and there is no random
/// value. They are also the same whichever major version of `package:archive`
/// (3.6.x or 4.x) the app resolved, because the container is written here and
/// `package:archive` only supplies the two primitives that exist unchanged in
/// both: the pure-Dart `Deflate` (4.x would otherwise switch to the native
/// zlib, which compresses to different bytes) and `getCrc32`.
///
/// A plain (non-zip64) zip: more than 65535 files, or a file or archive of
/// 4 GiB or more, is refused with a message instead of a corrupt zip.
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
  if (entries.length > _zip32MaxEntries) {
    throw BuildException(
      'The web build has ${entries.length} files; a zip holds at most $_zip32MaxEntries. Remove files from build/web.',
    );
  }
  final stamp = modified.toUtc();
  if (stamp.year < 1980 || stamp.year > 2107) {
    throw BuildException(
      'Cannot write a zip dated ${stamp.year}: zip times run from 1980 to 2107. Check the clock.',
    );
  }
  final dosTime =
      (stamp.hour << 11) | (stamp.minute << 5) | (stamp.second ~/ 2);
  final dosDate = ((stamp.year - 1980) << 9) | (stamp.month << 5) | stamp.day;

  final body = BytesBuilder(copy: false);
  final directory = BytesBuilder(copy: false);
  var count = 0;
  for (final relative in entries.keys.toList()..sort()) {
    final content = Uint8List.fromList(fs.readBytes(entries[relative]!));
    final name = utf8.encode(relative);
    final crc = getCrc32(content);
    final List<int> packed = Deflate(
      content,
      level: _deflateBestSpeed,
    ).getBytes();
    if (content.length > _zip32Max || packed.length > _zip32Max) {
      throw BuildException(
        '$relative is ${content.length} bytes; a zip entry holds less than 4 GiB. Remove it from build/web.',
      );
    }
    final offset = body.length;
    if (offset > _zip32Max) {
      throw BuildException(
        'The web build is 4 GiB or more once compressed, which a plain zip cannot hold.',
      );
    }
    // Local file header, then the compressed data.
    _writeLocalHeader(
      body,
      name: name,
      dosTime: dosTime,
      dosDate: dosDate,
      crc: crc,
      compressed: packed.length,
      size: content.length,
    );
    body.add(packed);
    _writeCentralHeader(
      directory,
      name: name,
      dosTime: dosTime,
      dosDate: dosDate,
      crc: crc,
      compressed: packed.length,
      size: content.length,
      offset: offset,
    );
    count++;
  }
  if (body.length + directory.length > _zip32Max) {
    throw BuildException(
      'The web build is 4 GiB or more once compressed, which a plain zip cannot hold.',
    );
  }
  final end = _Le()
    ..u32(0x06054b50)
    ..u16(0) // this disk
    ..u16(0) // disk with the central directory
    ..u16(count)
    ..u16(count)
    ..u32(directory.length)
    ..u32(body.length)
    ..u16(0); // no comment
  final out = BytesBuilder(copy: false)
    ..add(body.takeBytes())
    ..add(directory.takeBytes())
    ..add(end.bytes);
  return out.takeBytes();
}

const int _zip32Max = 0xFFFFFFFF;
const int _zip32MaxEntries = 0xFFFF;

/// `Deflate.BEST_SPEED` (3.x) / `DeflateLevel.bestSpeed` (4.x): the name moved
/// between the major versions, the value did not.
const int _deflateBestSpeed = 1;

/// Version needed to extract and version made by: 2.0, MS-DOS attributes.
const int _zipVersion = 20;

/// General purpose flag bit 11: the names are UTF-8.
const int _zipUtf8 = 0x0800;

/// Method 8: deflate.
const int _zipDeflate = 8;

/// `rw-r--r--` in the high half of the external attributes (what the old
/// `zip` command and `package:archive` both wrote for a regular file).
const int _zipExternalAttributes = 420 << 16;

void _writeLocalHeader(
  BytesBuilder out, {
  required List<int> name,
  required int dosTime,
  required int dosDate,
  required int crc,
  required int compressed,
  required int size,
}) {
  final header = _Le()
    ..u32(0x04034b50)
    ..u16(_zipVersion)
    ..u16(_zipUtf8)
    ..u16(_zipDeflate)
    ..u16(dosTime)
    ..u16(dosDate)
    ..u32(crc)
    ..u32(compressed)
    ..u32(size)
    ..u16(name.length)
    ..u16(0); // no extra field
  out
    ..add(header.bytes)
    ..add(name);
}

void _writeCentralHeader(
  BytesBuilder out, {
  required List<int> name,
  required int dosTime,
  required int dosDate,
  required int crc,
  required int compressed,
  required int size,
  required int offset,
}) {
  final header = _Le()
    ..u32(0x02014b50)
    ..u16(_zipVersion) // made by: MS-DOS (0) << 8 | 2.0
    ..u16(_zipVersion)
    ..u16(_zipUtf8)
    ..u16(_zipDeflate)
    ..u16(dosTime)
    ..u16(dosDate)
    ..u32(crc)
    ..u32(compressed)
    ..u32(size)
    ..u16(name.length)
    ..u16(0) // no extra field
    ..u16(0) // no comment
    ..u16(0) // disk number
    ..u16(0) // internal attributes
    ..u32(_zipExternalAttributes)
    ..u32(offset);
  out
    ..add(header.bytes)
    ..add(name);
}

/// Little-endian integer writer for the zip records.
class _Le {
  final BytesBuilder _out = BytesBuilder(copy: false);

  Uint8List get bytes => _out.toBytes();

  void u16(int value) => _out.add([value & 0xff, (value >> 8) & 0xff]);

  void u32(int value) => _out.add([
    value & 0xff,
    (value >> 8) & 0xff,
    (value >> 16) & 0xff,
    (value >> 24) & 0xff,
  ]);
}

/// The `<base href>` of web/index.html, as written there: a hardcoded path
/// (`/web_admin/`), or [flutterBaseHrefPlaceholder] when the file is the
/// template `flutter create` writes (see [servedBaseHref] for what that
/// means). Lines containing `<!--` are skipped, like the old build_web.sh
/// did, so a commented-out `<base>` is not taken.
String? parseBaseHref(String indexHtml) {
  for (final line in indexHtml.split('\n')) {
    if (line.contains('<!--')) continue;
    final match = RegExp(r'<base href="([^"]*)"').firstMatch(line);
    if (match != null) return match.group(1);
  }
  return null;
}

/// What `flutter create` puts in `<base href>`: Flutter replaces it with the
/// `--base-href` of the build.
const String flutterBaseHrefPlaceholder = r'$FLUTTER_BASE_HREF';

/// The path the built site is served at, for the profile and the deploy
/// hint: [href] (from [parseBaseHref]) as it is, except the template
/// placeholder, which Flutter fills with `/` because this tool passes no
/// `--base-href`.
String? servedBaseHref(String? href) =>
    href == flutterBaseHrefPlaceholder ? '/' : href;
