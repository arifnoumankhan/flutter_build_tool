import 'package:archive/archive.dart';
import 'package:test/test.dart';
import 'package:path/path.dart' as p;

import 'package:flutter_build_tools/src/model.dart';
import 'package:flutter_build_tools/src/web_zip.dart';
import 'fakes.dart';

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
  });
}
