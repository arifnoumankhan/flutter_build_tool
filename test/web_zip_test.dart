import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:test/test.dart';
import 'package:path/path.dart' as p;

import 'package:flutter_build_tools/src/model.dart';
import 'package:flutter_build_tools/src/sha256.dart';
import 'package:flutter_build_tools/src/web_zip.dart';
import 'fakes.dart';
import 'support/web_zip_fixture.dart';

void main() {
  group('isExcludedFromWebZip (the old zip -x patterns)', () {
    const excluded = [
      '.DS_Store',
      'assets/.DS_Store',
      'icons/foo.DS_Store',
      '__MACOSX/index.html',
      '__MACOSX/._main.dart.js',
      '.last_build_id',
      'old.zip',
      'sub/backup.zip',
    ];
    const kept = [
      'index.html',
      'main.dart.js',
      'assets/AssetManifest.json',
      'canvaskit/canvaskit.wasm',
      'assets/zip_icon.png',
      'sub/.last_build_id',
      'x__MACOSX/a',
    ];
    for (final path in excluded) {
      test('excludes $path', () => expect(isExcludedFromWebZip(path), isTrue));
    }
    for (final path in kept) {
      test('keeps $path', () => expect(isExcludedFromWebZip(path), isFalse));
    }
  });

  group('buildWebZip', () {
    final posix = p.Context(style: p.Style.posix);

    List<int> zipOf(MemoryFs fs) => buildWebZip(
      fs: fs,
      path: posix,
      webDir: '/repo/build/web',
      modified: DateTime.utc(2026, 10, 6, 12),
    );

    test(
      'files sit at the zip root, litter is excluded, content is intact',
      () {
        final fs = MemoryFs()
          ..put('/repo/build/web/index.html', '<html>')
          ..put('/repo/build/web/main.dart.js', 'console.log(1)')
          ..put('/repo/build/web/assets/AssetManifest.json', '{}')
          ..put('/repo/build/web/assets/fonts/Inter.ttf', [0, 1, 2, 255])
          ..put('/repo/build/web/.DS_Store', 'x')
          ..put('/repo/build/web/.last_build_id', 'abc')
          ..put('/repo/build/web/__MACOSX/._index.html', 'x')
          ..put('/repo/build/web/hand_made_backup.zip', 'x')
          ..put('/repo/build/other/ignored.txt', 'x');
        final archive = ZipDecoder().decodeBytes(zipOf(fs));
        expect(archive.files.map((f) => f.name).toList(), [
          'assets/AssetManifest.json',
          'assets/fonts/Inter.ttf',
          'index.html',
          'main.dart.js',
        ], reason: 'sorted, relative, no excluded files');
        expect(
          String.fromCharCodes(
            archive.findFile('index.html')!.content as List<int>,
          ),
          '<html>',
        );
        expect(archive.findFile('assets/fonts/Inter.ttf')!.content, [
          0,
          1,
          2,
          255,
        ]);
        expect(
          archive.files.every(
            (f) => !f.name.startsWith('/') && !f.name.contains('build/web'),
          ),
          isTrue,
        );
      },
    );

    test('an empty build folder is an error, not an empty zip', () {
      final fs = MemoryFs()..put('/repo/build/web/.DS_Store', 'x');
      expect(
        () => zipOf(fs),
        throwsA(
          isA<BuildException>().having(
            (e) => e.message,
            'message',
            contains('Nothing to zip'),
          ),
        ),
      );
    });

    test('Windows-style separators still give forward-slash entry names', () {
      final fs = MemoryFs(separator: r'\')
        ..put(r'C:\repo\build\web\index.html', 'x')
        ..put(r'C:\repo\build\web\assets\a.json', '{}');
      final bytes = buildWebZip(
        fs: fs,
        path: p.Context(style: p.Style.windows),
        webDir: r'C:\repo\build\web',
        modified: DateTime.utc(2026),
      );
      expect(ZipDecoder().decodeBytes(bytes).files.map((f) => f.name), [
        'assets/a.json',
        'index.html',
      ]);
    });
  });

  // The zip is written by this package (archive only supplies Deflate and
  // CRC-32), so its bytes are the same whichever archive major version the app
  // resolved: 3.6.x compressed with its own Deflate, 4.x would have used the
  // native zlib. These tests run unchanged against both (see the README).
  group('the zip bytes', () {
    final posix = p.Context(style: p.Style.posix);
    final moment = webZipMoment;

    MemoryFs fixture({bool reversed = false}) =>
        webZipFixture(reversed: reversed);

    List<int> zip(MemoryFs fs, {DateTime? modified}) => buildWebZip(
      fs: fs,
      path: posix,
      webDir: '/repo/build/web',
      modified: modified ?? moment,
    );

    test('are those of 0.1.0 on archive 3.6.x, and of archive 4.x', () {
      expect(Sha256.hex(zip(fixture())), webZipGolden);
    });

    test('do not depend on the order the files were created in', () {
      expect(zip(fixture(reversed: true)), zip(fixture()));
    });

    test('do not depend on the time zone of the machine', () {
      // The same instant, once as UTC and once as the machine's local time:
      // the entry times are the UTC fields in both.
      final local = DateTime.fromMillisecondsSinceEpoch(
        moment.millisecondsSinceEpoch,
      );
      expect(zip(fixture(), modified: local), zip(fixture()));
      final shifted = DateTime.parse('2026-10-06T17:34:56+05:00');
      expect(shifted.isAtSameMomentAs(moment), isTrue);
      expect(zip(fixture(), modified: shifted), zip(fixture()));
    });

    for (final zone in ['UTC', 'Asia/Karachi', 'America/Los_Angeles']) {
      test(
        'are the golden ones in a process running in $zone',
        skip: Platform.isWindows ? 'TZ is not honoured on Windows' : null,
        () async {
          final result = await Process.run(
            Platform.resolvedExecutable,
            ['run', p.join('test', 'support', 'zip_probe.dart')],
            workingDirectory: Directory.current.path,
            environment: {'TZ': zone},
          );
          expect(result.exitCode, 0, reason: '${result.stderr}');
          expect((result.stdout as String).trim(), webZipGolden);
        },
      );
    }

    test('change with the time, and only in the time fields', () {
      final a = zip(fixture());
      final b = zip(
        fixture(),
        modified: moment.add(const Duration(minutes: 1)),
      );
      expect(b.length, a.length);
      expect(b, isNot(a));
    });

    test('carry the DOS time of the UTC build time', () {
      final bytes = zip(fixture());
      final header = ByteData.sublistView(Uint8List.fromList(bytes));
      expect(header.getUint32(0, Endian.little), 0x04034b50);
      final time = header.getUint16(10, Endian.little);
      final date = header.getUint16(12, Endian.little);
      expect([time >> 11, (time >> 5) & 63, (time & 31) * 2], [12, 34, 56]);
      expect([(date >> 9) + 1980, (date >> 5) & 15, date & 31], [2026, 10, 6]);
    });

    test('are a valid zip: decoder with CRC checks, names, content, order', () {
      final bytes = zip(fixture());
      final archive = ZipDecoder().decodeBytes(bytes, verify: true);
      expect(archive.files.map((f) => f.name).toList(), [
        'assets/AssetManifest.json',
        'assets/fonts/Inter.ttf',
        'assets/\u65e5\u672c.txt',
        'big.txt',
        'empty.txt',
        'index.html',
        'main.dart.js',
      ]);
      expect(
        utf8.decode(archive.findFile('big.txt')!.content as List<int>),
        'The quick brown fox jumps over the lazy dog\n' * 500,
      );
      expect(archive.findFile('empty.txt')!.size, 0);
      expect(archive.findFile('assets/fonts/Inter.ttf')!.content, [
        0,
        1,
        2,
        255,
      ]);
      // Compressible content really is deflated.
      expect(bytes.length, lessThan(22000));
    });

    test('end with a central directory that counts every entry', () {
      final bytes = zip(fixture());
      final end = ByteData.sublistView(Uint8List.fromList(bytes));
      final eocd = bytes.length - 22;
      expect(end.getUint32(eocd, Endian.little), 0x06054b50);
      expect(end.getUint16(eocd + 8, Endian.little), 7);
      expect(end.getUint16(eocd + 10, Endian.little), 7);
      final directoryOffset = end.getUint32(eocd + 16, Endian.little);
      expect(end.getUint32(directoryOffset, Endian.little), 0x02014b50);
    });

    test('refuse more entries than a plain zip can hold', () {
      final fs = MemoryFs();
      for (var i = 0; i < 65536; i++) {
        fs.files['/repo/build/web/f$i'] = const [1];
      }
      expect(
        () => zip(fs),
        throwsA(
          isA<BuildException>().having(
            (e) => e.message,
            'message',
            contains('a zip holds at most 65535'),
          ),
        ),
      );
    });

    test('refuse a clock that a zip cannot write', () {
      expect(
        () => zip(fixture(), modified: DateTime.utc(1979, 12, 31)),
        throwsA(
          isA<BuildException>().having(
            (e) => e.message,
            'message',
            contains('zip times run from 1980 to 2107'),
          ),
        ),
      );
    });
  });

  group('parseBaseHref', () {
    test('reads the hardcoded base href and skips the commented placeholder', () {
      const html =
          '<head>\n<!--  <base href="\$FLUTTER_BASE_HREF">-->\n  <base href="/web_admin/">\n</head>';
      expect(parseBaseHref(html), '/web_admin/');
    });

    test('root site', () => expect(parseBaseHref('<base href="/">'), '/'));

    test(
      'none',
      () => expect(
        parseBaseHref('<!-- <base href="/x/"> -->\n<title>x</title>'),
        isNull,
      ),
    );

    test('the file flutter create writes holds the placeholder', () {
      expect(parseBaseHref(stockIndexHtml), r'$FLUTTER_BASE_HREF');
      expect(parseBaseHref(stockIndexHtml), flutterBaseHrefPlaceholder);
    });
  });

  group('servedBaseHref', () {
    test(
      'the template placeholder is served at / (no --base-href is passed)',
      () {
        expect(servedBaseHref(parseBaseHref(stockIndexHtml)), '/');
      },
    );

    test('a path the project hardcodes is shown as it is', () {
      expect(servedBaseHref('/web_admin/'), '/web_admin/');
      expect(servedBaseHref('/'), '/');
      expect(servedBaseHref('./'), './');
    });

    test('no <base> stays null, so the caller says so', () {
      expect(servedBaseHref(null), isNull);
    });
  });
}
