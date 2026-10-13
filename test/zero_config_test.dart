// A project with no tool/build/build_config.json: every fact is inferred from
// the project, a key of the file wins over the inference key by key, and the
// windows / macos facts are only needed when that platform is built.
import 'dart:convert';

import 'package:test/test.dart';

import 'package:flutter_build_tools/src/args.dart';
import 'package:flutter_build_tools/src/cli.dart';
import 'package:flutter_build_tools/src/config.dart';
import 'package:flutter_build_tools/src/inference.dart';
import 'package:flutter_build_tools/src/model.dart';
import 'package:flutter_build_tools/src/profile.dart';
import 'fakes.dart';

Future<int> run(TestWorld world, List<String> args) =>
    runBuildTool(args, world.env);

const _configFile = '/repo/tool/build/build_config.json';

/// The fake repository with no build_config.json, and the facts the Flutter
/// templates carry: windows/CMakeLists.txt, AppInfo.xcconfig, one installer.
TestWorld zeroConfig({bool templates = true}) {
  final world = TestWorld()..fs.deleteFile(_configFile);
  if (templates) {
    world.fs
      ..put('/repo/windows/CMakeLists.txt', 'set(BINARY_NAME "example_app")\n')
      ..put(
        '/repo/macos/Runner/Configs/AppInfo.xcconfig',
        'PRODUCT_NAME = example_app\n',
      );
  }
  return world;
}

/// A repository with no windows, macos or installer files at all.
TestWorld mobileOnly() {
  final world = zeroConfig(templates: false)
    ..fs.deleteFile('/repo/installer/example_app.iss');
  return world;
}

