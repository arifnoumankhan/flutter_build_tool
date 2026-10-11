// End-to-end tests of the whole tool against the fake machine: nothing here
// starts flutter, ISCC or hdiutil.
import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:test/test.dart';

import 'package:flutter_build_tools/src/cli.dart';
import 'package:flutter_build_tools/src/environment.dart';
import 'package:flutter_build_tools/src/model.dart';
import 'package:flutter_build_tools/src/runner.dart';
import 'package:flutter_build_tools/src/sha256.dart';
import 'fakes.dart';

Future<int> run(TestWorld world, List<String> args) =>
    runBuildTool(args, world.env);

bool isFlutterBuild(ProcessSpec s, [String? target]) =>
    s.executable == 'flutter' &&
    s.args.first == 'build' &&
    (target == null || s.args[1] == target);

Map<String, Object?> jsonFile(TestWorld world, String path) =>
    jsonDecode(world.fs.readString(path)) as Map<String, Object?>;

const apkBytes = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15];
const apkOut = '/repo/build/app/outputs/flutter-apk/app-release.apk';

const winVars = {
  'LOCALAPPDATA': r'C:\L',
  'ProgramFiles(x86)': r'C:\P86',
  'ProgramFiles': r'C:\P',
};
const iscc = r'C:\P86\Inno Setup 6\ISCC.exe';

TestWorld windowsWorld({bool dirty = false}) {
  final world = TestWorld(host: HostOs.windows, dirty: dirty, vars: winVars);
  world.fs.put(iscc, 'iscc');
  world.flutterBuilds('windows', {
    r'C:\repo\build\windows\x64\runner\Release\example_app.exe': 'exe',
  });
  return world;
}

/// ISCC that writes the installer named by /DMyOutputName.
void isccWritesInstaller(TestWorld world, {int failFirst = 0}) {
  var calls = 0;
  world.runner.onStream((s) => s.executable == iscc, (s) {
    if (calls++ < failFirst) return 2;
    final name = s.args
        .firstWhere((a) => a.startsWith('/DMyOutputName='))
        .substring('/DMyOutputName='.length);
    world.fs.put(
      'C:\\repo\\build\\windows\\installers\\$name.exe',
      'installer-bytes',
    );
    return 0;
  });
}

