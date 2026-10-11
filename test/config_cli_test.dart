// The optional keys of build_config.json, seen from the command line: the
// whole tool against the fake machine. Defaults are covered by cli_test.dart
// (which runs with the same config these tests start from).
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'package:flutter_build_tools/src/cli.dart';
import 'package:flutter_build_tools/src/environment.dart';
import 'package:flutter_build_tools/src/model.dart';
import 'package:flutter_build_tools/src/options.dart';
import 'fakes.dart';

Future<int> run(
  TestWorld world,
  List<String> args, {
  BuildToolOptions? options,
}) =>
    runBuildTool(args, world.env, options: options ?? const BuildToolOptions());

Map<String, Object?> jsonFile(TestWorld world, String path) =>
    jsonDecode(world.fs.readString(path)) as Map<String, Object?>;

/// The fake project's config without [keys].
Map<String, Object?> configWithout(List<String> keys) =>
    Map.of(exampleAppConfig)..removeWhere((key, _) => keys.contains(key));

/// A world whose config declares FEATURE_SET (plain) and ANALYTICS_URL (URL).
TestWorld extrasWorld({String? analytics = 'https://a.example.com'}) {
  final world = TestWorld();
  world.writeConfig({
    ...exampleAppConfig,
    'envFile': {
      'extraKeys': ['FEATURE_SET'],
      'extraUrlKeys': ['ANALYTICS_URL'],
    },
  });
  for (final (env, url) in [
    ('dev', 'https://devexample.example.com/public'),
    ('preprod', 'https://preprod.example.com/public'),
    ('prod', 'https://v1.example.com/public'),
    ('local', 'http://127.0.0.1:8011'),
  ]) {
    world.writeEnvFile(env, {
      'APP_ENV': env,
      'BASE_URL': url,
      'FEATURE_SET': 'pro',
      'ANALYTICS_URL': ?analytics,
    });
  }
  return world;
}

const apkBytes = [1, 2, 3, 4, 5, 6, 7, 8];
const apkOut = '/repo/build/app/outputs/flutter-apk/app-release.apk';
const winVars = {
  'LOCALAPPDATA': r'C:\L',
  'ProgramFiles(x86)': r'C:\P86',
  'ProgramFiles': r'C:\P',
};
const iscc = r'C:\P86\Inno Setup 6\ISCC.exe';

/// A Windows world whose ISCC drops the installer and which has stale ones.
TestWorld windowsWorld(Map<String, Object?> config) {
  final world = TestWorld(host: HostOs.windows, vars: winVars);
  world.writeConfig(config);
  world.fs.put(iscc, 'iscc');
  world.flutterBuilds('windows', {
    r'C:\repo\build\windows\x64\runner\Release\example_app.exe': 'exe',
  });
  world.runner.onStream((s) => s.executable == iscc, (s) {
    final name = s.args
        .firstWhere((a) => a.startsWith('/DMyOutputName='))
        .substring('/DMyOutputName='.length);
    world.fs.put(
      r'C:\repo\build\windows\installers\'
          '$name.exe',
      'installer',
    );
    return 0;
  });
  for (final stale in [
    'Example-Setup-1.0.40.exe',
    'ExampleApp-dev-v1.0.46.exe',
    'ExampleApp-old.EXE',
    'exampleapp-lower.exe',
    'readme.txt',
    'ExampleApp-notes.txt',
  ]) {
    world.fs.put('C:\\repo\\build\\windows\\installers\\$stale', 'old');
  }
  return world;
}

bool installerExists(TestWorld world, String name) =>
    world.fs.fileExists('C:\\repo\\build\\windows\\installers\\$name');