void main() {
  group('no build_config.json', () {
    test('--list works and names the app after the pubspec', () async {
      final world = zeroConfig();
      expect(await run(world, ['--list']), 0, reason: world.console.allText);
      expect(
        world.console.stdoutText,
        startsWith('Example App (ExampleApp) version 1.0.47+47, host macos'),
      );
    });

    test('a dry run resolves slug, app and artifact name', () async {
      final world = zeroConfig();
      expect(
        await run(world, ['apk', 'dev', '--dry-run']),
        0,
        reason: world.console.allText,
      );
      final out = world.console.stdoutText;
      expect(out, contains('app          app (Example App)'));
      expect(out, contains('dist/android/ExampleApp-dev-v1.0.47.apk'));
    });

    test(
      'the profile says the facts were inferred, so a missing file is not silent',
      () async {
        // The config file is what switches devHostMarkers on: an app whose
        // file is missing (never committed, git-ignored) would otherwise build
        // under another artifact name without a word.
        final world = zeroConfig();
        expect(await run(world, ['apk', 'dev', '--dry-run']), 0);
        expect(
          world.console.stdoutText,
          contains(
            '  app          app (Example App)\n'
            '  config       inferred from the project (no tool/build/build_config.json)\n'
            '  target       apk / dev / release\n',
          ),
        );
      },
    );

    test('a real build says it too, not only a dry run', () async {
      final world = zeroConfig();
      world.flutterBuilds('web', {'/repo/build/web/index.html': '<html>'});
      expect(await run(world, ['web', 'dev']), 0);
      expect(
        world.console.stdoutText,
        contains('config       inferred from the project'),
      );
    });

    test('a project that has the file prints no such line', () async {
      final world = TestWorld();
      expect(await run(world, ['apk', 'dev', '--dry-run']), 0);
      expect(world.console.stdoutText, isNot(contains('  config       ')));
      expect(world.console.stdoutText, contains('  app          admin ('));
    });

    test('the file missing changes the name and the guard, and says so', () async {
      // The case the line is for: a prod build pointing at the dev host. With
      // the file the project's marker refuses it; without it only the built-in
      // markers apply, and the output must not hide that the file was not read.
      final withFile = TestWorld();
      withFile.writeEnvFile('prod', {
        'APP_ENV': 'prod',
        'BASE_URL': 'https://devexample.example.com/public',
      });
      expect(await run(withFile, ['apk', 'prod', '--dry-run']), 1);
      expect(withFile.console.stderrText, contains('error [prod-dev-url]'));

      final without = zeroConfig();
      without.writeEnvFile('prod', {
        'APP_ENV': 'prod',
        'BASE_URL': 'https://devexample.example.com/public',
      });
      await run(without, ['apk', 'prod', '--dry-run']);
      expect(without.console.stderrText, isNot(contains('prod-dev-url')));
      expect(
        without.console.stdoutText,
        contains('config       inferred from the project'),
      );
    });

    test('--help is titled with the inferred name and shows init', () async {
      final world = zeroConfig();
      expect(await run(world, ['--help']), 0);
      final out = world.console.stdoutText;
      expect(out, startsWith('Example App build tool: one command'));
      expect(out, contains('dart run flutter_build_tools init'));
      expect(out, contains('First run in a new project'));
    });

    test('a real web build works and the manifest says app', () async {
      final world = zeroConfig();
      world.flutterBuilds('web', {'/repo/build/web/index.html': '<html>'});
      expect(
        await run(world, ['web', 'dev']),
        0,
        reason: world.console.allText,
      );
      const artifact = '/repo/dist/web/ExampleApp-dev-v1.0.47.zip';
      expect(world.fs.fileExists(artifact), isTrue);
      final manifest =
          jsonDecode(world.fs.readString('$artifact.json'))
              as Map<String, Object?>;
      expect(manifest['app'], 'app');
    });

    test(
      'is the same as a file that holds exactly the inferred values',
      () async {
        // What `init` writes must change nothing: the output of every command
        // is identical with and without the file, except for the one profile
        // line that says the facts were inferred (so a file that was never
        // committed is noticed in CI).
        const inferredLine =
            '  config       inferred from the project (no tool/build/build_config.json)';
        final explicit = zeroConfig()
          ..fs.put(
            _configFile,
            jsonEncode({
              'app': 'app',
              'slug': 'ExampleApp',
              'displayName': 'Example App',
              'envDir': 'config/env',
              'windows': {
                'exe': 'example_app.exe',
                'installerScript': 'installer/example_app.iss',
              },
              'macos': {'appName': 'example_app'},
            }),
          );
        for (final args in [
          ['--list'],
          ['apk', 'dev', '--dry-run'],
          ['web', 'prod', '--dry-run'],
          ['macos', 'dev', '--dry-run'],
          ['windows', 'dev', '--dry-run'],
          ['--help'],
        ]) {
          final inferred = zeroConfig();
          final inferredCode = await run(inferred, args);
          final explicitWorld = zeroConfig()
            ..fs.put(_configFile, explicit.fs.readString(_configFile));
          final explicitCode = await run(explicitWorld, args);
          expect(explicitCode, inferredCode, reason: args.join(' '));
          // --help differs by exactly the first-run hint.
          if (args.first != '--help') {
            final withoutLine = [
              for (final line in inferred.console.outLines)
                if (line != inferredLine) line,
            ].join('\n');
            expect(
              explicitWorld.console.stdoutText,
              withoutLine,
              reason: args.join(' '),
            );
            expect(
              inferred.console.outLines.contains(inferredLine),
              args.first != '--list',
              reason: '${args.join(' ')}: the profile says it was inferred',
            );
            expect(
              explicitWorld.console.outLines.contains(inferredLine),
              isFalse,
              reason: '${args.join(' ')}: a file was read',
            );
            expect(
              explicitWorld.console.stderrText,
              inferred.console.stderrText,
              reason: args.join(' '),
            );
          }
        }
      },
    );

    test('the inferred windows facts drive the windows plan', () async {
      final world = TestWorld(host: HostOs.windows, vars: const {})
        ..fs.deleteFile(r'C:\repo\tool\build\build_config.json')
        ..fs.put(
          r'C:\repo\windows\CMakeLists.txt',
          'set(BINARY_NAME "shop_front")\n',
        )
        ..fs.put(r'C:\repo\installer\shop.iss', '#define MyBuildMode "Release"')
        ..fs.deleteFile(r'C:\repo\installer\example_app.iss');
      await run(world, ['windows', 'dev', '--dry-run']);
      final out = world.console.stdoutText;
      expect(out, contains(r'C:\repo\installer\shop.iss'));
      expect(out, contains('remove old ExampleApp*.exe'));
    });

    test('the inferred macos app name locates the bundle', () async {
      final world = TestWorld()
        ..fs.deleteFile(_configFile)
        ..fs.put(
          '/repo/macos/Runner/Configs/AppInfo.xcconfig',
          'PRODUCT_NAME = Shop Front\n',
        );
      await run(world, ['macos', 'dev', '--dry-run']);
      expect(
        world.console.stdoutText,
        contains('build/macos/Build/Products/Release/Shop Front.app'),
      );
    });
  });

  group('the file wins key by key', () {
    test('one key set, the rest inferred', () async {
      final world = zeroConfig()
        ..fs.put(_configFile, jsonEncode({'slug': 'ShopFront'}));
      expect(
        await run(world, ['apk', 'dev', '--dry-run']),
        0,
        reason: world.console.allText,
      );
      final out = world.console.stdoutText;
      expect(out, contains('dist/android/ShopFront-dev-v1.0.47.apk'));
      expect(out, contains('app          app (Example App)'));
    });

    test('an empty object is a complete config', () async {
      final world = zeroConfig()..fs.put(_configFile, '{}');
      expect(await run(world, ['--list']), 0, reason: world.console.allText);
      expect(
        world.console.stdoutText,
        startsWith('Example App (ExampleApp) version'),
      );
    });

    test('the file value is used even when the project says otherwise', () {
      final world = zeroConfig();
      world.fs.put(
        _configFile,
        jsonEncode({
          'app': 'customer',
          'displayName': 'My Shop',
          'envDir': 'env',
          'windows': {'exe': 'shop.exe'},
          'macos': {'appName': 'Shop'},
        }),
      );
      final config = loadAppConfig(world.env);
      expect(config.app, 'customer');
      expect(config.displayName, 'My Shop');
      expect(config.envDir, 'env');
      expect(config.windowsExe, 'shop.exe');
      expect(config.macosAppName, 'Shop');
      // The key the file leaves out comes from the project.
      expect(config.slug, 'ExampleApp');
      expect(config.installerScript, 'installer/example_app.iss');
    });

    test('a typo is still an error', () async {
      final world = zeroConfig()
        ..fs.put(_configFile, jsonEncode({'slugg': 'X'}));
      expect(await run(world, ['--list']), 1);
      expect(world.console.stderrText, contains('has unknown key "slugg"'));
    });

    test('an invalid value is an error, not silently inferred', () async {
      final world = zeroConfig()..fs.put(_configFile, jsonEncode({'slug': ''}));
      expect(await run(world, ['--list']), 1);
      expect(
        world.console.stderrText,
        contains('"slug" must be a non-empty string'),
      );
    });
  });

  group('windows and macos are needed only when built', () {
    test('a mobile-only project builds apk and web', () async {
      for (final platform in ['apk', 'web']) {
        final world = mobileOnly();
        expect(
          await run(world, [platform, 'dev', '--dry-run']),
          0,
          reason: '$platform: ${world.console.allText}',
        );
      }
    });

    test('--list does not need them either', () async {
      final world = mobileOnly();
      expect(await run(world, ['--list']), 0, reason: world.console.allText);
    });

    test('a config without the sections works for apk', () async {
      final world = TestWorld()
        ..writeConfig({
          'app': 'admin',
          'slug': 'ExampleApp',
          'displayName': 'Example App',
          'envDir': 'config/env',
        })
        ..fs.deleteFile('/repo/installer/example_app.iss');
      expect(
        await run(world, ['apk', 'dev', '--dry-run']),
        0,
        reason: world.console.allText,
      );
    });

    test('windows names both missing facts and how to set them', () async {
      final world = mobileOnly();
      expect(await run(world, ['windows', 'dev', '--dry-run']), 1);
      final err = world.console.stderrText;
      expect(err, contains('Cannot build windows.'));
      expect(err, contains('windows.exe is not set'));
      expect(err, contains('windows/CMakeLists.txt does not exist'));
      expect(err, contains('windows.installerScript is not set'));
      expect(err, contains('installer/ has no .iss file'));
      expect(
        err,
        contains(
          '{"windows":{"exe":"<BINARY_NAME>.exe","installerScript":"installer/<name>.iss"}}',
        ),
      );
      expect(err, contains('dart run flutter_build_tools init'));
      expect(
        err,
        contains(
          '"build_config.json" section of the flutter_build_tools README',
        ),
      );
      // Nothing was planned or built.
      expect(world.console.stdoutText, isEmpty);
      expect(world.runner.streamed, isEmpty);
    });

    test('macos names the missing fact', () async {
      final world = mobileOnly();
      expect(await run(world, ['macos', 'dev', '--dry-run']), 1);
      final err = world.console.stderrText;
      expect(err, contains('Cannot build macos.'));
      expect(err, contains('macos.appName is not set'));
      expect(
        err,
        contains('macos/Runner/Configs/AppInfo.xcconfig does not exist'),
      );
      expect(err, contains('{"macos":{"appName":"<PRODUCT_NAME>"}}'));
      expect(err, isNot(contains('windows.exe')));
    });

    test('a real windows build is refused before anything runs', () async {
      final world = mobileOnly();
      expect(await run(world, ['windows', 'dev']), 1);
      expect(world.runner.streamed, isEmpty);
    });

    test('only the fact that is missing is named', () async {
      final world = mobileOnly()
        ..fs.put('/repo/windows/CMakeLists.txt', 'set(BINARY_NAME "x")\n');
      expect(await run(world, ['windows', 'dev', '--dry-run']), 1);
      final err = world.console.stderrText;
      expect(err, contains('windows.installerScript is not set'));
      expect(err, isNot(contains('windows.exe is not set')));
    });

    test('two installer scripts are named, and none is guessed', () async {
      final world = zeroConfig()..fs.put('/repo/installer/other.iss', '');
      expect(await run(world, ['windows', 'dev', '--dry-run']), 1);
      expect(
        world.console.stderrText,
        contains(
          'installer/ has 2 .iss files (installer/example_app.iss, installer/other.iss)',
        ),
      );
    });

    test('an explicit fact makes the platform buildable', () async {
      final world = mobileOnly()
        ..fs.put(
          _configFile,
          jsonEncode({
            'windows': {'exe': 'x.exe', 'installerScript': 'inst/x.iss'},
          }),
        );
      // The host is macOS, so the dry run ends with the host guard, not with
      // a missing fact.
      expect(await run(world, ['windows', 'dev', '--dry-run']), 1);
      expect(world.console.stderrText, contains('error [host-windows]'));
      expect(world.console.stderrText, isNot(contains('is not set')));
    });

    test('reading a missing fact directly throws the same pointed error', () {
      final config = AppConfig.parse(
        '{}',
        inferred: const ProjectFacts(pubspecName: 'x'),
      );
      expect(
        () => config.windowsExe,
        throwsA(
          isA<BuildException>().having(
            (e) => e.message,
            'message',
            allOf(contains('windows.exe is not set'), contains('init')),
          ),
        ),
      );
    });
  });

  group('first errors point at init and the README', () {
    test('the env files are missing', () async {
      final world = zeroConfig()..fs.deleteFile('/repo/config/env/dev.json');
      expect(await run(world, ['apk', 'dev', '--dry-run']), 1);
      final err = world.console.stderrText;
      expect(err, contains('Env file config/env/dev.json not found.'));
      expect(
        err,
        contains(
          'Run "dart run flutter_build_tools init" to create every missing env file',
        ),
      );
      expect(
        err,
        contains('"Quick start" section of the flutter_build_tools README'),
      );
    });

    test('--list shows the same pointer per environment and exits 1', () async {
      final world = zeroConfig();
      for (final name in ['dev', 'preprod', 'prod', 'local']) {
        world.fs.deleteFile('/repo/config/env/$name.json');
      }
      expect(await run(world, ['--list']), 1);
      expect(
        'init'.allMatches(world.console.stdoutText).length,
        greaterThanOrEqualTo(4),
      );
    });

    test('the installer script named by the config is missing', () async {
      final world = TestWorld(host: HostOs.windows, vars: const {});
      world.fs.deleteFile(r'C:\repo\installer\example_app.iss');
      expect(await run(world, ['windows', 'dev', '--dry-run']), 1);
      final err = world.console.stderrText;
      expect(
        err,
        contains(r'Missing Inno Setup script installer/example_app.iss.'),
      );
      expect(
        err,
        contains('"windows" section of the flutter_build_tools README'),
      );
      expect(err, contains('"windows.installerScript"'));
      expect(err, contains('dart run flutter_build_tools init'));
      expect(err, contains('"Quick start" section of the README'));
    });

    test('a missing pubspec.yaml sends the person to init and the README', () {
      final world = TestWorld()..fs.deleteFile('/repo/pubspec.yaml');
      expect(
        () => loadPubspecVersion(world.env),
        throwsA(
          isA<BuildException>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('pubspec.yaml not found at /repo/pubspec.yaml.'),
              contains('dart run flutter_build_tools init'),
              contains(
                '"Quick start" section of the flutter_build_tools README',
              ),
            ),
          ),
        ),
      );
    });

    test('a pubspec without a name, and no config', () async {
      final world = zeroConfig()
        ..fs.put('/repo/pubspec.yaml', 'version: 1.0.0+1\n');
      expect(await run(world, ['--list']), 1);
      final err = world.console.stderrText;
      expect(err, contains('pubspec.yaml has no top-level "name:"'));
      expect(err, contains('dart run flutter_build_tools init'));
    });

    test(
      'the project docs stay in the message when the config sets them',
      () async {
        final world = TestWorld()..fs.deleteFile('/repo/config/env/dev.json');
        expect(await run(world, ['apk', 'dev', '--dry-run']), 1);
        final err = world.console.stderrText;
        // The 0.1.0 sentence is untouched; the init pointer follows it.
        expect(
          err,
          contains(
            'Env file config/env/dev.json not found. Create it ({"APP_ENV": "dev", "BASE_URL": "https://..."}), see tool/build/README.md. Run "dart run flutter_build_tools init" to create',
          ),
        );
      },
    );
  });

  group('the first-run hint of --help', () {
    test('is absent when the project has its config (0.1.0 text)', () {
      final text = usageText();
      expect(text, isNot(contains('init')));
      expect(text, isNot(contains('First run')));
      expect(usageText(initHint: true), contains('First run in a new project'));
    });

    test('a project that has the file shows the text of 0.1.0', () async {
      final world = TestWorld();
      expect(await run(world, ['--help']), 0);
      expect(world.console.stdoutText, isNot(contains('init')));
    });
  });
}
