// The real file system and process seams, against a temporary folder. The rest
// of the suite uses fakes; this proves the real implementations behave the
// same way and that the checksum and zip files are accepted by the OS tools.
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'package:flutter_build_tools/src/cli.dart';
import 'package:flutter_build_tools/src/environment.dart';
import 'package:flutter_build_tools/src/fs.dart';
import 'package:flutter_build_tools/src/model.dart';
import 'package:flutter_build_tools/src/runner.dart';
import 'fakes.dart';

void main() {
  late Directory temp;
  setUp(() => temp = Directory.systemTemp.createTempSync('build_tool_test_'));
  tearDown(() => temp.deleteSync(recursive: true));

  String at(String relative) =>
      '${temp.path}${Platform.pathSeparator}${relative.replaceAll('/', Platform.pathSeparator)}';

  group('IoFs', () {
    const fs = IoFs();

    test(
      'writes create parent folders; reads, length and streaming agree',
      () async {
        fs.writeString(at('a/b/c.txt'), 'hello');
        fs.writeBytes(at('a/b/d.bin'), [0, 1, 2, 255]);
        expect(fs.fileExists(at('a/b/c.txt')), isTrue);
        expect(fs.dirExists(at('a/b')), isTrue);
        expect(fs.readString(at('a/b/c.txt')), 'hello');
        expect(fs.readBytes(at('a/b/d.bin')), [0, 1, 2, 255]);
        expect(fs.length(at('a/b/d.bin')), 4);
        final chunks = await fs.openRead(at('a/b/d.bin')).toList();
        expect([for (final chunk in chunks) ...chunk], [0, 1, 2, 255]);
      },
    );

    test(
      'listFiles: files only, recursive or not, empty for a missing folder',
      () {
        fs.writeString(at('top.txt'), '1');
        fs.writeString(at('sub/deep.txt'), '2');
        expect(
          fs
              .listFiles(temp.path)
              .map((f) => f.split(Platform.pathSeparator).last),
          ['top.txt'],
        );
        expect(
          fs
              .listFiles(temp.path, recursive: true)
              .map((f) => f.split(Platform.pathSeparator).last)
              .toSet(),
          {'top.txt', 'deep.txt'},
        );
        expect(fs.listFiles(at('missing')), isEmpty);
      },
    );

    test('findFile: case-insensitive, recursive, null when absent', () {
      fs.writeString(at('Programs/Inno Setup 6/ISCC.exe'), 'x');
      expect(
        fs.findFile(temp.path, 'iscc.exe'),
        at('Programs/Inno Setup 6/ISCC.exe'),
      );
      expect(fs.findFile(temp.path, 'nothing.exe'), isNull);
      expect(fs.findFile(at('missing'), 'ISCC.exe'), isNull);
    });

    test('copy, delete, createDir, createTempDir', () {
      fs.writeString(at('src.txt'), 'data');
      fs.copyFile(at('src.txt'), at('out/dst.txt'));
      expect(fs.readString(at('out/dst.txt')), 'data');
      fs.deleteFile(at('out/dst.txt'));
      fs.deleteFile(at('out/dst.txt')); // already gone: no error
      expect(fs.fileExists(at('out/dst.txt')), isFalse);
      fs.createDir(at('x/y/z'));
      expect(fs.dirExists(at('x/y/z')), isTrue);
      fs.deleteDir(at('x'));
      fs.deleteDir(at('x')); // already gone: no error
      expect(fs.dirExists(at('x')), isFalse);
      final tempDir = fs.createTempDir('build_tool_inner_');
      expect(fs.dirExists(tempDir), isTrue);
      fs.deleteDir(tempDir);
    });
  });

  group('IoProcessRunner', () {
    const runner = IoProcessRunner();
    final shell = Platform.isWindows ? 'cmd' : 'sh';
    List<String> script(String command) =>
        Platform.isWindows ? ['/c', command] : ['-c', command];

    test('capture returns exit code and output', () async {
      final result = await runner.capture(
        ProcessSpec(shell, script('echo hi')),
      );
      expect(result.exitCode, 0);
      expect(result.stdout.trim(), 'hi');
    });

    test('stream returns the exit code', () async {
      expect(await runner.stream(ProcessSpec(shell, script('exit 3'))), 3);
    });

    test(
      'a missing executable is a ProcessStartException, not a crash',
      () async {
        const missing = ProcessSpec('definitely-not-an-installed-program', []);
        await expectLater(
          runner.capture(missing),
          throwsA(isA<ProcessStartException>()),
        );
        await expectLater(
          runner.stream(missing),
          throwsA(isA<ProcessStartException>()),
        );
      },
    );
  });

  test(
    'a whole web build on the real file system: zip, checksum and manifest accepted by the OS tools',
    () async {
      final runner = FakeRunner()..scriptDefaults();
      runner.onStream((s) => s.executable == 'flutter' && s.args[1] == 'web', (
        s,
      ) {
        const fs = IoFs();
        fs.writeString(at('build/web/index.html'), '<html>');
        fs.writeString(at('build/web/assets/a.json'), '{}');
        fs.writeString(at('build/web/.DS_Store'), 'x');
        // The define file exists while flutter runs, with the profile inside.
        expect(
          File(at('build/build_tool/defines-web-dev.json')).readAsStringSync(),
          contains('"APP_ENV": "dev"'),
        );
        return 0;
      });
      const fs = IoFs();
      final world = TestWorld();
      fs.writeString(at('pubspec.yaml'), 'name: x\nversion: 1.0.47+47\n');
      fs.writeString(
        at('tool/build/build_config.json'),
        jsonEncode(exampleAppConfig),
      );
      fs.writeString(
        at('config/env/dev.json'),
        '{"APP_ENV": "dev", "BASE_URL": "https://dev.example.com/public"}',
      );
      fs.writeString(at('web/index.html'), '<base href="/web_admin/">');
      final console = FakeConsole();
      final env = BuildEnvironment(
        root: temp.path,
        host: HostOs.fromDartName(Platform.operatingSystem),
        vars: const {},
        fs: fs,
        runner: runner,
        console: console,
        now: world.env.now,
      );

      expect(
        await runBuildTool(['web', 'dev'], env),
        0,
        reason: console.allText,
      );

      final name = '${exampleAppConfig['slug']}-dev-v1.0.47.zip';
      final dist = at('dist/web');
      final zip = '$dist${Platform.pathSeparator}$name';
      expect(File(zip).existsSync(), isTrue);
      expect(File('$zip.sha256').readAsStringSync(), endsWith('  $name\n'));
      expect(File('$zip.json').existsSync(), isTrue);
      expect(
        File(at('build/build_tool/defines-web-dev.json')).existsSync(),
        isFalse,
      );

      // The OS tools agree (skipped where they are not installed, e.g. Windows).
      for (final (tool, args) in [
        ('shasum', ['-a', '256', '-c', '$name.sha256']),
        ('unzip', ['-tq', name]),
      ]) {
        try {
          final result = await Process.run(tool, args, workingDirectory: dist);
          expect(
            result.exitCode,
            0,
            reason: '$tool ${args.join(' ')}: ${result.stdout}${result.stderr}',
          );
        } on ProcessException {
          markTestSkipped('$tool is not installed');
        }
      }
    },
  );
}