void main() {
  group('entry points', () {
    test('--help prints the usage and exits 0', () async {
      final world = TestWorld();
      expect(await run(world, ['--help']), 0);
      expect(world.console.stdoutText, contains('Usage:'));
      expect(world.runner.calls, isEmpty);
    });

    test('no arguments without a terminal is a usage error (exit 2)', () async {
      final world = TestWorld();
      expect(await run(world, []), 2);
      expect(world.console.stderrText, contains('Missing arguments'));
      expect(world.console.stderrText, contains('needs a terminal'));
    });

    test('bad arguments exit 2 and point at --help', () async {
      final world = TestWorld();
      expect(await run(world, ['apk', 'staging']), 2);
      expect(
        world.console.stderrText,
        allOf(
          contains('Unknown word "staging"'),
          contains('Example: dart run flutter_build_tools apk release preprod'),
          contains('--help'),
        ),
      );
      expect(world.runner.calls, isEmpty);
    });

    test('the interactive picker builds what was chosen', () async {
      final world = TestWorld(interactive: true, inputs: ['1', '2', '1', 'y']);
      world.flutterBuilds('apk', {apkOut: apkBytes});
      expect(await run(world, []), 0);
      expect(
        world.fs.fileExists(
          '/repo/dist/android/ExampleApp-preprod-v1.0.47.apk',
        ),
        isTrue,
      );
    });

    test('declining in the picker builds nothing and exits 1', () async {
      final world = TestWorld(interactive: true, inputs: ['1', '1', '1', 'n']);
      expect(await run(world, []), 1);
      expect(world.console.stdoutText, contains('Cancelled'));
      expect(world.runner.streamed, isEmpty);
    });
  });

  group('--list', () {
    test('platforms, envs and their resolved URLs', () async {
      final world = TestWorld();
      expect(await run(world, ['--list']), 0);
      final out = world.console.stdoutText;
      expect(
        out,
        contains('Example App (ExampleApp) version 1.0.47+47, host macos'),
      );
      expect(out, contains('apk                  buildable on this host'));
      expect(
        out,
        contains(
          'windows (alias exe)  not buildable on this host (Windows only)',
        ),
      );
      expect(out, contains('macos (alias dmg)    buildable on this host'));
      expect(
        out,
        contains('dev      BASE_URL     https://devexample.example.com/public'),
      );
      expect(out, contains('POS_WEB_URL  https://pos.example.com'));
      expect(out, contains('local    BASE_URL     http://127.0.0.1:8011'));
      expect(world.runner.calls, isEmpty);
    });

    test(
      'a broken or mismatching env file is flagged and fails the command',
      () async {
        final world = TestWorld();
        world.fs.put('/repo/config/env/dev.json', '{"APP_ENV": "dev"}');
        world.writeEnvFile('preprod', {
          'APP_ENV': 'dev',
          'BASE_URL': 'https://x.example.com',
        });
        expect(await run(world, ['--list']), 1);
        expect(
          world.console.stdoutText,
          contains(
            'INVALID: config/env/dev.json is missing required key "BASE_URL"',
          ),
        );
        expect(
          world.console.stdoutText,
          contains('APP_ENV is "dev": builds will be refused'),
        );
      },
    );
  });

  group('apk preprod', () {
    test(
      'builds with the defines, names the artifact, writes checksum and manifest',
      () async {
        final world = TestWorld();
        Map<String, Object?>? definesDuringBuild;
        world.flutterBuilds(
          'apk',
          {apkOut: apkBytes},
          inspect: (_) => definesDuringBuild = jsonFile(
            world,
            '/repo/build/build_tool/defines-apk-preprod.json',
          ),
        );

        expect(await run(world, ['apk', 'preprod']), 0);

        expect(definesDuringBuild, {
          'APP_ENV': 'preprod',
          'BASE_URL': 'https://preprod.example.com/public',
          'BUILD_SHA': 'abc1234',
          'POS_WEB_URL': 'https://preprod.example.com/public/web_pos',
        }, reason: 'no per-run value (BUILD_TIME) among the defines');
        expect(
          world.fs.fileExists(
            '/repo/build/build_tool/defines-apk-preprod.json',
          ),
          isFalse,
          reason: 'temporary define file is deleted',
        );

        final flutter = world.runner.streamed.single;
        expect(
          flutter.display,
          'flutter build apk --release --dart-define-from-file=build/build_tool/defines-apk-preprod.json --build-name=1.0.47 --build-number=47',
        );

        const artifact = '/repo/dist/android/ExampleApp-preprod-v1.0.47.apk';
        expect(world.fs.files[artifact], apkBytes);
        final sha = Sha256.hex(apkBytes);
        expect(
          world.fs.readString('$artifact.sha256'),
          '$sha  ExampleApp-preprod-v1.0.47.apk\n',
        );
        final manifest = jsonFile(world, '$artifact.json');
        expect(manifest['sha256'], sha);
        expect(manifest['sizeBytes'], apkBytes.length);
        expect(manifest['env'], 'preprod');
        expect(manifest['platform'], 'apk');
        expect(manifest['file'], 'ExampleApp-preprod-v1.0.47.apk');
        expect(manifest['flutter'], '3.47.0 (stable)');
        expect(manifest['signing'], 'debug-key');
        expect(
          manifest['builtAt'],
          fixedNow,
          reason: 'the build time is kept in the manifest, not in the defines',
        );

        final out = world.console.stdoutText;
        expect(out, contains('OK  ExampleApp-preprod-v1.0.47.apk'));
        expect(out, contains('Path:     $artifact'));
        expect(out, contains('Size:     15 bytes'));
        expect(out, contains('SHA256:   $sha'));
        expect(
          world.console.stderrText,
          contains('signed with the DEBUG key'),
          reason: 'the debug-key fallback is visible',
        );
      },
    );

    test('a build stamp is left for --no-build', () async {
      final world = TestWorld();
      world.flutterBuilds('apk', {apkOut: apkBytes});
      await run(world, ['apk', 'preprod']);
      final stamp = jsonFile(
        world,
        '/repo/build/build_tool/stamp-apk-release.json',
      );
      expect(stamp['platform'], 'apk');
      expect((stamp['defines'] as Map)['APP_ENV'], 'preprod');
      expect(stamp['builtAt'], fixedNow);
      expect((stamp['defines'] as Map).containsKey('BUILD_TIME'), isFalse);
    });

    test(
      'flutter failing: exit 1, nothing in dist, the define file is still deleted',
      () async {
        final world = TestWorld();
        world.runner.onStream((s) => isFlutterBuild(s), (_) => 1);
        expect(await run(world, ['apk', 'preprod']), 1);
        expect(
          world.console.stderrText,
          contains('flutter build apk failed (exit 1)'),
        );
        expect(
          world.fs.files.keys.where((f) => f.startsWith('/repo/dist/')),
          isEmpty,
        );
        expect(
          world.fs.fileExists(
            '/repo/build/build_tool/defines-apk-preprod.json',
          ),
          isFalse,
        );
      },
    );

    test(
      'a failed build removes the previous stamp, so --no-build cannot vouch for half-written output',
      () async {
        final world = TestWorld();
        world.flutterBuilds('apk', {apkOut: apkBytes});
        await run(world, ['apk', 'dev']);
        expect(
          world.fs.fileExists('/repo/build/build_tool/stamp-apk-release.json'),
          isTrue,
        );
        world.runner.onStream((s) => isFlutterBuild(s), (_) => 1, first: true);
        expect(await run(world, ['apk', 'dev']), 1);
        expect(
          world.fs.fileExists('/repo/build/build_tool/stamp-apk-release.json'),
          isFalse,
        );
        expect(await run(world, ['apk', 'dev', '--no-build']), 1);
      },
    );

    test('flutter missing from PATH explains the fix', () async {
      final noFlutter = TestWorld();
      noFlutter.runner.onCapture(
        (s) => s.executable == 'flutter',
        (s) => throw ProcessStartException(s, 'No such file'),
        first: true,
      );
      expect(await run(noFlutter, ['apk', 'preprod']), 1);
      expect(
        noFlutter.console.stderrText,
        allOf(contains('could not start "flutter"'), contains('on PATH')),
      );
      expect(noFlutter.runner.streamed, isEmpty);
    });

    test('a build that leaves no apk is an error', () async {
      final world = TestWorld();
      expect(await run(world, ['apk', 'preprod']), 1);
      expect(
        world.console.stderrText,
        contains(
          'APK not found at build/app/outputs/flutter-apk/app-release.apk',
        ),
      );
    });

    test('debug mode: -debug name suffix and the debug apk path', () async {
      final world = TestWorld();
      world.flutterBuilds('apk', {
        '/repo/build/app/outputs/flutter-apk/app-debug.apk': apkBytes,
      });
      expect(await run(world, ['apk', 'dev', '--debug']), 0);
      expect(
        world.fs.fileExists(
          '/repo/dist/android/ExampleApp-dev-v1.0.47-debug.apk',
        ),
        isTrue,
      );
      expect(world.runner.streamed.single.args.take(3), [
        'build',
        'apk',
        '--debug',
      ]);
    });

    test(
      '--version changes the file name and the binary version together',
      () async {
        final world = TestWorld();
        world.flutterBuilds('apk', {apkOut: apkBytes});
        expect(
          await run(world, [
            'apk',
            'dev',
            '--version',
            '2.5.1',
            '--build-number',
            '77',
          ]),
          0,
        );
        expect(
          world.fs.fileExists('/repo/dist/android/ExampleApp-dev-v2.5.1.apk'),
          isTrue,
        );
        expect(
          world.runner.streamed.single.args,
          containsAll(['--build-name=2.5.1', '--build-number=77']),
        );
      },
    );

    test(
      '--base-url overrides the URL in the define file and is recorded in the manifest',
      () async {
        final world = TestWorld();
        world.flutterBuilds('apk', {apkOut: apkBytes});
        expect(
          await run(world, [
            'apk',
            'local',
            '--base-url',
            'http://192.168.1.20:8011',
          ]),
          0,
        );
        expect(
          jsonFile(
            world,
            '/repo/dist/android/ExampleApp-local-v1.0.47.apk.json',
          )['baseUrl'],
          'http://192.168.1.20:8011',
        );
      },
    );
  });

  group('apk signing and prod', () {
    test(
      'prod apk: requests release signing, reports the release keystore, never prints secrets',
      () async {
        final world = TestWorld()..seedKeystore();
        world.flutterBuilds('apk', {apkOut: apkBytes});
        expect(await run(world, ['apk', 'prod']), 0);
        expect(
          world.runner.streamed.single.args,
          containsAllInOrder(['-P', 'useReleaseSigning=true']),
        );
        expect(
          jsonFile(
            world,
            '/repo/dist/android/ExampleApp-prod-v1.0.47.apk.json',
          )['signing'],
          'release-keystore',
        );
        expect(world.console.allText, isNot(contains('secret-store')));
        expect(world.console.allText, isNot(contains('secret-key')));
        for (final file in world.fs.files.entries.where(
          (f) =>
              f.key.contains('/build/build_tool/') || f.key.contains('/dist/'),
        )) {
          expect(
            utf8.decode(file.value, allowMalformed: true),
            isNot(contains('secret-')),
            reason: file.key,
          );
        }
      },
    );

    test(
      'prod apk without a keystore is refused before flutter starts',
      () async {
        final world = TestWorld();
        expect(await run(world, ['apk', 'prod']), 1);
        expect(world.console.stderrText, contains('error [keystore]'));
        expect(
          world.console.stderrText,
          contains('android/key.properties does not exist'),
        );
        expect(world.runner.streamed, isEmpty);
      },
    );

    test('--release-signing on a non-prod apk', () async {
      final world = TestWorld()..seedKeystore();
      world.flutterBuilds('apk', {apkOut: apkBytes});
      expect(await run(world, ['apk', 'dev', '--release-signing']), 0);
      expect(
        world.runner.streamed.single.args,
        containsAllInOrder(['-P', 'useReleaseSigning=true']),
      );
      expect(
        jsonFile(
          world,
          '/repo/dist/android/ExampleApp-dev-v1.0.47.apk.json',
        )['signing'],
        'release-keystore',
      );
      expect(world.console.stderrText, isNot(contains('DEBUG key')));
    });
  });

  group('guard failures stop everything', () {
    Future<void> refused(
      TestWorld world,
      List<String> args,
      String code, {
      String? message,
    }) async {
      expect(await run(world, args), 1, reason: args.join(' '));
      expect(world.console.stderrText, contains('error [$code]'));
      if (message != null) expect(world.console.stderrText, contains(message));
      expect(world.runner.streamed, isEmpty, reason: 'no build may start');
      expect(
        world.fs.files.keys.where(
          (f) => f.startsWith('/repo/dist/') || f.startsWith('/repo/build/'),
        ),
        isEmpty,
      );
    }

    test('prod + --base-url', () async {
      await refused(TestWorld()..seedKeystore(), [
        'apk',
        'prod',
        '--base-url',
        'https://other.example.com/public',
      ], 'prod-override');
    });

    test('prod + --debug', () async {
      await refused(TestWorld()..seedKeystore(), [
        'apk',
        'prod',
        '--debug',
      ], 'prod-mode');
    });

    test('mismatched APP_ENV in the env file', () async {
      final world = TestWorld()
        ..writeEnvFile('preprod', {
          'APP_ENV': 'dev',
          'BASE_URL': 'https://preprod.example.com/public',
        });
      await refused(
        world,
        ['web', 'preprod'],
        'app-env-mismatch',
        message: 'config/env/preprod.json has APP_ENV "dev"',
      );
    });

    test('http BASE_URL on preprod', () async {
      final world = TestWorld()
        ..writeEnvFile('preprod', {
          'APP_ENV': 'preprod',
          'BASE_URL': 'http://preprod.example.com/public',
        });
      await refused(world, ['web', 'preprod'], 'not-https');
    });

    test('prod pointing at a dev server', () async {
      final world = TestWorld()
        ..writeEnvFile('prod', {
          'APP_ENV': 'prod',
          'BASE_URL': 'https://devexample.example.com/public',
        });
      await refused(world, ['web', 'prod'], 'prod-dev-url');
    });

    test('prod from a dirty tree, and --allow-dirty accepts it', () async {
      await refused(TestWorld(dirty: true), ['web', 'prod'], 'dirty-tree');
      final world = TestWorld(dirty: true);
      world.flutterBuilds('web', {'/repo/build/web/index.html': '<html>'});
      expect(await run(world, ['web', 'prod', '--allow-dirty']), 0);
      expect(
        jsonFile(
          world,
          '/repo/dist/web/ExampleApp-prod-v1.0.47.zip.json',
        )['git'],
        {'sha': 'abc1234', 'dirty': true},
      );
      expect(
        world.runner.streamed.single.args,
        contains(
          '--dart-define-from-file=build/build_tool/defines-web-prod.json',
        ),
      );
    });

    test('windows prod on macOS: the right message, nothing runs', () async {
      final world = TestWorld();
      await refused(
        world,
        ['windows', 'prod'],
        'host-windows',
        message: 'only be built on Windows (this host: macos)',
      );
    });

    test('macos target on a Windows host', () async {
      await refused(
        windowsWorld(),
        ['dmg', 'dev'],
        'host-macos',
        message: 'only be built on macOS (this host: windows)',
      );
    });

    test('every problem is listed, not just the first', () async {
      final world = TestWorld(dirty: true);
      expect(
        await run(world, [
          'windows',
          'prod',
          '--debug',
          '--base-url',
          'http://localhost:1',
        ]),
        1,
      );
      final err = world.console.stderrText;
      for (final code in [
        'not-https',
        'prod-dev-url',
        'prod-override',
        'prod-mode',
        'dirty-tree',
        'host-windows',
      ]) {
        expect(err, contains('error [$code]'));
      }
      expect(err, contains('Refusing to build: 6 problem(s)'));
    });
  });

  group('web dev', () {
    test(
      'zips build/web with the files at the root and prints the deploy hint',
      () async {
        final world = TestWorld();
        world.flutterBuilds('web', {
          '/repo/build/web/index.html': '<html>',
          '/repo/build/web/main.dart.js': 'js',
          '/repo/build/web/assets/a.json': '{}',
          '/repo/build/web/.DS_Store': 'x',
          '/repo/build/web/.last_build_id': 'id',
          '/repo/build/web/old.zip': 'z',
        });
        expect(await run(world, ['web', 'dev']), 0);
        const artifact = '/repo/dist/web/ExampleApp-dev-v1.0.47.zip';
        final archive = ZipDecoder().decodeBytes(world.fs.files[artifact]!);
        expect(archive.files.map((f) => f.name), [
          'assets/a.json',
          'index.html',
          'main.dart.js',
        ]);
        expect(
          world.fs.readString('$artifact.sha256'),
          startsWith(Sha256.hex(world.fs.files[artifact]!)),
        );
        final out = world.console.stdoutText;
        expect(
          out,
          contains("Deploy: extract into the folder served at '/web_admin/'"),
        );
        expect(out, contains('base href    /web_admin/   [web/index.html]'));
      },
    );

    test('a build without index.html is an error', () async {
      final world = TestWorld();
      expect(await run(world, ['web', 'dev']), 1);
      expect(
        world.console.stderrText,
        contains('Web build not found at build/web'),
      );
    });
  });

  group('windows', () {
    test(
      'windows prod: flutter, then Inno Setup, installer copied to dist/windows',
      () async {
        final world = windowsWorld();
        world.fs.put(
          r'C:\repo\build\windows\installers\Example-Setup-1.0.40.exe',
          'old',
        );
        world.fs.put(
          r'C:\repo\build\windows\installers\ExampleApp-dev-v1.0.46.exe',
          'old',
        );
        world.fs.put(r'C:\repo\build\windows\installers\readme.txt', 'keep');
        isccWritesInstaller(world);

        expect(await run(world, ['exe', 'prod']), 0);

        expect(world.runner.streamed.map((s) => s.executable), [
          'flutter',
          iscc,
        ]);
        expect(world.runner.streamed[0].shell, isTrue);
        expect(world.runner.streamed[1].args, [
          '/DMyAppVersion=1.0.47',
          '/DMyOutputName=ExampleApp-prod-v1.0.47',
          r'C:\repo\installer\example_app.iss',
        ]);
        expect(
          world.fs.fileExists(
            r'C:\repo\build\windows\installers\Example-Setup-1.0.40.exe',
          ),
          isFalse,
          reason: 'old installers are cleared',
        );
        expect(
          world.fs.fileExists(
            r'C:\repo\build\windows\installers\ExampleApp-dev-v1.0.46.exe',
          ),
          isFalse,
        );
        expect(
          world.fs.fileExists(r'C:\repo\build\windows\installers\readme.txt'),
          isTrue,
        );
        const artifact = r'C:\repo\dist\windows\ExampleApp-prod-v1.0.47.exe';
        expect(world.fs.readString(artifact), 'installer-bytes');
        expect(world.fs.fileExists('$artifact.sha256'), isTrue);
        expect(jsonFile(world, '$artifact.json')['platform'], 'windows');
        expect(jsonFile(world, '$artifact.json')['hostOs'], 'windows');
        expect(world.sleeps, isEmpty);
      },
    );

    test('Inno failing once is retried after 3 seconds', () async {
      final world = windowsWorld();
      isccWritesInstaller(world, failFirst: 1);
      expect(await run(world, ['windows', 'dev']), 0);
      expect(
        world.runner.streamed.where((s) => s.executable == iscc),
        hasLength(2),
      );
      expect(world.sleeps, [const Duration(seconds: 3)]);
      expect(world.console.stdoutText, contains('Retrying once'));
    });

    test('Inno failing twice stops with the antivirus hint', () async {
      final world = windowsWorld();
      isccWritesInstaller(world, failFirst: 2);
      expect(await run(world, ['windows', 'dev']), 1);
      expect(
        world.console.stderrText,
        allOf(
          contains('Inno Setup compile failed (exit 2)'),
          contains('antivirus'),
          contains('build/windows/installers'),
        ),
      );
      expect(world.fs.files.keys.where((f) => f.contains(r'\dist\')), isEmpty);
    });

    test('ISCC.exe missing stops before the long flutter build', () async {
      final world = TestWorld(host: HostOs.windows, vars: winVars);
      expect(await run(world, ['windows', 'dev']), 1);
      expect(
        world.console.stderrText,
        allOf(
          contains('ISCC.exe not found'),
          contains('winget install JRSoftware.InnoSetup'),
        ),
      );
      expect(world.runner.streamed, isEmpty);
    });

    test(
      'an installer script that ignores /DMyOutputName is detected',
      () async {
        final world = windowsWorld();
        world.runner.onStream((s) => s.executable == iscc, (_) => 0);
        expect(await run(world, ['windows', 'dev']), 1);
        expect(
          world.console.stderrText,
          allOf(
            contains('ExampleApp-dev-v1.0.47.exe is missing'),
            contains('OutputBaseFilename={#MyOutputName}'),
          ),
        );
      },
    );

    test(
      'debug: packages the Debug folder, and refuses an iss that cannot',
      () async {
        final world = TestWorld(host: HostOs.windows, vars: winVars);
        world.fs.put(iscc, 'iscc');
        world.flutterBuilds('windows', {
          r'C:\repo\build\windows\x64\runner\Debug\example_app.exe': 'exe',
        });
        isccWritesInstaller(world);
        expect(await run(world, ['windows', 'dev', '--debug']), 0);
        expect(
          world.runner.streamed.last.args,
          contains('/DMyBuildMode=Debug'),
        );
        expect(
          world.fs.fileExists(
            r'C:\repo\dist\windows\ExampleApp-dev-v1.0.47-debug.exe',
          ),
          isTrue,
        );

        final stale = windowsWorld();
        stale.fs.put(
          r'C:\repo\installer\example_app.iss',
          'OutputBaseFilename={#MyOutputName}',
        );
        expect(await run(stale, ['windows', 'dev', '--debug']), 1);
        expect(
          stale.console.stderrText,
          contains('always packages the Release folder'),
        );
        expect(stale.runner.streamed, isEmpty);
      },
    );

    test(
      '--msix adds a second artifact built by msix:create, without rebuilding',
      () async {
        final world = windowsWorld();
        isccWritesInstaller(world);
        world.runner.onStream((s) => s.executable == 'dart', (s) {
          world.fs.put(
            r'C:\repo\dist\windows\ExampleApp-dev-v1.0.47.msix',
            'msix-bytes',
          );
          return 0;
        });
        expect(await run(world, ['windows', 'dev', '--msix']), 0);
        expect(world.runner.streamed.map((s) => s.executable), [
          'flutter',
          iscc,
          'dart',
        ]);
        expect(
          world.runner.streamed.last.args,
          containsAllInOrder(['msix:create', '--build-windows', 'false']),
        );
        for (final extension in ['exe', 'msix']) {
          final path =
              r'C:\repo\dist\windows\ExampleApp-dev-v1.0.47.' + extension;
          expect(
            world.fs.fileExists('$path.sha256'),
            isTrue,
            reason: extension,
          );
          expect(
            jsonFile(world, '$path.json')['file'],
            'ExampleApp-dev-v1.0.47.$extension',
          );
        }
      },
    );

    test(
      '--msix without the msix package in pubspec stops before the build',
      () async {
        final world = windowsWorld();
        world.fs.put(r'C:\repo\pubspec.yaml', 'name: x\nversion: 1.0.47+47\n');
        expect(await run(world, ['windows', 'dev', '--msix']), 1);
        expect(world.console.stderrText, contains('needs the msix package'));
        expect(world.runner.streamed, isEmpty);
      },
    );

    test('--msix on a debug build is refused', () async {
      final world = windowsWorld();
      expect(await run(world, ['windows', 'dev', '--msix', '--debug']), 1);
      expect(world.console.stderrText, contains('error [msix-mode]'));
    });
  });

  group('macos', () {
    TestWorld macWorld() {
      final world = TestWorld();
      world.flutterBuilds('macos', {
        '/repo/build/macos/Build/Products/Release/Example App.app/Contents/Info.plist':
            'plist',
      });
      world.runner.onStream((s) => s.executable == 'hdiutil', (s) {
        world.fs.put(s.args.last, 'dmg-bytes');
        return 0;
      });
      return world;
    }

    test(
      'stages the app, builds the DMG, removes the staging folder',
      () async {
        final world = macWorld();
        expect(await run(world, ['dmg', 'dev']), 0);
        expect(world.runner.streamed.map((s) => s.executable), [
          'flutter',
          'cp',
          'ln',
          'hdiutil',
        ]);
        final hdiutil = world.runner.streamed.last;
        expect(hdiutil.args, [
          'create',
          '-volname',
          'Example App',
          '-srcfolder',
          '/tmp/exampleapp_dmg_0',
          '-ov',
          '-format',
          'UDZO',
          '/repo/dist/macos/ExampleApp-dev-v1.0.47.dmg',
        ]);
        expect(world.fs.dirs, isNot(contains('/tmp/exampleapp_dmg_0')));
        expect(
          world.fs.readString('/repo/dist/macos/ExampleApp-dev-v1.0.47.dmg'),
          'dmg-bytes',
        );
        expect(
          world.fs.fileExists(
            '/repo/dist/macos/ExampleApp-dev-v1.0.47.dmg.sha256',
          ),
          isTrue,
        );
      },
    );

    test('a failing hdiutil still removes the staging folder', () async {
      final world = TestWorld();
      world.flutterBuilds('macos', {
        '/repo/build/macos/Build/Products/Release/Example App.app/Contents/Info.plist':
            'plist',
      });
      world.runner.onStream((s) => s.executable == 'hdiutil', (_) => 1);
      expect(await run(world, ['macos', 'dev']), 1);
      expect(world.console.stderrText, contains('hdiutil failed (exit 1)'));
      expect(world.fs.dirs, isNot(contains('/tmp/exampleapp_dmg_0')));
    });

    test('a missing app bundle is an error', () async {
      final world = TestWorld();
      expect(await run(world, ['macos', 'dev']), 1);
      expect(
        world.console.stderrText,
        contains(
          'App bundle not found at build/macos/Build/Products/Release/Example App.app',
        ),
      );
    });
  });

  group('--dry-run executes nothing', () {
    for (final (platform, host) in [
      ('apk', HostOs.macos),
      ('web', HostOs.macos),
      ('macos', HostOs.macos),
      ('windows', HostOs.windows),
      ('windows', HostOs.macos),
    ]) {
      test('$platform on ${host.name}', () async {
        final world = TestWorld(host: host, vars: winVars);
        final before = world.fs.snapshot();
        await run(world, [platform, 'preprod', '--dry-run']);
        expect(
          world.runner.streamed,
          isEmpty,
          reason: 'no flutter / ISCC / hdiutil',
        );
        expect(
          world.runner.calls.map((c) => c.executable).toSet().difference({
            'git',
            'df',
          }),
          isEmpty,
          reason: 'only read-only git and df probes',
        );
        expect(
          world.fs.snapshot(),
          before,
          reason: 'no file written or deleted',
        );
        final out = world.console.stdoutText;
        expect(out, contains('Build profile'));
        expect(
          out,
          contains('BASE_URL     https://preprod.example.com/public'),
        );
        expect(
          out,
          contains(
            'flutter build $platform --release --dart-define-from-file=build/build_tool/defines-$platform-preprod.json',
          ),
        );
      });
    }

    test('a good dry run exits 0 and says nothing was built', () async {
      final world = TestWorld();
      expect(await run(world, ['web', 'dev', '--dry-run']), 0);
      expect(world.console.stdoutText, contains('dry run: nothing was built.'));
    });

    test(
      'a dry run that a real run would refuse exits 1 but still shows the plan',
      () async {
        final world = TestWorld();
        expect(await run(world, ['windows', 'prod', '--dry-run']), 1);
        expect(
          world.console.stdoutText,
          allOf(
            contains('Plan:'),
            contains(
              'ISCC.exe /DMyAppVersion=1.0.47 /DMyOutputName=ExampleApp-prod-v1.0.47',
            ),
          ),
        );
        expect(
          world.console.stderrText,
          allOf(
            contains('error [host-windows]'),
            contains('a real run would be refused'),
          ),
        );
      },
    );

    test('the plan shows the exact msix, dmg and apk signing commands', () async {
      final windows = TestWorld(host: HostOs.windows, vars: winVars);
      await run(windows, ['windows', 'dev', '--msix', '--dry-run']);
      expect(
        windows.console.stdoutText,
        contains(
          'dart run msix:create --build-windows false --install-certificate false --version 1.0.47.0',
        ),
      );
      final mac = TestWorld();
      await run(mac, ['dmg', 'dev', '--dry-run']);
      expect(
        mac.console.stdoutText,
        contains(
          'hdiutil create -volname "Example App" -srcfolder "<temp staging folder>" -ov -format UDZO',
        ),
      );
      final apk = TestWorld()..seedKeystore();
      await run(apk, ['apk', 'prod', '--dry-run']);
      expect(apk.console.stdoutText, contains('-P useReleaseSigning=true'));
      expect(apk.console.stdoutText, contains('signing      release keystore'));
    });
  });

  group('--dry-run also runs the read-only pre-flight checks of a real run', () {
    test(
      'windows on Windows: ISCC found, its path is in the command',
      () async {
        final world = windowsWorld();
        expect(await run(world, ['windows', 'dev', '--dry-run']), 0);
        expect(world.console.stdoutText, contains('ISCC.exe found'));
        expect(
          world.console.stdoutText,
          contains('"$iscc" /DMyAppVersion=1.0.47'),
        );
      },
    );

    test(
      'windows on Windows: ISCC missing is reported, nothing runs',
      () async {
        final world = TestWorld(host: HostOs.windows, vars: winVars);
        expect(await run(world, ['windows', 'dev', '--dry-run']), 1);
        expect(world.console.stderrText, contains('ISCC.exe not found'));
        expect(
          world.console.stderrText,
          contains('a real run would be refused (1 problem(s))'),
        );
        expect(world.runner.streamed, isEmpty);
      },
    );

    test('--no-build without a matching stamp', () async {
      final world = TestWorld();
      expect(await run(world, ['apk', 'dev', '--no-build', '--dry-run']), 1);
      expect(world.console.stderrText, contains('no build stamp'));
      expect(
        world.console.stdoutText,
        contains(
          'verify build/build_tool/stamp-apk-release.json matches this profile',
        ),
      );
    });

    test('--no-build with a matching stamp passes', () async {
      final world = TestWorld();
      world.flutterBuilds('apk', {apkOut: apkBytes});
      await run(world, ['apk', 'dev']);
      expect(await run(world, ['apk', 'dev', '--no-build', '--dry-run']), 0);
    });
  });

  group('--no-build', () {
    Future<TestWorld> built({String env = 'dev'}) async {
      final world = TestWorld();
      world.flutterBuilds('apk', {apkOut: apkBytes});
      expect(await run(world, ['apk', env]), 0);
      world.runner.streamed.clear();
      world.fs.deleteDir('/repo/dist');
      return world;
    }

    test('re-packages the existing output when the stamp matches', () async {
      final world = await built();
      expect(await run(world, ['apk', 'dev', '--no-build']), 0);
      expect(world.runner.streamed, isEmpty, reason: 'flutter is not run');
      expect(
        world.fs.files['/repo/dist/android/ExampleApp-dev-v1.0.47.apk'],
        apkBytes,
      );
      expect(
        world.console.stdoutText,
        contains('--no-build: re-packaging the existing output'),
      );
      expect(
        jsonFile(
          world,
          '/repo/dist/android/ExampleApp-dev-v1.0.47.apk.json',
        )['builtAt'],
        fixedNow,
        reason: 'build time of the original build',
      );
    });

    test('refuses output built for another environment', () async {
      final world = await built();
      expect(await run(world, ['apk', 'preprod', '--no-build']), 1);
      final err = world.console.stderrText;
      expect(err, contains('does not match this profile'));
      expect(err, contains('APP_ENV: built dev, requested preprod'));
      expect(
        err,
        contains(
          'BASE_URL: built https://devexample.example.com/public, requested https://preprod.example.com/public',
        ),
      );
      expect(
        world.fs.files.keys.where((f) => f.startsWith('/repo/dist/')),
        isEmpty,
      );
    });

    test('refuses a changed version or mode', () async {
      final world = await built();
      expect(
        await run(world, ['apk', 'dev', '--no-build', '--version', '9.9.9']),
        1,
      );
      expect(
        world.console.stderrText,
        contains('version: built 1.0.47, requested 9.9.9'),
      );
      world.fs.put(
        '/repo/build/app/outputs/flutter-apk/app-debug.apk',
        apkBytes,
      );
      expect(await run(world, ['apk', 'dev', '--no-build', '--debug']), 1);
      expect(
        world.console.stderrText,
        contains('no build stamp'),
        reason: 'there is no debug stamp',
      );
    });

    test(
      'refuses when there is no stamp at all (output of unknown origin)',
      () async {
        final world = TestWorld();
        world.fs.put(apkOut, apkBytes);
        expect(await run(world, ['apk', 'dev', '--no-build']), 1);
        expect(
          world.console.stderrText,
          allOf(
            contains(
              'no build stamp at build/build_tool/stamp-apk-release.json',
            ),
            contains('without --no-build'),
          ),
        );
      },
    );

    test('refuses an unreadable stamp', () async {
      final world = TestWorld();
      world.fs.put(apkOut, apkBytes);
      world.fs.put('/repo/build/build_tool/stamp-apk-release.json', '{broken');
      expect(await run(world, ['apk', 'dev', '--no-build']), 1);
      expect(world.console.stderrText, contains('unreadable'));
    });

    test('works without flutter installed (manifest says unknown)', () async {
      final world = await built();
      final offline = TestWorld();
      offline.fs.files
        ..clear()
        ..addAll(world.fs.files);
      offline.runner.onCapture(
        (s) => s.executable == 'flutter',
        (_) => const CapturedProcess(1, '', 'broken'),
        first: true,
      );
      expect(await run(offline, ['apk', 'dev', '--no-build']), 0);
      expect(
        offline.console.stdoutText,
        contains('could not read the Flutter version'),
      );
      expect(
        jsonFile(
          offline,
          '/repo/dist/android/ExampleApp-dev-v1.0.47.apk.json',
        )['flutter'],
        'unknown',
      );
    });
  });

  group('the sentences the user says, with the mode word', () {
    test('apk release preprod builds the release APK for preprod', () async {
      final world = TestWorld();
      world.flutterBuilds('apk', {apkOut: apkBytes});
      expect(await run(world, ['apk', 'release', 'preprod']), 0);
      expect(
        world.runner.streamed.single.display,
        startsWith('flutter build apk --release --dart-define-from-file='),
      );
      expect(
        world.fs.fileExists(
          '/repo/dist/android/ExampleApp-preprod-v1.0.47.apk',
        ),
        isTrue,
      );
    });

    test(
      'web release dev, dry run: the resolved profile and commands',
      () async {
        final world = TestWorld();
        expect(await run(world, ['web', 'release', 'dev', '--dry-run']), 0);
        final out = world.console.stdoutText;
        expect(out, contains('target       web / dev / release'));
        expect(
          out,
          contains('BASE_URL     https://devexample.example.com/public'),
        );
        expect(
          out,
          contains('flutter build web --release --dart-define-from-file='),
        );
        expect(world.runner.streamed, isEmpty);
      },
    );

    test('windows release prod, dry run on Windows', () async {
      final world = windowsWorld();
      expect(await run(world, ['windows', 'release', 'prod', '--dry-run']), 0);
      final out = world.console.stdoutText;
      expect(out, contains('target       windows / prod / release'));
      expect(out, contains('flutter build windows --release'));
      expect(out, contains('ISCC.exe found'));
    });

    test('the same request in every word order is built identically', () async {
      final plans = <String>{};
      for (final words in [
        ['apk', 'release', 'preprod'],
        ['apk', 'preprod', 'release'],
        ['release', 'apk', 'preprod'],
        ['preprod', 'apk', 'release'],
      ]) {
        final world = TestWorld();
        expect(await run(world, [...words, '--dry-run']), 0, reason: '$words');
        plans.add(world.console.stdoutText);
      }
      expect(plans, hasLength(1));
    });

    test('a bare debug word builds debug and names the file for it', () async {
      final world = TestWorld();
      world.flutterBuilds('apk', {
        '/repo/build/app/outputs/flutter-apk/app-debug.apk': apkBytes,
      });
      expect(await run(world, ['apk', 'debug', 'dev']), 0);
      expect(world.runner.streamed.single.display, contains('--debug'));
      expect(
        world.fs.fileExists(
          '/repo/dist/android/ExampleApp-dev-v1.0.47-debug.apk',
        ),
        isTrue,
      );
    });

    test('prod stays release only when the mode is a bare word', () async {
      final world = TestWorld();
      expect(await run(world, ['apk', 'debug', 'prod']), 1);
      expect(world.console.stderrText, contains('error [prod-mode]'));
      expect(world.runner.streamed, isEmpty);
    });

    test(
      'conflicts and unknown words exit 2, run nothing, show an example',
      () async {
        for (final args in [
          ['apk', 'release', 'preprod', '--debug'],
          ['apk', 'release', 'debug', 'preprod'],
          ['apk', 'preprod', 'fast'],
          ['apk', 'web', 'preprod'],
        ]) {
          final world = TestWorld();
          expect(await run(world, args), 2, reason: '$args');
          expect(
            world.console.stderrText,
            contains('Example: '),
            reason: '$args',
          );
          expect(world.console.stderrText, contains('--help'), reason: '$args');
          expect(world.runner.calls, isEmpty, reason: '$args');
        }
      },
    );
  });

  group(
    'the build time is not a define (it leaked a cache folder per build)',
    () {
      test(
        'two real runs at different times pass the same defines to flutter',
        () async {
          final defines = <String>[];
          for (final minute in [1, 59]) {
            final world = TestWorld();
            final now = DateTime.utc(2026, 10, 6, 12, minute, 0);
            final env = BuildEnvironment(
              root: '/repo',
              host: HostOs.macos,
              vars: const {},
              fs: world.fs,
              runner: world.runner,
              console: world.console,
              now: () => now,
            );
            world.flutterBuilds(
              'apk',
              {apkOut: apkBytes},
              inspect: (_) => defines.add(
                world.fs.readString(
                  '/repo/build/build_tool/defines-apk-preprod.json',
                ),
              ),
            );
            expect(await runBuildTool(['apk', 'preprod'], env), 0);
            expect(
              jsonFile(
                world,
                '/repo/dist/android/ExampleApp-preprod-v1.0.47.apk.json',
              )['builtAt'],
              '2026-10-06T12:${minute.toString().padLeft(2, '0')}:00Z',
              reason: 'each manifest still records its own build time',
            );
          }
          expect(defines, hasLength(2));
          expect(defines.first, defines.last);
          expect(defines.first, isNot(contains('BUILD_TIME')));
          expect(defines.first, isNot(contains('2026-10-06')));
        },
      );

      test(
        'the profile printed before a build says the time is manifest only',
        () async {
          final world = TestWorld();
          await run(world, ['apk', 'preprod', '--dry-run']);
          final out = world.console.stdoutText;
          expect(
            out,
            contains(
              'build time   $fixedNow   [manifest only, not compiled in]',
            ),
          );
          expect(out, isNot(contains('BUILD_TIME')));
        },
      );

      test('--no-build still reads the time of the original build', () async {
        final world = TestWorld();
        world.flutterBuilds('apk', {apkOut: apkBytes});
        expect(await run(world, ['apk', 'dev']), 0);
        final stampPath = '/repo/build/build_tool/stamp-apk-release.json';
        expect(jsonFile(world, stampPath)['builtAt'], fixedNow);
        world.fs.deleteDir('/repo/dist');
        expect(await run(world, ['apk', 'dev', '--no-build']), 0);
        expect(
          world.console.stdoutText,
          contains(
            're-packaging the existing output (built $fixedNow, abc1234)',
          ),
        );
      });

      test(
        'a stamp written before the change (time inside the defines) still works',
        () async {
          final world = TestWorld();
          world.flutterBuilds('apk', {apkOut: apkBytes});
          expect(await run(world, ['apk', 'dev']), 0);
          final stampPath = '/repo/build/build_tool/stamp-apk-release.json';
          final legacy = jsonFile(world, stampPath);
          legacy.remove('builtAt');
          (legacy['defines'] as Map<String, Object?>)['BUILD_TIME'] =
              '2025-01-02T03:04:05Z';
          world.fs.put(stampPath, jsonEncode(legacy));
          world.fs.deleteDir('/repo/dist');
          expect(
            await run(world, ['apk', 'dev', '--no-build']),
            0,
            reason: world.console.allText,
          );
          expect(
            jsonFile(
              world,
              '/repo/dist/android/ExampleApp-dev-v1.0.47.apk.json',
            )['builtAt'],
            '2025-01-02T03:04:05Z',
          );
        },
      );
    },
  );

  group('free disk space pre-flight', () {
    const gigabytesInKb = 1024 * 1024;

    void scriptDf(TestWorld world, int availableKb) {
      world.runner.onCapture(
        (s) => s.executable == 'df',
        (_) => CapturedProcess(
          0,
          'Filesystem   1024-blocks     Used Available Capacity  Mounted on\n'
              '/dev/disk3s1    97656252 86275520 $availableKb    89%    /Volumes/Workspaces\n',
          '',
        ),
      );
    }

    Iterable<ProcessSpec> dfCalls(TestWorld world) =>
        world.runner.calls.where((c) => c.executable == 'df');

    test('under 3 GB free: a loud warning, and the build still runs', () async {
      final world = TestWorld();
      scriptDf(world, 1536 * 1024); // 1.5 GB
      world.flutterBuilds('apk', {apkOut: apkBytes});
      expect(await run(world, ['apk', 'preprod']), 0);
      final err = world.console.stderrText;
      expect(
        err,
        contains('warning [low-disk]: LOW DISK SPACE: only 1.5 GB free'),
      );
      expect(err, contains('.dart_tool/flutter_build'));
      expect(world.runner.streamed, hasLength(1), reason: 'flutter still ran');
      expect(
        world.fs.fileExists(
          '/repo/dist/android/ExampleApp-preprod-v1.0.47.apk',
        ),
        isTrue,
      );
      expect(dfCalls(world).single.args, ['-Pk', '/repo']);
    });

    test('the warning comes before the build starts', () async {
      final world = TestWorld();
      scriptDf(world, 100 * 1024);
      var warnedBeforeFlutter = false;
      world.flutterBuilds(
        'web',
        {'/repo/build/web/index.html': '<html>'},
        inspect: (_) =>
            warnedBeforeFlutter = world.console.stderrText.contains('low-disk'),
      );
      expect(await run(world, ['web', 'dev']), 0);
      expect(warnedBeforeFlutter, isTrue);
    });

    test('3 GB or more: no warning', () async {
      final world = TestWorld();
      scriptDf(world, 3 * gigabytesInKb);
      world.flutterBuilds('apk', {apkOut: apkBytes});
      expect(await run(world, ['apk', 'preprod']), 0);
      expect(world.console.stderrText, isNot(contains('low-disk')));
      expect(dfCalls(world), hasLength(1));
    });

    test('a dry run warns too and builds nothing', () async {
      final world = TestWorld();
      scriptDf(world, 200 * 1024);
      expect(await run(world, ['apk', 'preprod', '--dry-run']), 0);
      expect(world.console.stderrText, contains('warning [low-disk]'));
      expect(world.runner.streamed, isEmpty);
    });

    test('--no-build runs no flutter, so the disk is not looked at', () async {
      final world = TestWorld();
      world.flutterBuilds('apk', {apkOut: apkBytes});
      expect(await run(world, ['apk', 'dev']), 0);
      world.runner.calls.clear();
      scriptDf(world, 100 * 1024);
      expect(await run(world, ['apk', 'dev', '--no-build']), 0);
      expect(dfCalls(world), isEmpty);
      expect(world.console.stderrText, isNot(contains('low-disk')));
    });

    test('Windows is not probed', () async {
      final world = windowsWorld();
      scriptDf(world, 100 * 1024);
      expect(await run(world, ['windows', 'dev', '--dry-run']), 0);
      expect(dfCalls(world), isEmpty);
      expect(world.console.stderrText, isNot(contains('low-disk')));
    });

    test(
      'df missing or unreadable is ignored: no warning, no failure',
      () async {
        final missing = TestWorld(); // df not scripted
        missing.flutterBuilds('apk', {apkOut: apkBytes});
        expect(await run(missing, ['apk', 'preprod']), 0);
        expect(missing.console.stderrText, isNot(contains('low-disk')));

        final garbled = TestWorld();
        garbled.runner.onCapture(
          (s) => s.executable == 'df',
          (_) => const CapturedProcess(0, 'nonsense', ''),
        );
        garbled.flutterBuilds('apk', {apkOut: apkBytes});
        expect(await run(garbled, ['apk', 'preprod']), 0);
        expect(garbled.console.stderrText, isNot(contains('low-disk')));
      },
    );

    test('it does not turn a refused build into an accepted one', () async {
      final world = TestWorld();
      scriptDf(world, 100 * 1024);
      expect(await run(world, ['windows', 'dev']), 1);
      expect(world.console.stderrText, contains('error [host-windows]'));
      expect(world.console.stderrText, contains('warning [low-disk]'));
    });
  });
}