void main() {
  group('--help', () {
    test('is titled with the display name and lists the wrappers', () async {
      final world = TestWorld();
      expect(await run(world, ['--help']), 0);
      final lines = world.console.stdoutText.split('\n');
      expect(
        lines.first,
        'Example App build tool: one command to build an app for any platform and environment.',
      );
      expect(
        lines,
        containsAllInOrder([
          'Usage:',
          '  dart run flutter_build_tools <platform> <env> [mode] [options]',
          '  dart run flutter_build_tools                        (interactive picker, in a terminal)',
          '  scripts/build.sh <platform> <env> [mode] [options]  (macOS/Linux wrapper)',
          '  scripts/build.ps1 <platform> <env> [mode] [options] (Windows wrapper)',
        ]),
      );
      expect(
        world.console.stdoutText,
        contains('(release only, see tool/build/README.md)'),
      );
    });

    test('the notes of the usage lines start in one column', () async {
      final world = TestWorld();
      await run(world, ['--help']);
      final notes = world.console.stdoutText
          .split('\n')
          .where(
            (l) =>
                l.contains('(interactive picker') ||
                l.contains('(macOS/Linux wrapper)') ||
                l.contains('(Windows wrapper)'),
          )
          .toList();
      expect(notes, hasLength(3));
      for (final line in notes) {
        expect(line.indexOf('('), 54, reason: line);
      }
    });

    test('a wrapper path longer than the column still gets a space', () async {
      final world = TestWorld();
      world.writeConfig({
        ...exampleAppConfig,
        'cli': {
          'wrappers': [
            {
              'script': 'tools/scripts/build_release_artifacts.sh',
              'label': 'long wrapper',
            },
          ],
        },
      });
      await run(world, ['--help']);
      expect(
        world.console.stdoutText,
        contains(
          '  tools/scripts/build_release_artifacts.sh <platform> <env> [mode] [options] (long wrapper)',
        ),
      );
    });

    test('without cli.* there are no wrapper lines and no app paths', () async {
      final world = TestWorld();
      world.writeConfig(configWithout(['cli']));
      expect(await run(world, ['--help']), 0);
      final out = world.console.stdoutText;
      expect(out, isNot(contains('scripts/build')));
      expect(out, isNot(contains('tool/build/README.md')));
      expect(
        out,
        contains('(release only, see the flutter_build_tools README)'),
      );
      expect(out, contains('(interactive picker, in a terminal)'));
    });

    test('names the configured env folder', () async {
      final world = TestWorld();
      world.writeConfig({...exampleAppConfig, 'envDir': 'environments'});
      await run(world, ['--help']);
      expect(
        world.console.stdoutText,
        contains(
          'Envs:      dev | preprod | prod | local        (environments/<env>.json)',
        ),
      );
    });

    test('the invocation of the options is the command shown', () async {
      final world = TestWorld();
      expect(
        await run(
          world,
          ['--help'],
          options: const BuildToolOptions(
            invocation: 'dart run tool/build/build.dart',
          ),
        ),
        0,
      );
      final out = world.console.stdoutText;
      expect(
        out,
        contains(
          '  dart run tool/build/build.dart <platform> <env> [mode] [options]',
        ),
      );
      expect(
        out,
        contains(
          '  dart run tool/build/build.dart                      (interactive picker, in a terminal)',
        ),
      );
      expect(out, isNot(contains('flutter_build_tools')));
    });

    group('keeps working when the config cannot be used', () {
      for (final (label, text) in <(String, String?)>[
        ('is missing', null),
        ('is not JSON', '{oops'),
        ('has a typo in a key', '{"slug": "X", "devHostMarker": []}'),
        ('has no windows section', '{"app":"x"}'),
      ]) {
        test('the config $label', () async {
          final world = TestWorld();
          if (text == null) {
            world.fs.deleteFile('/repo/tool/build/build_config.json');
          } else {
            world.fs.put('/repo/tool/build/build_config.json', text);
          }
          expect(
            await run(world, ['--help']),
            0,
            reason: world.console.allText,
          );
          final out = world.console.stdoutText;
          expect(out, startsWith('Flutter build tool: one command'));
          expect(out, contains('Usage:'));
          expect(out, contains('(config/env/<env>.json)'));
          expect(world.console.stderrText, isEmpty);
        });
      }

      test('the config file cannot be read', () async {
        final world = TestWorld();
        final fs = _UnreadableConfigFs()
          ..files.addAll(world.fs.files)
          ..dirs.addAll(world.fs.dirs);
        final env = BuildEnvironment(
          root: '/repo',
          host: HostOs.macos,
          vars: const {},
          fs: fs,
          runner: world.runner,
          console: world.console,
        );
        expect(await runBuildTool(['--help'], env), 0);
        expect(world.console.stdoutText, startsWith('Flutter build tool:'));
      });
    });
  });

  group('the command shown in messages is the invocation of the options', () {
    const options = BuildToolOptions(
      invocation: 'dart run tool/build/build.dart',
    );

    test('usage errors end with an example', () async {
      final world = TestWorld();
      expect(await run(world, ['apk', 'staging'], options: options), 2);
      expect(
        world.console.stderrText,
        contains('Example: dart run tool/build/build.dart apk release preprod'),
      );
    });

    test('--list must stand alone', () async {
      final world = TestWorld();
      expect(await run(world, ['--list', 'apk'], options: options), 2);
      expect(
        world.console.stderrText,
        contains('Run it alone: dart run tool/build/build.dart --list'),
      );
    });

    test('the picker prints the equivalent command', () async {
      final world = TestWorld(interactive: true, inputs: ['2', '2', '1', 'n']);
      await run(world, [], options: options);
      expect(
        world.console.stdoutText,
        contains('Build: dart run tool/build/build.dart web preprod'),
      );
    });

    test('the default is dart run flutter_build_tools', () async {
      final world = TestWorld();
      await run(world, ['apk', 'staging']);
      expect(
        world.console.stderrText,
        contains('Example: dart run flutter_build_tools apk release preprod'),
      );
    });
  });

  group('envFile.extraKeys and envFile.extraUrlKeys', () {
    test('--list shows the extra URL under its env', () async {
      final world = extrasWorld();
      expect(await run(world, ['--list']), 0, reason: world.console.allText);
      final out = world.console.stdoutText;
      expect(
        out.split('\n'),
        contains('           ANALYTICS_URL https://a.example.com'),
      );
      expect(
        out,
        isNot(contains('FEATURE_SET')),
        reason: 'only URLs are listed',
      );
    });

    test('--list shows nothing extra when the env file has none', () async {
      final world = extrasWorld(analytics: null);
      expect(await run(world, ['--list']), 0, reason: world.console.allText);
      expect(world.console.stdoutText, isNot(contains('ANALYTICS_URL')));
    });

    test('the profile lists the extra URL after POS_WEB_URL', () async {
      final world = extrasWorld();
      world.writeEnvFile('dev', {
        'APP_ENV': 'dev',
        'BASE_URL': 'https://devexample.example.com/public',
        'POS_WEB_URL': 'https://devexample.example.com/web_pos',
        'ANALYTICS_URL': 'https://a.example.com',
      });
      expect(
        await run(world, ['web', 'dev', '--dry-run']),
        0,
        reason: world.console.allText,
      );
      final lines = world.console.stdoutText.split('\n');
      final pos = lines.indexWhere((l) => l.startsWith('  POS_WEB_URL  '));
      expect(pos, greaterThan(0));
      expect(
        lines[pos + 1],
        '  ANALYTICS_URL https://a.example.com   [config/env/dev.json]',
      );
      expect(lines[pos + 2], startsWith('  BUILD_SHA    '));
    });

    test('the defines passed to flutter carry both extras', () async {
      final world = extrasWorld();
      Map<String, Object?>? defines;
      world.flutterBuilds(
        'apk',
        {apkOut: apkBytes},
        inspect: (_) => defines = jsonFile(
          world,
          '/repo/build/build_tool/defines-apk-dev.json',
        ),
      );
      expect(
        await run(world, ['apk', 'dev']),
        0,
        reason: world.console.allText,
      );
      expect(defines, {
        'APP_ENV': 'dev',
        'BASE_URL': 'https://devexample.example.com/public',
        'FEATURE_SET': 'pro',
        'ANALYTICS_URL': 'https://a.example.com',
        'BUILD_SHA': 'abc1234',
      });
    });

    test('the manifest names them, and only when configured', () async {
      final world = extrasWorld();
      world.flutterBuilds('apk', {apkOut: apkBytes});
      expect(await run(world, ['apk', 'dev']), 0);
      final manifest = jsonFile(
        world,
        '/repo/dist/android/ExampleApp-dev-v1.0.47.apk.json',
      );
      expect(manifest['extraUrls'], {'ANALYTICS_URL': 'https://a.example.com'});
      expect(manifest['extraDefines'], {'FEATURE_SET': 'pro'});

      final plain = TestWorld();
      plain.flutterBuilds('apk', {apkOut: apkBytes});
      expect(await run(plain, ['apk', 'dev']), 0);
      final plainManifest = jsonFile(
        plain,
        '/repo/dist/android/ExampleApp-dev-v1.0.47.apk.json',
      );
      expect(plainManifest, isNot(contains('extraUrls')));
      expect(plainManifest, isNot(contains('extraDefines')));
      expect(
        plainManifest['posWebUrl'],
        'https://devexample.example.com/web_pos',
      );
    });

    test(
      'an env file without the extras is fine (they are optional)',
      () async {
        final world = extrasWorld(analytics: null);
        world.flutterBuilds('apk', {apkOut: apkBytes});
        expect(
          await run(world, ['apk', 'dev']),
          0,
          reason: world.console.allText,
        );
        final manifest = jsonFile(
          world,
          '/repo/dist/android/ExampleApp-dev-v1.0.47.apk.json',
        );
        expect(manifest, isNot(contains('extraUrls')));
        expect(manifest['extraDefines'], {'FEATURE_SET': 'pro'});
      },
    );

    test('a key the config does not declare is still refused', () async {
      final world = TestWorld();
      world.writeEnvFile('dev', {
        'APP_ENV': 'dev',
        'BASE_URL': 'https://devexample.example.com/public',
        'ANALYTICS_URL': 'https://a.example.com',
      });
      expect(await run(world, ['web', 'dev', '--dry-run']), 1);
      expect(
        world.console.stderrText,
        contains(
          'config/env/dev.json has unknown key "ANALYTICS_URL". Allowed keys: APP_ENV, BASE_URL, POS_WEB_URL.',
        ),
      );
    });

    test('a declared key is accepted and named in the allowed list', () async {
      final world = extrasWorld();
      world.writeEnvFile('dev', {
        'APP_ENV': 'dev',
        'BASE_URL': 'https://devexample.example.com/public',
        'TOKEN': 'x',
      });
      expect(await run(world, ['web', 'dev', '--dry-run']), 1);
      expect(
        world.console.stderrText,
        contains(
          'Allowed keys: APP_ENV, BASE_URL, POS_WEB_URL, FEATURE_SET, ANALYTICS_URL.',
        ),
      );
    });

    test('an extra URL is guarded: http outside local is refused', () async {
      final world = extrasWorld(analytics: 'http://a.example.com');
      expect(await run(world, ['web', 'preprod', '--dry-run']), 1);
      expect(
        world.console.stderrText,
        allOf(
          contains('error [not-https]'),
          contains('ANALYTICS_URL "http://a.example.com"'),
        ),
      );
    });

    test('an extra URL is guarded: prod refuses a dev-looking host', () async {
      final world = extrasWorld(analytics: 'https://devexample.example.com');
      expect(await run(world, ['web', 'prod', '--dry-run']), 1);
      expect(
        world.console.stderrText,
        allOf(contains('error [prod-dev-url]'), contains('prod ANALYTICS_URL')),
      );
    });

    test('--no-build names a changed extra key', () async {
      final world = extrasWorld();
      world.flutterBuilds('apk', {apkOut: apkBytes});
      expect(await run(world, ['apk', 'dev']), 0);
      world.fs.deleteDir('/repo/dist');

      world.writeEnvFile('dev', {
        'APP_ENV': 'dev',
        'BASE_URL': 'https://devexample.example.com/public',
        'FEATURE_SET': 'lite',
        'ANALYTICS_URL': 'https://b.example.com',
      });
      expect(await run(world, ['apk', 'dev', '--no-build']), 1);
      final err = world.console.stderrText;
      expect(err, contains('does not match this profile'));
      expect(
        err,
        contains(
          'ANALYTICS_URL: built https://a.example.com, requested https://b.example.com',
        ),
      );
      expect(err, contains('FEATURE_SET: built pro, requested lite'));
    });

    test('--no-build passes when the extras are unchanged', () async {
      final world = extrasWorld();
      world.flutterBuilds('apk', {apkOut: apkBytes});
      expect(await run(world, ['apk', 'dev']), 0);
      world.fs.deleteDir('/repo/dist');
      expect(
        await run(world, ['apk', 'dev', '--no-build']),
        0,
        reason: world.console.allText,
      );
    });
  });

  group('cli.docs in the missing env file error', () {
    test('points at the configured documentation', () async {
      final world = TestWorld();
      world.fs.deleteFile('/repo/config/env/dev.json');
      expect(await run(world, ['web', 'dev', '--dry-run']), 1);
      expect(
        world.console.stderrText,
        contains(
          'Env file config/env/dev.json not found. Create it ({"APP_ENV": "dev", "BASE_URL": "https://..."}), see tool/build/README.md.',
        ),
      );
    });

    test('points at the package README by default', () async {
      final world = TestWorld();
      world.writeConfig(configWithout(['cli']));
      world.fs.deleteFile('/repo/config/env/dev.json');
      expect(await run(world, ['web', 'dev', '--dry-run']), 1);
      expect(
        world.console.stderrText,
        contains('see the flutter_build_tools README.'),
      );
    });

    test(
      'a custom --env-file that is missing does not mention the docs',
      () async {
        final world = TestWorld();
        expect(
          await run(world, [
            'web',
            'dev',
            '--env-file',
            'nope.json',
            '--dry-run',
          ]),
          1,
        );
        expect(
          world.console.stderrText,
          contains('Env file nope.json not found. Check the --env-file path.'),
        );
      },
    );
  });

  group('devHostMarkers', () {
    test('the configured marker stops a prod build', () async {
      final world = TestWorld();
      world.writeEnvFile('prod', {
        'APP_ENV': 'prod',
        'BASE_URL': 'https://devexample.example.com/public',
      });
      expect(await run(world, ['web', 'prod', '--dry-run']), 1);
      expect(
        world.console.stderrText,
        allOf(
          contains('error [prod-dev-url]'),
          contains('matches "devexample"'),
        ),
      );
    });

    test('without the key the same URL is not recognised as dev', () async {
      final world = TestWorld();
      world.writeConfig(configWithout(['devHostMarkers']));
      world.writeEnvFile('prod', {
        'APP_ENV': 'prod',
        'BASE_URL': 'https://devexample.example.com/public',
      });
      expect(
        await run(world, ['web', 'prod', '--dry-run']),
        0,
        reason: world.console.allText,
      );
      expect(world.console.stderrText, isNot(contains('prod-dev-url')));
    });

    test('the built-in markers always apply', () async {
      final world = TestWorld();
      world.writeConfig(configWithout(['devHostMarkers']));
      world.writeEnvFile('prod', {
        'APP_ENV': 'prod',
        'BASE_URL': 'https://localhost/public',
      });
      expect(await run(world, ['web', 'prod', '--dry-run']), 1);
      expect(world.console.stderrText, contains('matches "localhost"'));
    });

    test('a prod override file is checked against the marker', () async {
      final world = TestWorld();
      world.fs.put(
        '/repo/other.json',
        '{"APP_ENV": "prod", "BASE_URL": "https://devexample.example.com/public"}',
      );
      expect(
        await run(world, [
          'web',
          'prod',
          '--env-file',
          'other.json',
          '--allow-prod-override',
          '--dry-run',
        ]),
        1,
      );
      expect(world.console.stderrText, contains('error [prod-dev-url]'));
    });

    test('the prod-override hint names the configured env folder', () async {
      final world = TestWorld();
      world.writeConfig({...exampleAppConfig, 'envDir': 'environments'});
      for (final env in ['dev', 'preprod', 'prod', 'local']) {
        world.fs.put(
          '/repo/environments/$env.json',
          jsonEncode({
            'APP_ENV': env,
            'BASE_URL': env == 'local'
                ? 'http://127.0.0.1:8011'
                : 'https://$env.example.com/public',
          }),
        );
      }
      expect(
        await run(world, [
          'web',
          'prod',
          '--base-url',
          'https://other.example.com/public',
          '--dry-run',
        ]),
        1,
      );
      expect(
        world.console.stderrText,
        contains('Prefer editing environments/prod.json and committing it.'),
      );
    });
  });

  group('windows.cleanupPrefix', () {
    test(
      'defaults to the slug: only installers of this app are cleared',
      () async {
        final windows = windowsWorld({
          ...exampleAppConfig,
          'windows': {
            'exe': 'example_app.exe',
            'installerScript': 'installer/example_app.iss',
          },
        });
        expect(
          await run(windows, ['exe', 'dev']),
          0,
          reason: windows.console.allText,
        );
        expect(installerExists(windows, 'ExampleApp-dev-v1.0.46.exe'), isFalse);
        expect(installerExists(windows, 'ExampleApp-old.EXE'), isFalse);
        expect(
          installerExists(windows, 'Example-Setup-1.0.40.exe'),
          isTrue,
          reason: 'does not start with the slug',
        );
        expect(
          installerExists(windows, 'exampleapp-lower.exe'),
          isTrue,
          reason: 'the prefix is case-sensitive',
        );
        expect(installerExists(windows, 'readme.txt'), isTrue);
        expect(installerExists(windows, 'ExampleApp-notes.txt'), isTrue);
        expect(
          windows.console.stdoutText,
          contains('==> Remove old installer: ExampleApp-dev-v1.0.46.exe'),
        );
      },
    );

    test('a configured prefix replaces the slug', () async {
      final windows = windowsWorld({
        ...exampleAppConfig,
        'windows': {
          'exe': 'example_app.exe',
          'installerScript': 'installer/example_app.iss',
          'cleanupPrefix': 'Example-Setup',
        },
      });
      expect(
        await run(windows, ['exe', 'dev']),
        0,
        reason: windows.console.allText,
      );
      expect(installerExists(windows, 'Example-Setup-1.0.40.exe'), isFalse);
      expect(
        installerExists(windows, 'ExampleApp-dev-v1.0.46.exe'),
        isTrue,
        reason: 'no longer matches the prefix',
      );
    });

    test('a broad prefix clears every installer of the family', () async {
      final windows = windowsWorld({
        ...exampleAppConfig,
        'windows': {
          'exe': 'example_app.exe',
          'installerScript': 'installer/example_app.iss',
          'cleanupPrefix': 'Example',
        },
      });
      expect(
        await run(windows, ['exe', 'dev']),
        0,
        reason: windows.console.allText,
      );
      expect(installerExists(windows, 'Example-Setup-1.0.40.exe'), isFalse);
      expect(installerExists(windows, 'ExampleApp-dev-v1.0.46.exe'), isFalse);
      expect(installerExists(windows, 'exampleapp-lower.exe'), isTrue);
    });

    test('the dry-run plan names the prefix it would clear', () async {
      final custom = windowsWorld({
        ...exampleAppConfig,
        'windows': {
          'exe': 'example_app.exe',
          'installerScript': 'installer/example_app.iss',
          'cleanupPrefix': 'Example',
        },
      });
      expect(await run(custom, ['exe', 'dev', '--dry-run']), 0);
      expect(
        custom.console.stdoutText,
        contains('remove old Example*.exe in build/windows/installers'),
      );
      expect(installerExists(custom, 'Example-Setup-1.0.40.exe'), isTrue);

      final byDefault = windowsWorld({
        ...exampleAppConfig,
        'windows': {
          'exe': 'example_app.exe',
          'installerScript': 'installer/example_app.iss',
        },
      });
      expect(await run(byDefault, ['exe', 'dev', '--dry-run']), 0);
      expect(
        byDefault.console.stdoutText,
        contains('remove old ExampleApp*.exe in build/windows/installers'),
      );
    });
  });

  group('the macOS staging folder is named after the slug', () {
    test('lower case slug plus _dmg_', () async {
      final world = TestWorld();
      world.writeConfig({
        ...exampleAppConfig,
        'slug': 'AcmeStore',
        'macos': {'appName': 'Acme Store'},
      });
      world.flutterBuilds('macos', {
        '/repo/build/macos/Build/Products/Release/Acme Store.app/Contents/Info.plist':
            'plist',
      });
      world.runner.onStream((s) => s.executable == 'hdiutil', (s) {
        world.fs.put(s.args.last, 'dmg');
        return 0;
      });
      expect(
        await run(world, ['macos', 'dev']),
        0,
        reason: world.console.allText,
      );
      final hdiutil = world.runner.streamed.firstWhere(
        (s) => s.executable == 'hdiutil',
      );
      expect(hdiutil.args, contains('/tmp/acmestore_dmg_0'));
      expect(
        world.fs.fileExists('/repo/dist/macos/AcmeStore-dev-v1.0.47.dmg'),
        isTrue,
      );
    });
  });
}

/// A file system whose `tool/build/build_config.json` exists but cannot be read.
class _UnreadableConfigFs extends MemoryFs {
  @override
  String readString(String path) {
    if (path.endsWith('build_config.json')) {
      throw FileSystemException('Permission denied', path);
    }
    return super.readString(path);
  }
}
