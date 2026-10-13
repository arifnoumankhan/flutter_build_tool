// The process entry: which command the messages show, and what happens when
// the working folder is not a Flutter project.
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'package:flutter_build_tools/src/entry.dart';
import 'package:flutter_build_tools/src/options.dart';
import 'fakes.dart';

void main() {
  group('invocationFor', () {
    test('a shim inside the project is shown relative to it', () {
      expect(
        invocationFor(
          root: '/work/app',
          script: '/work/app/tool/build/build.dart',
        ),
        'dart run tool/build/build.dart',
      );
      expect(
        invocationFor(root: '/work/app', script: '/work/app/build.dart'),
        'dart run build.dart',
      );
    });

    test('the snapshot of `dart run flutter_build_tools` is not a command', () {
      expect(
        invocationFor(
          root: '/work/app',
          script:
              '/work/app/.dart_tool/pub/bin/flutter_build_tools/flutter_build_tools.dart-3.13.0.snapshot',
        ),
        BuildToolOptions.defaultInvocation,
      );
      expect(
        invocationFor(
          root: '/work/app',
          script: '/work/app/.dart_tool/pub/bin/flutter_build_tools/x.dart',
        ),
        BuildToolOptions.defaultInvocation,
        reason: 'anything under .dart_tool is generated',
      );
    });

    test('a script outside the project falls back to the package command', () {
      expect(
        invocationFor(
          root: '/work/app',
          script: '/home/me/.pub-cache/hosted/pub.dev/x/bin/y.dart',
        ),
        'dart run flutter_build_tools',
      );
      expect(
        invocationFor(root: '/work/app', script: '/work/app2/tool/b.dart'),
        'dart run flutter_build_tools',
        reason: 'a sibling folder with the same prefix is not inside',
      );
    });

    test('no script or a non-Dart file falls back too', () {
      expect(
        invocationFor(root: '/work/app', script: null),
        'dart run flutter_build_tools',
      );
      expect(
        invocationFor(root: '/work/app', script: '/work/app/tool/build.exe'),
        'dart run flutter_build_tools',
      );
    });
  });

  group('runBuildToolCli', () {
    test(
      'a folder without pubspec.yaml is a usage-style error (exit 2)',
      () async {
        final world = TestWorld()..fs.deleteFile('/repo/pubspec.yaml');
        expect(
          await runBuildToolCli(
            ['--list'],
            projectRoot: '/repo',
            environment: world.env,
          ),
          2,
        );
        expect(
          world.console.stderrText,
          'error: expected pubspec.yaml at /repo; run this tool from the Flutter project (dart run flutter_build_tools ...).',
        );
        expect(world.console.stdoutText, isEmpty);
        expect(world.runner.calls, isEmpty);
      },
    );

    test('the error shows the invocation it was given', () async {
      final world = TestWorld()..fs.deleteFile('/repo/pubspec.yaml');
      await runBuildToolCli(
        [],
        projectRoot: '/repo',
        options: const BuildToolOptions(
          invocation: 'dart run tool/build/build.dart',
        ),
        environment: world.env,
      );
      expect(
        world.console.stderrText,
        contains('(dart run tool/build/build.dart ...)'),
      );
    });

    test('a project runs the tool and returns its exit code', () async {
      final world = TestWorld();
      expect(
        await runBuildToolCli(
          ['--list'],
          projectRoot: '/repo',
          environment: world.env,
        ),
        0,
      );
      expect(world.console.stdoutText, contains('Example App (ExampleApp)'));

      final bad = TestWorld();
      expect(
        await runBuildToolCli(
          ['apk', 'staging'],
          projectRoot: '/repo',
          environment: bad.env,
        ),
        2,
      );
    });

    test('the options reach the messages of the tool', () async {
      final world = TestWorld();
      await runBuildToolCli(
        ['apk', 'staging'],
        projectRoot: '/repo',
        options: const BuildToolOptions(invocation: 'make build'),
        environment: world.env,
      );
      expect(
        world.console.stderrText,
        contains('Example: make build apk release preprod'),
      );
    });

    test(
      'without options the script of this test is not inside the project',
      () async {
        // The test runner is not a script of /repo, so the package default shows.
        final world = TestWorld();
        await runBuildToolCli(
          ['apk', 'staging'],
          projectRoot: '/repo',
          environment: world.env,
        );
        expect(
          world.console.stderrText,
          contains('Example: dart run flutter_build_tools apk release preprod'),
        );
      },
    );
  });

  group('findProjectRoot', () {
    final posix = p.Context(style: p.Style.posix);

    test('is the folder itself when it has a pubspec.yaml', () {
      final fs = MemoryFs()..put('/work/app/pubspec.yaml', 'name: app\n');
      expect(findProjectRoot('/work/app', fs: fs, context: posix), '/work/app');
    });

    test('is the nearest folder above that has one', () {
      final fs = MemoryFs()
        ..put('/work/pubspec.yaml', 'name: outer\n')
        ..put('/work/app/pubspec.yaml', 'name: app\n')
        ..put('/work/app/lib/src/a.dart', '');
      expect(
        findProjectRoot('/work/app/lib/src', fs: fs, context: posix),
        '/work/app',
      );
    });

    test('is null when no folder up to the root has one', () {
      final fs = MemoryFs()..put('/work/app/lib/a.dart', '');
      expect(findProjectRoot('/work/app/lib', fs: fs, context: posix), isNull);
    });

    test('a pubspec.yaml that is a folder is not a project', () {
      final fs = MemoryFs()..createDir('/work/app/pubspec.yaml');
      expect(findProjectRoot('/work/app', fs: fs, context: posix), isNull);
    });
  });

  group('runBuildToolFromDirectory', () {
    final posix = p.Context(style: p.Style.posix);

    test('outside a Flutter project it says so and returns 2, whatever the '
        'machine has above its temporary folder', () async {
      // The in-memory file system has no pubspec.yaml anywhere, so this
      // does not depend on the real folders above the test's temp dir.
      final fs = MemoryFs();
      final console = FakeConsole();
      expect(
        await runBuildToolFromDirectory(
          ['--list'],
          directory: '/anywhere/below',
          fs: fs,
          console: console,
          pathContext: posix,
        ),
        2,
      );
      expect(
        console.stderrText,
        allOf(
          startsWith(
            'error: no pubspec.yaml in /anywhere/below or any parent folder.',
          ),
          contains('Quick start'),
        ),
      );
      expect(console.stdoutText, isEmpty);
    });

    test('from a subfolder it runs the tool for the project above', () async {
      final world = TestWorld();
      String? seenRoot;
      final code = await runBuildToolFromDirectory(
        ['--list'],
        directory: '/repo/lib/features',
        fs: world.fs,
        console: world.console,
        pathContext: posix,
        environmentFor: (root) {
          seenRoot = root;
          return world.env;
        },
      );
      expect(code, 0, reason: world.console.allText);
      expect(seenRoot, '/repo');
      expect(world.console.stdoutText, contains('Example App (ExampleApp)'));
    });

    test('the exit code of the tool is passed through', () async {
      final world = TestWorld();
      expect(
        await runBuildToolFromDirectory(
          ['apk', 'staging'],
          directory: '/repo',
          fs: world.fs,
          console: world.console,
          pathContext: posix,
          environmentFor: (_) => world.env,
        ),
        2,
      );
    });
  });
}
