// The init command: what it writes, what it never overwrites, and that the
// project builds right after it.
import 'dart:convert';
import 'dart:io' show FileSystemException;

import 'package:test/test.dart';

import 'package:flutter_build_tools/src/cli.dart';
import 'package:flutter_build_tools/src/config.dart';
import 'package:flutter_build_tools/src/init.dart';
import 'package:flutter_build_tools/src/model.dart';
import 'package:flutter_build_tools/src/profile.dart';
import 'package:flutter_build_tools/src/runner.dart';
import 'fakes.dart';

Future<int> run(TestWorld world, List<String> args) =>
    runBuildTool(args, world.env);

/// A Flutter-like project that has nothing the tool needs but a pubspec: no
/// tool/, no config/, no scripts/. [lib] adds lib/ files.
TestWorld bare({
  bool templates = true,
  List<String> lib = const [],
  HostOs host = HostOs.macos,
}) {
  final world = TestWorld(host: host);
  final fs = world.fs;
  for (final path in [
    'tool/build/build_config.json',
    'config/env/dev.json',
    'config/env/preprod.json',
    'config/env/prod.json',
    'config/env/local.json',
    'installer/example_app.iss',
    'web/index.html',
  ]) {
    fs.deleteFile(world.abs(path));
  }
  fs.dirs.removeWhere((d) => d.contains('config') || d.contains('tool'));
  if (templates) {
    fs
      ..put(
        world.abs('windows/CMakeLists.txt'),
        'set(BINARY_NAME "example_app")\n',
      )
      ..put(
        world.abs('macos/Runner/Configs/AppInfo.xcconfig'),
        'PRODUCT_NAME = example_app\n',
      )
      ..put(world.abs('installer/example_app.iss'), '[Setup]\n');
  }
  for (final file in lib) {
    fs.put(world.abs(file), '// $file\n');
  }
  // chmod works.
  world.runner.onCapture((s) => s.executable == 'chmod', (_) {
    return const CapturedProcess(0, '', '');
  });
  return world;
}

/// The line `init` prints for [verb] and [path] (the verb column is padded).
String row(String verb, String path) => '  ${verb.padRight(15)} $path';

Map<String, Object?> json(TestWorld world, String path) =>
    jsonDecode(world.fs.readString(world.abs(path))) as Map<String, Object?>;

List<String> chmodCalls(TestWorld world) => [
  for (final call in world.runner.calls)
    if (call.executable == 'chmod') call.args.join(' '),
];

void main() {
  group('a plain init', () {
    late TestWorld world;
    late int code;

    setUp(() async {
      world = bare();
      code = await run(world, ['init']);
    });

    test('exits 0 and lists what it created', () {
      expect(code, 0, reason: world.console.allText);
      final out = world.console.stdoutText;
      expect(out, startsWith('init: Example App (example_app)'));
      for (final path in [
        'tool/build/build_config.json',
        'config/env/dev.json',
        'config/env/preprod.json',
        'config/env/prod.json',
        'config/env/local.json',
        'scripts/build.sh',
        'scripts/build.ps1',
        'lib/app_env.dart',
      ]) {
        expect(out, contains(row('created', path)));
        expect(world.fs.fileExists(world.abs(path)), isTrue, reason: path);
      }
      expect(out, contains('8 created, 0 overwritten, 0 skipped.'));
      expect(world.console.stderrText, isEmpty);
    });

    test('the config holds the inferred facts, as explicit values', () {
      final config = json(world, 'tool/build/build_config.json');
      expect(
        config,
        {
          r'$comment': isA<String>(),
          'app': 'app',
          'slug': 'ExampleApp',
          'displayName': 'Example App',
          'envDir': 'config/env',
          'windows': {
            'exe': 'example_app.exe',
            'installerScript': 'installer/example_app.iss',
          },
          'macos': {'appName': 'example_app'},
        }.map((k, v) => MapEntry(k, v)),
      );
    });

    test('the config parses and equals what is inferred', () {
      final written = AppConfig.parse(
        world.fs.readString(world.abs('tool/build/build_config.json')),
      );
      world.fs.deleteFile(world.abs('tool/build/build_config.json'));
      final inferred = loadAppConfig(world.env);
      expect(written.app, inferred.app);
      expect(written.slug, inferred.slug);
      expect(written.displayName, inferred.displayName);
      expect(written.envDir, inferred.envDir);
      expect(written.windowsExe, inferred.windowsExe);
      expect(written.installerScript, inferred.installerScript);
      expect(written.macosAppName, inferred.macosAppName);
    });

    test('the env files carry placeholders, local is plain http', () {
      expect(json(world, 'config/env/dev.json'), {
        'APP_ENV': 'dev',
        'BASE_URL': 'https://dev.replace-me.invalid',
      });
      expect(json(world, 'config/env/preprod.json'), {
        'APP_ENV': 'preprod',
        'BASE_URL': 'https://preprod.replace-me.invalid',
      });
      expect(json(world, 'config/env/prod.json'), {
        'APP_ENV': 'prod',
        'BASE_URL': 'https://prod.replace-me.invalid',
      });
      expect(json(world, 'config/env/local.json'), {
        'APP_ENV': 'local',
        'BASE_URL': 'http://127.0.0.1',
      });
      expect(
        world.fs.readString(world.abs('config/env/dev.json')),
        endsWith('}\n'),
      );
    });

    test('the wrappers are thin and the shell one is made executable', () {
      final sh = world.fs.readString(world.abs('scripts/build.sh'));
      expect(sh, startsWith('#!/usr/bin/env bash\n'));
      expect(sh, contains('exec dart run flutter_build_tools "\$@"'));
      expect(sh, contains(r'cd "$(dirname "${BASH_SOURCE[0]}")/.."'));
      final ps1 = world.fs.readString(world.abs('scripts/build.ps1'));
      expect(ps1, contains('dart run flutter_build_tools @args'));
      expect(ps1, contains(r'exit $LASTEXITCODE'));
      expect(chmodCalls(world), ['+x /repo/scripts/build.sh']);
    });

    test('only chmod and a read-only git query were run, and main.dart is '
        'not touched', () {
      final calls = [
        for (final call in world.runner.calls)
          '${call.executable} ${call.args.first}',
      ];
      expect(calls, ['chmod +x', 'git check-ignore']);
      expect(world.fs.fileExists(world.abs('lib/main.dart')), isFalse);
    });

    test('prints what it inferred and the next steps', () {
      final out = world.console.stdoutText;
      expect(out, contains('Inferred from the project:'));
      expect(out, contains(RegExp(r'slug +ExampleApp +pubspec name')));
      expect(
        out,
        contains(
          RegExp(r'windows\.exe +example_app\.exe +windows/CMakeLists\.txt'),
        ),
      );
      expect(out, contains('Next steps'));
      expect(out, contains('1. Edit BASE_URL in config/env/dev.json'));
      expect(out, contains('2. dart run flutter_build_tools --list'));
      expect(
        out,
        contains('3. dart run flutter_build_tools apk dev --dry-run'),
      );
      expect(out, isNot(contains('Not inferred')));
    });

    test('the project builds right after it: dev and preprod work', () async {
      for (final env in ['dev', 'preprod']) {
        final after = bare();
        await run(after, ['init']);
        expect(
          await run(after, ['apk', env, '--dry-run']),
          0,
          reason: after.console.allText,
        );
        expect(
          after.console.stderrText,
          contains(
            'warning [placeholder-url]: BASE_URL "https://$env.replace-me.invalid" is still a placeholder',
          ),
        );
      }
    });

    test('prod stops on the placeholder with a clear message', () async {
      final after = bare();
      await run(after, ['init']);
      expect(
        await run(after, ['web', 'prod', '--dry-run', '--allow-dirty']),
        1,
      );
      final err = after.console.stderrText;
      expect(
        err,
        contains(
          'error [placeholder-url]: prod BASE_URL "https://prod.replace-me.invalid" is still a placeholder',
        ),
      );
      expect(err, contains('config/env/prod.json'));
      expect(err, isNot(contains('looks like a dev/local server')));
    });

    test('--list marks the placeholders and not local', () async {
      final after = bare();
      await run(after, ['init']);
      expect(await run(after, ['--list']), 0);
      final out = after.console.stdoutText;
      expect(
        out,
        contains(
          'dev      BASE_URL     https://dev.replace-me.invalid   (placeholder: edit config/env/dev.json)',
        ),
      );
      expect(out, contains('local    BASE_URL     http://127.0.0.1'));
      expect(out, isNot(contains('http://127.0.0.1   (placeholder')));
    });

    test('once the URLs are edited prod builds', () async {
      final after = bare();
      await run(after, ['init']);
      after.fs.put(
        after.abs('config/env/prod.json'),
        jsonEncode({'APP_ENV': 'prod', 'BASE_URL': 'https://api.shop.test'}),
      );
      expect(
        await run(after, ['web', 'prod', '--dry-run']),
        0,
        reason: after.console.allText,
      );
    });
  });

  group('running it again', () {
    test('overwrites nothing and says so', () async {
      final world = bare();
      await run(world, ['init']);
      final before = world.fs.snapshot();
      world.console.outLines.clear();
      expect(await run(world, ['init']), 0);
      expect(world.fs.snapshot(), before);
      final out = world.console.stdoutText;
      expect(
        out,
        contains(
          row(
            'skipped',
            'tool/build/build_config.json (exists; --force overwrites it)',
          ),
        ),
      );
      expect(
        out,
        contains('Nothing to do: every file already exists (8 skipped).'),
      );
    });

    test('keeps a URL the project edited', () async {
      final world = bare();
      await run(world, ['init']);
      world.fs.put(
        world.abs('config/env/prod.json'),
        jsonEncode({'APP_ENV': 'prod', 'BASE_URL': 'https://api.shop.test'}),
      );
      await run(world, ['init']);
      expect(
        json(world, 'config/env/prod.json')['BASE_URL'],
        'https://api.shop.test',
      );
    });

    test(
      'next steps name only the env files that are still placeholders',
      () async {
        final world = bare();
        await run(world, ['init']);
        expect(
          world.console.stdoutText,
          contains(
            '1. Edit BASE_URL in config/env/dev.json, config/env/preprod.json, config/env/prod.json (',
          ),
        );
        for (final env in ['dev', 'prod']) {
          world.fs.put(
            world.abs('config/env/$env.json'),
            jsonEncode({'APP_ENV': env, 'BASE_URL': 'https://$env.shop.test'}),
          );
        }
        world.console.outLines.clear();
        await run(world, ['init']);
        var out = world.console.stdoutText;
        expect(out, contains('1. Edit BASE_URL in config/env/preprod.json ('));
        expect(out, isNot(contains('config/env/dev.json, ')));
        world.fs.put(
          world.abs('config/env/preprod.json'),
          jsonEncode({'APP_ENV': 'preprod', 'BASE_URL': 'https://p.shop.test'}),
        );
        world.console.outLines.clear();
        await run(world, ['init']);
        out = world.console.stdoutText;
        expect(out, isNot(contains('Edit BASE_URL')));
        expect(out, contains('1. dart run flutter_build_tools --list'));
      },
    );

    test('creates only what is missing', () async {
      final world = bare();
      await run(world, ['init']);
      world.fs.deleteFile(world.abs('config/env/preprod.json'));
      world.fs.put(world.abs('scripts/build.sh'), '#!/bin/sh\necho mine\n');
      world.console.outLines.clear();
      expect(await run(world, ['init']), 0);
      final out = world.console.stdoutText;
      expect(out, contains(row('created', 'config/env/preprod.json')));
      expect(out, contains(row('skipped', 'scripts/build.sh (exists')));
      expect(
        world.fs.readString(world.abs('scripts/build.sh')),
        contains('echo mine'),
      );
      expect(out, contains('1 created, 0 overwritten, 7 skipped.'));
    });
  });

  group('--force', () {
    test('overwrites, and reports the URL it replaced', () async {
      final world = bare();
      await run(world, ['init']);
      world.fs.put(
        world.abs('config/env/prod.json'),
        jsonEncode({'APP_ENV': 'prod', 'BASE_URL': 'https://api.shop.test'}),
      );
      world.fs.put(world.abs('scripts/build.sh'), 'mine');
      world.console.outLines.clear();
      expect(await run(world, ['init', '--force']), 0);
      final out = world.console.stdoutText;
      expect(
        out,
        contains(
          row(
            'overwrote',
            'config/env/prod.json (BASE_URL was https://api.shop.test)',
          ),
        ),
      );
      // local.json already said http://127.0.0.1: nothing was lost, no note.
      expect(out, contains(row('overwrote', 'config/env/local.json\n')));
      expect(out, contains(row('overwrote', 'scripts/build.sh')));
      // init's own AppEnv text is replaced without a note.
      expect(out, contains(row('overwrote', 'lib/app_env.dart\n')));
      expect(out, contains('0 created, 8 overwritten, 0 skipped.'));
      expect(
        json(world, 'config/env/prod.json')['BASE_URL'],
        'https://prod.replace-me.invalid',
      );
      expect(
        world.fs.readString(world.abs('scripts/build.sh')),
        startsWith('#!/usr/bin/env bash'),
      );
    });

    test('keeps what the project set in its config', () async {
      final world = bare();
      world.fs.put(
        world.abs('tool/build/build_config.json'),
        jsonEncode({
          'slug': 'ShopFront',
          'envDir': 'env',
          'devHostMarkers': ['shop-dev'],
          'windows': {'cleanupPrefix': 'Shop'},
          'cli': {'docs': 'docs/build.md'},
          r'$note': 'kept',
        }),
      );
      expect(
        await run(world, ['init', '--force']),
        0,
        reason: world.console.allText,
      );
      final config = json(world, 'tool/build/build_config.json');
      expect(config['slug'], 'ShopFront');
      expect(config['envDir'], 'env');
      expect(config['devHostMarkers'], ['shop-dev']);
      expect(config['cli'], {'docs': 'docs/build.md'});
      expect(config[r'$note'], 'kept');
      expect(config['windows'], {
        'exe': 'example_app.exe',
        'installerScript': 'installer/example_app.iss',
        'cleanupPrefix': 'Shop',
      });
      // And the env files went to the folder the config names.
      expect(world.fs.fileExists(world.abs('env/dev.json')), isTrue);
      expect(world.fs.fileExists(world.abs('config/env/dev.json')), isFalse);
    });

    test(
      'an env file keeps POS_WEB_URL and the project\'s own keys, only APP_ENV and BASE_URL are reset',
      () async {
        final world = bare();
        world.fs.put(
          world.abs('tool/build/build_config.json'),
          jsonEncode({
            'envFile': {
              'extraKeys': ['USE_DUMMY'],
              'extraUrlKeys': ['SHOP_URL'],
            },
          }),
        );
        world.fs.put(
          world.abs('config/env/prod.json'),
          jsonEncode({
            'APP_ENV': 'prod',
            'BASE_URL': 'https://api.shop.test',
            'POS_WEB_URL': 'https://pos.shop.test',
            'USE_DUMMY': 'false',
            'SHOP_URL': 'https://shop.shop.test',
          }),
        );
        world.fs.put(
          world.abs('config/env/local.json'),
          jsonEncode({
            'APP_ENV': 'local',
            'BASE_URL': 'http://127.0.0.1:8011',
            'POS_WEB_URL': 'http://127.0.0.1:8011/web_pos',
          }),
        );
        expect(
          await run(world, ['init', '--force']),
          0,
          reason: world.console.allText,
        );
        expect(json(world, 'config/env/prod.json'), {
          'APP_ENV': 'prod',
          'BASE_URL': 'https://prod.replace-me.invalid',
          'POS_WEB_URL': 'https://pos.shop.test',
          'USE_DUMMY': 'false',
          'SHOP_URL': 'https://shop.shop.test',
        });
        expect(json(world, 'config/env/local.json'), {
          'APP_ENV': 'local',
          'BASE_URL': 'http://127.0.0.1',
          'POS_WEB_URL': 'http://127.0.0.1:8011/web_pos',
        });
        final out = world.console.stdoutText;
        expect(
          out,
          contains(
            row(
              'overwrote',
              'config/env/prod.json (BASE_URL was https://api.shop.test)',
            ),
          ),
        );
        expect(
          out,
          contains(
            row(
              'overwrote',
              'config/env/local.json (BASE_URL was http://127.0.0.1:8011)',
            ),
          ),
        );
        // Nothing else is lost: the file is still accepted and keeps the URL.
        expect(await run(world, ['--list']), 0, reason: world.console.allText);
        expect(
          world.console.stdoutText,
          contains('POS_WEB_URL  https://pos.shop.test'),
        );
      },
    );

    test(
      'a script that is not init\'s own text is reported as replaced',
      () async {
        final world = bare();
        await run(world, ['init']);
        world.fs.put(
          world.abs('scripts/build.sh'),
          '#!/usr/bin/env bash\nexec dart run tool/build/build.dart "\$@"\n',
        );
        world.console.outLines.clear();
        expect(await run(world, ['init', '--force']), 0);
        final out = world.console.stdoutText;
        expect(
          out,
          contains(
            row('overwrote', 'scripts/build.sh (custom content replaced)'),
          ),
        );
        // build.ps1 held init's own text: nothing to say. Nor for the config
        // (its keys are kept) or the env files (their keys are kept).
        expect(
          out,
          contains(RegExp(r'overwrote +scripts/build\.ps1$', multiLine: true)),
        );
        expect(out, isNot(contains('build_config.json (')));
        expect(out, isNot(contains('config/env/dev.json (')));
      },
    );

    test('an env file that is not JSON is replaced, and it says so', () async {
      final world = bare();
      await run(world, ['init']);
      world.fs.put(world.abs('config/env/dev.json'), '{oops');
      world.console.outLines.clear();
      expect(await run(world, ['init', '--force']), 0);
      expect(
        world.console.stdoutText,
        contains(
          row('overwrote', 'config/env/dev.json (custom content replaced)'),
        ),
      );
      expect(json(world, 'config/env/dev.json'), {
        'APP_ENV': 'dev',
        'BASE_URL': 'https://dev.replace-me.invalid',
      });
    });

    test(
      'replaces a config that is not JSON, which init cannot read',
      () async {
        final world = bare();
        world.fs.put(world.abs('tool/build/build_config.json'), '{oops');
        expect(await run(world, ['init']), 1);
        expect(
          world.console.stderrText,
          contains('exists but is not a JSON object'),
        );
        expect(
          world.fs.readString(world.abs('tool/build/build_config.json')),
          '{oops',
        );
        expect(await run(world, ['init', '--force']), 0);
        expect(
          json(world, 'tool/build/build_config.json')['slug'],
          'ExampleApp',
        );
      },
    );
  });

  group('--dry-run', () {
    test('writes nothing and lists what it would write', () async {
      final world = bare();
      final before = world.fs.snapshot();
      expect(await run(world, ['init', '--dry-run']), 0);
      expect(world.fs.snapshot(), before);
      expect(chmodCalls(world), isEmpty);
      final out = world.console.stdoutText;
      expect(
        out,
        startsWith('init (dry run: nothing is written): Example App'),
      );
      expect(
        out,
        contains(row('would create', 'tool/build/build_config.json')),
      );
      expect(out, contains(row('would create', 'lib/app_env.dart')));
      expect(out, contains('8 file(s) would be written, 0 skipped.'));
    });

    test(
      'with --force says what it would replace, as the real run does',
      () async {
        final world = bare();
        await run(world, ['init']);
        world.fs.put(
          world.abs('config/env/prod.json'),
          jsonEncode({
            'APP_ENV': 'prod',
            'BASE_URL': 'https://api.shop.test',
            'POS_WEB_URL': 'https://pos.shop.test',
          }),
        );
        world.fs.put(world.abs('scripts/build.sh'), 'mine');
        world.console.outLines.clear();
        final before = world.fs.snapshot();
        expect(await run(world, ['init', '--dry-run', '--force']), 0);
        expect(world.fs.snapshot(), before);
        final out = world.console.stdoutText;
        expect(
          out,
          contains(
            row(
              'would overwrite',
              'config/env/prod.json (BASE_URL was https://api.shop.test)',
            ),
          ),
        );
        expect(
          out,
          contains(
            row(
              'would overwrite',
              'scripts/build.sh (custom content replaced)',
            ),
          ),
        );
      },
    );

    test('with --force says which files it would overwrite', () async {
      final world = bare();
      await run(world, ['init']);
      world.console.outLines.clear();
      final before = world.fs.snapshot();
      expect(await run(world, ['init', '--dry-run', '--force']), 0);
      expect(world.fs.snapshot(), before);
      expect(
        world.console.stdoutText,
        contains('would overwrite config/env/dev.json'),
      );
    });
  });

  group('AppEnv', () {
    group('by default', () {
      test(
        'is written to lib/app_env.dart when lib/config does not exist',
        () async {
          final world = bare(lib: ['lib/main.dart']);
          expect(await run(world, ['init']), 0, reason: world.console.allText);
          final source = world.fs.readString(world.abs('lib/app_env.dart'));
          expect(source, contains("String.fromEnvironment('APP_ENV')"));
          expect(source, contains("String.fromEnvironment('BASE_URL')"));
          expect(source, contains("String.fromEnvironment('BUILD_SHA')"));
          expect(source, contains('class AppEnv'));
          expect(
            world.fs.fileExists(world.abs('lib/config/app_env.dart')),
            isFalse,
          );
          expect(
            world.console.stdoutText,
            contains(row('created', 'lib/app_env.dart')),
          );
        },
      );

      test(
        'is written to lib/config/app_env.dart when lib/config exists',
        () async {
          final world = bare(lib: ['lib/main.dart', 'lib/config/theme.dart']);
          expect(await run(world, ['init']), 0);
          expect(
            world.fs.fileExists(world.abs('lib/config/app_env.dart')),
            isTrue,
          );
          expect(world.fs.fileExists(world.abs('lib/app_env.dart')), isFalse);
        },
      );

      test('has the members apps read and a startup guard for release', () async {
        final world = bare();
        await run(world, ['init']);
        final source = world.fs.readString(world.abs('lib/app_env.dart'));
        // The members of the 0.2.0 class, unchanged.
        expect(
          source,
          contains(
            "static const String name = String.fromEnvironment('APP_ENV');",
          ),
        );
        expect(
          source,
          contains(
            "static const String baseUrl = String.fromEnvironment('BASE_URL');",
          ),
        );
        expect(
          source,
          contains(
            "static const String buildSha = String.fromEnvironment('BUILD_SHA');",
          ),
        );
        expect(
          source,
          contains(r"static String get summary => '$name $baseUrl $buildSha';"),
        );
        // The guard: release only, StateError, says how to build.
        expect(
          source,
          contains(
            "import 'package:flutter/foundation.dart' show kReleaseMode;",
          ),
        );
        expect(source, contains('static void ensureValid() {'));
        expect(source, contains('if (!kReleaseMode) return;'));
        expect(source, contains('throw StateError('));
        expect(source, contains('name.isEmpty'));
        expect(source, contains('baseUrl.isEmpty'));
        expect(
          source,
          contains('"dart run flutter_build_tools <platform> <env>"'),
        );
        expect(
          source,
          contains('--dart-define-from-file=config/env/<env>.json'),
        );
        // A plain `flutter run` keeps working, and the comment says how to
        // pass the env file.
        expect(
          source,
          contains('flutter run --dart-define-from-file=config/env/dev.json'),
        );
        expect(source, isNot(contains('@ENV_DIR@')));
      });

      test('names the env folder of the config in the file', () async {
        final world = bare();
        world.fs.put(
          world.abs('tool/build/build_config.json'),
          jsonEncode({'envDir': 'env'}),
        );
        await run(world, ['init']);
        final source = world.fs.readString(world.abs('lib/app_env.dart'));
        expect(source, contains('--dart-define-from-file=env/<env>.json'));
        expect(source, contains('--dart-define-from-file=env/dev.json'));
        expect(source, isNot(contains('config/env')));
      });

      for (final (label, dir, literal) in <(String, String, String)>[
        ('a quote', "cfg/it's", r"cfg/it\'s"),
        ('a dollar', r'cfg/$env', r'cfg/\$env'),
        ('a dollar and braces', r'cfg/a${b}c', r'cfg/a\${b}c'),
        ('a backslash', r'cfg\new', r'cfg\\new'),
      ]) {
        test('a folder name with $label is a valid literal', () async {
          final world = bare();
          world.fs.put(
            world.abs('tool/build/build_config.json'),
            jsonEncode({'envDir': dir}),
          );
          expect(await run(world, ['init']), 0, reason: world.console.allText);
          final source = world.fs.readString(world.abs('lib/app_env.dart'));
          // The string says the folder as it is; the comment shows it as is.
          expect(
            source,
            contains(
              "'--dart-define-from-file=$literal/<env>.json to flutter build.'",
            ),
          );
          expect(
            source,
            contains('`flutter run --dart-define-from-file=$dir/dev.json`'),
          );
          expect(source, isNot(contains('@ENV_DIR')));
        });
      }

      test(
        'a line break in the folder name does not end the comment',
        () async {
          final world = bare();
          world.fs.put(
            world.abs('tool/build/build_config.json'),
            jsonEncode({'envDir': 'cfg\nenv'}),
          );
          expect(await run(world, ['init']), 0, reason: world.console.allText);
          final source = world.fs.readString(world.abs('lib/app_env.dart'));
          expect(
            source,
            contains(r'--dart-define-from-file=cfg\nenv/<env>.json'),
          );
          expect(
            source,
            contains('`flutter run --dart-define-from-file=cfg env/dev.json`'),
          );
          for (final line in source.split('\n')) {
            expect(
              line.startsWith('///') ||
                  !line.contains('--dart-define-from-file') ||
                  line.trimLeft().startsWith("'"),
              isTrue,
              reason: line,
            );
          }
        },
      );

      test('prints the main.dart lines and never edits main.dart', () async {
        final world = bare(lib: ['lib/main.dart', 'lib/config/theme.dart']);
        final mainBefore = world.fs.readString(world.abs('lib/main.dart'));
        await run(world, ['init']);
        expect(world.fs.readString(world.abs('lib/main.dart')), mainBefore);
        final out = world.console.stdoutText;
        expect(out, contains('init never edits lib/main.dart'));
        expect(
          out,
          contains("import 'package:example_app/config/app_env.dart';"),
        );
        expect(out, contains('    AppEnv.ensureValid();'));
        expect(out, contains('    debugPrint(AppEnv.summary);'));
        expect(out, isNot(contains('note: lib/config/app_env.dart')));
        // The guard comes before the log line, both after the import.
        expect(
          out.indexOf('AppEnv.ensureValid();'),
          lessThan(out.indexOf('debugPrint(AppEnv.summary);')),
        );
      });

      test(
        'a dry run lists it, writes nothing and still shows the lines',
        () async {
          final world = bare(lib: ['lib/config/theme.dart']);
          final before = world.fs.snapshot();
          expect(await run(world, ['init', '--dry-run']), 0);
          expect(world.fs.snapshot(), before);
          final out = world.console.stdoutText;
          expect(out, contains(row('would create', 'lib/config/app_env.dart')));
          expect(
            out,
            contains("import 'package:example_app/config/app_env.dart';"),
          );
          expect(out, contains('AppEnv.ensureValid();'));
        },
      );
    });

    group('--app-env', () {
      test('is the default: the same files and the same output', () async {
        final plain = bare(lib: ['lib/main.dart']);
        final flagged = bare(lib: ['lib/main.dart']);
        expect(await run(plain, ['init']), 0);
        expect(await run(flagged, ['init', '--app-env']), 0);
        expect(flagged.fs.snapshot(), plain.fs.snapshot());
        expect(flagged.console.stdoutText, plain.console.stdoutText);
        expect(flagged.console.stderrText, plain.console.stderrText);
      });

      test('with --dry-run and --force is the same as without it', () async {
        for (final extra in [
          ['--dry-run'],
          ['--force', '--dry-run'],
        ]) {
          final plain = bare(lib: ['lib/main.dart']);
          final flagged = bare(lib: ['lib/main.dart']);
          expect(await run(plain, ['init', ...extra]), 0);
          expect(await run(flagged, ['init', '--app-env', ...extra]), 0);
          expect(
            flagged.console.stdoutText,
            plain.console.stdoutText,
            reason: extra.join(' '),
          );
        }
      });
    });

    group('--no-app-env', () {
      test('writes no AppEnv and prints no main.dart lines', () async {
        final world = bare(lib: ['lib/main.dart', 'lib/config/theme.dart']);
        expect(
          await run(world, ['init', '--no-app-env']),
          0,
          reason: world.console.allText,
        );
        expect(world.fs.fileExists(world.abs('lib/app_env.dart')), isFalse);
        expect(
          world.fs.fileExists(world.abs('lib/config/app_env.dart')),
          isFalse,
        );
        final out = world.console.stdoutText;
        expect(out, isNot(contains('AppEnv')));
        expect(out, isNot(contains('app_env')));
        expect(out, isNot(contains('debugPrint')));
        expect(out, isNot(contains('lib/main.dart')));
        expect(out, contains('7 created, 0 overwritten, 0 skipped.'));
      });

      test('a dry run lists no AppEnv either', () async {
        final world = bare();
        expect(await run(world, ['init', '--no-app-env', '--dry-run']), 0);
        final out = world.console.stdoutText;
        expect(out, isNot(contains('app_env')));
        expect(out, contains('7 file(s) would be written, 0 skipped.'));
      });

      test(
        'leaves an AppEnv that exists alone and says nothing of it',
        () async {
          final world = bare(lib: ['lib/app_env.dart']);
          final before = world.fs.readString(world.abs('lib/app_env.dart'));
          expect(await run(world, ['init', '--no-app-env', '--force']), 0);
          expect(world.fs.readString(world.abs('lib/app_env.dart')), before);
          final out = world.console.stdoutText;
          expect(out, isNot(contains('app_env')));
          expect(out, isNot(contains('AppEnv')));
        },
      );

      test('does not look at lib/ for a class of that name', () async {
        final world = bare();
        final off = ListCountingFs();
        expect(
          await runBuildTool(['init', '--no-app-env'], world.envOn(off)),
          0,
        );
        expect(off.listed, isNot(contains('/repo/lib')));
        // The control: without the flag the folder is looked at.
        final on = ListCountingFs();
        expect(await runBuildTool(['init'], bare().envOn(on)), 0);
        expect(on.listed, contains('/repo/lib'));
      });

      test(
        'with --app-env is a usage error (exit 2) and writes nothing',
        () async {
          for (final args in [
            ['init', '--app-env', '--no-app-env'],
            ['init', '--no-app-env', '--app-env', '--dry-run'],
          ]) {
            final world = bare();
            final before = world.fs.snapshot();
            expect(await run(world, args), 2, reason: args.join(' '));
            expect(
              world.console.stderrText,
              contains('--app-env and --no-app-env contradict each other'),
            );
            expect(world.fs.snapshot(), before);
          }
        },
      );
    });

    group('one that exists', () {
      test(
        'is not written again, also when it lives in the other place',
        () async {
          final world = bare(lib: ['lib/config/theme.dart'])
            ..fs.put(world0('lib/app_env.dart'), await initsOwnText());
          expect(await run(world, ['init']), 0);
          expect(
            world.fs.fileExists(world.abs('lib/config/app_env.dart')),
            isFalse,
          );
          expect(
            world.console.stdoutText,
            contains(
              'skipped         lib/app_env.dart (exists; --force overwrites it)',
            ),
          );
        },
      );

      test(
        'the main.dart import names the copy that exists in the other place',
        () async {
          final world = bare(lib: ['lib/config/theme.dart'])
            ..fs.put(world0('lib/app_env.dart'), await initsOwnText());
          expect(await run(world, ['init']), 0);
          final out = world.console.stdoutText;
          expect(out, contains("import 'package:example_app/app_env.dart';"));
          expect(out, isNot(contains('config/app_env.dart')));
        },
      );

      test(
        '--force replaces the copy that exists, it never adds a second class',
        () async {
          final world = bare(lib: ['lib/config/theme.dart'])
            ..fs.put(world0('lib/app_env.dart'), _appEnv020);
          expect(await run(world, ['init', '--force']), 0);
          expect(
            world.fs.fileExists(world.abs('lib/config/app_env.dart')),
            isFalse,
          );
          expect(
            world.fs.readString(world.abs('lib/app_env.dart')),
            contains('static void ensureValid()'),
          );
          final out = world.console.stdoutText;
          expect(out, contains(row('overwrote', 'lib/app_env.dart\n')));
          expect(out, contains("import 'package:example_app/app_env.dart';"));
        },
      );

      test(
        'the copy in lib/config/ is the one used when lib/ has none',
        () async {
          final world = bare()
            ..fs.put(world0('lib/config/app_env.dart'), await initsOwnText());
          expect(await run(world, ['init']), 0);
          expect(world.fs.fileExists(world.abs('lib/app_env.dart')), isFalse);
          expect(
            world.console.stdoutText,
            contains("import 'package:example_app/config/app_env.dart';"),
          );
        },
      );

      test('init\'s own text is kept, and the lines are shown again', () async {
        final world = bare(lib: ['lib/main.dart']);
        await run(world, ['init']);
        final before = world.fs.snapshot();
        world.console.outLines.clear();
        expect(await run(world, ['init']), 0);
        expect(world.fs.snapshot(), before);
        final out = world.console.stdoutText;
        expect(
          out,
          contains(
            'skipped         lib/app_env.dart (exists; --force overwrites it)',
          ),
        );
        expect(out, contains('AppEnv.ensureValid();'));
        expect(out, contains('debugPrint(AppEnv.summary);'));
        expect(out, isNot(contains('note: lib/app_env.dart')));
      });

      test(
        'with --force init\'s own text is replaced without a note',
        () async {
          final world = bare();
          await run(world, ['init']);
          world.console.outLines.clear();
          expect(await run(world, ['init', '--force']), 0);
          final out = world.console.stdoutText;
          expect(out, contains(row('overwrote', 'lib/app_env.dart\n')));
          expect(out, isNot(contains('lib/app_env.dart (')));
        },
      );

      group('from 0.2.0', () {
        TestWorld before() =>
            bare(lib: ['lib/config/theme.dart'])
              ..fs.put(world0('lib/config/app_env.dart'), _appEnv020);

        test('is kept; the lines leave out ensureValid and say why', () async {
          final world = before();
          expect(await run(world, ['init']), 0);
          expect(
            world.fs.readString(world.abs('lib/config/app_env.dart')),
            _appEnv020,
          );
          final out = world.console.stdoutText;
          expect(
            out,
            contains("import 'package:example_app/config/app_env.dart';"),
          );
          expect(out, contains('debugPrint(AppEnv.summary);'));
          expect(out, isNot(contains('AppEnv.ensureValid();')));
          expect(
            out,
            contains(
              'note: lib/config/app_env.dart was written by an earlier init and has no ensureValid()',
            ),
          );
        });

        test('--force updates it and does not call it custom', () async {
          final world = before();
          expect(await run(world, ['init', '--force']), 0);
          final out = world.console.stdoutText;
          expect(out, contains(row('overwrote', 'lib/config/app_env.dart\n')));
          expect(
            world.fs.readString(world.abs('lib/config/app_env.dart')),
            contains('static void ensureValid()'),
          );
          expect(out, contains('AppEnv.ensureValid();'));
          expect(out, isNot(contains('earlier init')));
        });

        test('deleting it and running init again is the upgrade', () async {
          final world = before();
          world.fs.deleteFile(world.abs('lib/config/app_env.dart'));
          expect(await run(world, ['init']), 0);
          expect(
            world.fs.readString(world.abs('lib/config/app_env.dart')),
            contains('static void ensureValid()'),
          );
        });
      });

      test('a file of your own at that place gets the "your own" note', () async {
        final world = bare(lib: ['lib/config/theme.dart'])
          ..fs.put(
            world0('lib/config/app_env.dart'),
            "class AppEnv {\n  static const flavor = 'x';\n}\n",
          );
        expect(await run(world, ['init']), 0);
        final out = world.console.stdoutText;
        expect(
          out,
          contains(
            'note: lib/config/app_env.dart is your own AppEnv and init did not change it. It has no ensureValid()',
          ),
        );
        expect(out, isNot(contains('AppEnv.ensureValid();')));
        expect(out, isNot(contains('debugPrint')));
      });
    });

    group('a file of the project at that place', () {
      const custom = '''
import 'package:flutter/foundation.dart';

class AppEnv {
  static const baseUrl = String.fromEnvironment('BASE_URL');
  static const sentryDsn = 'https://key@sentry.example/1';
}
''';

      String importOf(String path) =>
          "import 'package:example_app/${path.substring('lib/'.length)}';";

      for (final (label, lib, path) in <(String, List<String>, String)>[
        (
          'lib/config/app_env.dart',
          ['lib/main.dart'],
          'lib/config/app_env.dart',
        ),
        (
          'lib/app_env.dart next to lib/config/',
          ['lib/config/theme.dart'],
          'lib/app_env.dart',
        ),
        ('lib/app_env.dart', ['lib/main.dart'], 'lib/app_env.dart'),
      ]) {
        group('a class $label', () {
          test('is kept by init --force and named in the import', () async {
            final world = bare(lib: lib)..fs.put(world0(path), custom);
            final before = world.fs.snapshot();
            expect(
              await run(world, ['init', '--force']),
              0,
              reason: world.console.allText,
            );
            expect(world.fs.readString(world.abs(path)), custom);
            final added = {...world.fs.files.keys}.difference({...before.keys});
            expect(
              added.where((f) => f.endsWith('.dart')),
              isEmpty,
              reason: 'no Dart file was added',
            );
            final out = world.console.stdoutText;
            expect(
              out,
              contains(
                row(
                  'skipped',
                  '$path (already defines AppEnv; init writes no second one)',
                ),
              ),
            );
            expect(out, isNot(contains('overwrote         $path')));
            expect(out, contains(importOf(path)));
            // Only the class is kept: the rest of init still ran.
            expect(out, contains(row('created', 'config/env/dev.json')));
          });

          test('is not listed as overwritten by --force --dry-run', () async {
            final world = bare(lib: lib)..fs.put(world0(path), custom);
            final before = world.fs.snapshot();
            expect(await run(world, ['init', '--force', '--dry-run']), 0);
            expect(world.fs.snapshot(), before);
            final out = world.console.stdoutText;
            expect(out, isNot(contains('would overwrite $path')));
            expect(out, isNot(contains('custom content replaced')));
            expect(out, contains('skipped         $path (already defines'));
          });
        });
      }

      for (final (label, source) in <(String, String)>[
        ('a constant', 'const appEnvName = "x";\n'),
        ('an enum of another name', 'enum AppEnvironment { dev, prod }\n'),
        ('an empty file', ''),
      ]) {
        test('$label is kept: no import, no "your own AppEnv"', () async {
          final world = bare(lib: ['lib/config/theme.dart'])
            ..fs.put(world0('lib/config/app_env.dart'), source);
          for (final args in [
            ['init'],
            ['init', '--force'],
            ['init', '--force', '--dry-run'],
          ]) {
            world.console.outLines.clear();
            expect(await run(world, args), 0, reason: args.join(' '));
            expect(
              world.fs.readString(world.abs('lib/config/app_env.dart')),
              source,
            );
            final out = world.console.stdoutText;
            expect(
              out,
              contains(
                row(
                  'skipped',
                  'lib/config/app_env.dart (exists but defines no AppEnv; init does not replace it, not even with --force)',
                ),
              ),
            );
            expect(
              out,
              contains(
                'note: lib/config/app_env.dart exists but defines no AppEnv, so init wrote none',
              ),
            );
            expect(out, isNot(contains('import \'package:')));
            expect(out, isNot(contains('your own AppEnv')));
            expect(out, isNot(contains('AppEnv.ensureValid();')));
            expect(out, isNot(contains('would overwrite lib/')));
          }
          expect(world.fs.fileExists(world.abs('lib/app_env.dart')), isFalse);
        });
      }

      test('a file that is not text is kept and says so', () async {
        final world = bare(lib: ['lib/main.dart'])
          ..fs.put(world0('lib/app_env.dart'), [0xC3, 0x28, 0xFF]);
        expect(await run(world, ['init', '--force']), 0);
        expect(world.fs.files[world0('lib/app_env.dart')], [0xC3, 0x28, 0xFF]);
        expect(
          world.console.stdoutText,
          contains(
            'note: lib/app_env.dart exists but cannot be read as text, so init wrote none',
          ),
        );
      });

      test('a class elsewhere is used when the file there has none', () async {
        final world = bare(lib: ['lib/config/theme.dart'])
          ..fs.put(
            world0('lib/config/app_env.dart'),
            'enum AppEnvironment {}\n',
          )
          ..fs.put(world0('lib/core/env.dart'), custom);
        expect(await run(world, ['init']), 0);
        final out = world.console.stdoutText;
        expect(
          out,
          contains(
            row(
              'skipped',
              'lib/core/env.dart (already defines AppEnv; init writes no second one)',
            ),
          ),
        );
        expect(out, contains(importOf('lib/core/env.dart')));
        expect(out, isNot(contains('config/app_env.dart')));
      });

      test('a class at the other place wins over one found elsewhere', () async {
        final world = bare(lib: ['lib/config/theme.dart'])
          ..fs.put(world0('lib/app_env.dart'), custom)
          ..fs.put(world0('lib/core/env.dart'), custom);
        expect(await run(world, ['init']), 0);
        final out = world.console.stdoutText;
        expect(
          out,
          contains(
            row(
              'skipped',
              'lib/app_env.dart (already defines AppEnv; init writes no second one)',
            ),
          ),
        );
        expect(out, contains(importOf('lib/app_env.dart')));
        expect(out, isNot(contains('core/env.dart')));
      });
    });

    group('with CRLF line endings', () {
      String crlf(String text) => text.replaceAll('\n', '\r\n');

      test('init\'s own text is still its own', () async {
        final own = crlf(await initsOwnText());
        final world = bare(lib: ['lib/main.dart'])
          ..fs.put(world0('lib/app_env.dart'), own);
        expect(await run(world, ['init']), 0);
        expect(world.fs.readString(world.abs('lib/app_env.dart')), own);
        var out = world.console.stdoutText;
        expect(
          out,
          contains(
            'skipped         lib/app_env.dart (exists; --force overwrites it)',
          ),
        );
        expect(out, contains('AppEnv.ensureValid();'));
        expect(out, isNot(contains('your own AppEnv')));
        expect(out, isNot(contains('earlier init')));

        world.console.outLines.clear();
        expect(await run(world, ['init', '--force']), 0);
        out = world.console.stdoutText;
        expect(out, contains(row('overwrote', 'lib/app_env.dart\n')));
        expect(out, isNot(contains('custom content replaced')));
      });

      test('the 0.2.0 text is still the one of an earlier init', () async {
        final world = bare(lib: ['lib/main.dart'])
          ..fs.put(world0('lib/app_env.dart'), crlf(_appEnv020));
        expect(await run(world, ['init']), 0);
        var out = world.console.stdoutText;
        expect(
          out,
          contains(
            'note: lib/app_env.dart was written by an earlier init and has no ensureValid()',
          ),
        );
        expect(out, isNot(contains('your own AppEnv')));

        world.console.outLines.clear();
        expect(await run(world, ['init', '--force']), 0);
        out = world.console.stdoutText;
        expect(out, contains(row('overwrote', 'lib/app_env.dart\n')));
        expect(out, isNot(contains('custom content replaced')));
        expect(
          world.fs.readString(world.abs('lib/app_env.dart')),
          contains('static void ensureValid()'),
        );
      });

      test('a wrapper script is not custom content because of it', () async {
        final first = bare();
        await run(first, ['init']);
        final script = first.fs.readString(first.abs('scripts/build.sh'));
        final world = bare()..fs.put(world0('scripts/build.sh'), crlf(script));
        expect(await run(world, ['init', '--force']), 0);
        final out = world.console.stdoutText;
        expect(out, contains(row('overwrote', 'scripts/build.sh\n')));
        expect(out, isNot(contains('custom content replaced')));
      });
    });

    group('one the project defines elsewhere', () {
      const own = '''
import 'package:flutter/foundation.dart';

class AppEnv {
  static const baseUrl = String.fromEnvironment('BASE_URL');
  static String get summary => baseUrl;
  static void ensureValid() {}
}
''';

      TestWorld defined(String path, String source, {List<String>? lib}) =>
          bare(lib: lib ?? ['lib/main.dart'])..fs.put(world0(path), source);

      test('is not duplicated: init writes none and names the file', () async {
        final world = defined('lib/core/env.dart', own);
        expect(await run(world, ['init']), 0, reason: world.console.allText);
        expect(world.fs.fileExists(world.abs('lib/app_env.dart')), isFalse);
        expect(
          world.fs.fileExists(world.abs('lib/config/app_env.dart')),
          isFalse,
        );
        final out = world.console.stdoutText;
        expect(
          out,
          contains(
            row(
              'skipped',
              'lib/core/env.dart (already defines AppEnv; init writes no second one)',
            ),
          ),
        );
        expect(out, contains('7 created, 0 overwritten, 1 skipped.'));
      });

      test('the main.dart import is the file of the project', () async {
        final world = defined('lib/core/env.dart', own);
        await run(world, ['init']);
        final out = world.console.stdoutText;
        expect(out, contains("import 'package:example_app/core/env.dart';"));
        expect(out, isNot(contains('app_env.dart')));
        // It has both members, so both lines are shown.
        expect(out, contains('AppEnv.ensureValid();'));
        expect(out, contains('debugPrint(AppEnv.summary);'));
        expect(out, isNot(contains('note: lib/core/env.dart')));
      });

      test(
        'only the members it has are shown, with a note for the guard',
        () async {
          final world = defined(
            'lib/core/env.dart',
            'class AppEnv {\n  static const baseUrl = "x";\n}\n',
          );
          await run(world, ['init']);
          final out = world.console.stdoutText;
          expect(out, contains("import 'package:example_app/core/env.dart';"));
          expect(out, isNot(contains('AppEnv.ensureValid();')));
          expect(out, isNot(contains('AppEnv.summary')));
          expect(
            out,
            contains(
              'note: lib/core/env.dart is your own AppEnv and init did not change it. It has no ensureValid()',
            ),
          );
        },
      );

      test('--force does not touch it and writes no second one', () async {
        final world = defined('lib/core/env.dart', own);
        final before = world.fs.snapshot();
        expect(await run(world, ['init', '--force']), 0);
        expect(world.fs.readString(world.abs('lib/core/env.dart')), own);
        expect(world.fs.fileExists(world.abs('lib/app_env.dart')), isFalse);
        final files = {...world.fs.files.keys}.difference({...before.keys});
        expect(
          files.where((f) => f.endsWith('.dart')),
          isEmpty,
          reason: 'no Dart file was added',
        );
        expect(
          world.console.stdoutText,
          contains(
            row(
              'skipped',
              'lib/core/env.dart (already defines AppEnv; init writes no second one)',
            ),
          ),
        );
      });

      test('a dry run lists it as skipped', () async {
        final world = defined('lib/core/env.dart', own);
        final before = world.fs.snapshot();
        expect(await run(world, ['init', '--dry-run']), 0);
        expect(world.fs.snapshot(), before);
        final out = world.console.stdoutText;
        expect(out, contains('skipped         lib/core/env.dart'));
        expect(out, isNot(contains('would create lib/app_env.dart')));
        expect(out, contains('7 file(s) would be written, 1 skipped.'));
      });

      test('a second init says there is nothing to do', () async {
        final world = defined('lib/core/env.dart', own);
        await run(world, ['init']);
        final before = world.fs.snapshot();
        world.console.outLines.clear();
        expect(await run(world, ['init']), 0);
        expect(world.fs.snapshot(), before);
        expect(
          world.console.stdoutText,
          contains('Nothing to do: every file already exists (8 skipped).'),
        );
      });

      for (final (label, source) in <(String, String)>[
        ('abstract final class', 'abstract final class AppEnv {}'),
        ('sealed class', 'sealed class AppEnv {}'),
        ('base mixin class', 'base mixin class AppEnv {}'),
        ('class with a type parameter', 'class AppEnv<T> {}'),
        ('class with extends', 'class AppEnv extends Base {}'),
        ('enum', 'enum AppEnv { dev, prod }'),
        ('mixin', 'mixin AppEnv {}'),
        ('extension type', 'extension type const AppEnv(String v) {}'),
        ('typedef', 'typedef AppEnv = Map<String, String>;'),
        ('indented', '  class AppEnv {}'),
      ]) {
        test('$label counts as one', () async {
          final world = defined('lib/env/settings.dart', '$source\n');
          expect(await run(world, ['init']), 0);
          expect(world.fs.fileExists(world.abs('lib/app_env.dart')), isFalse);
          expect(
            world.console.stdoutText,
            contains("import 'package:example_app/env/settings.dart';"),
          );
        });
      }

      for (final (label, source) in <(String, String)>[
        ('a class of another name', 'class AppEnvironment {}'),
        ('a longer name', 'class AppEnv2 {}\nclass AppEnv_x {}'),
        ('a dollar in the name', r'class AppEnv$x {}'),
        ('a comment', '// class AppEnv {}\n/// class AppEnv {}'),
        ('a use', 'final e = AppEnv();\nvoid f(AppEnv e) {}'),
        ('a string', "const s = 'class AppEnv';"),
      ]) {
        test('$label does not', () async {
          final world = defined('lib/env/settings.dart', '$source\n');
          expect(await run(world, ['init']), 0);
          expect(world.fs.fileExists(world.abs('lib/app_env.dart')), isTrue);
          expect(world.console.stdoutText, isNot(contains('already defines')));
        });
      }

      test('only Dart files under lib/ are looked at', () async {
        final world = bare(lib: ['lib/main.dart'])
          ..fs.put(world0('lib/notes.md'), 'class AppEnv {}\n')
          ..fs.put(world0('test/app_env_test.dart'), 'class AppEnv {}\n')
          ..fs.put(world0('tool/env.dart'), 'class AppEnv {}\n')
          ..fs.put(world0('example/lib/env.dart'), 'class AppEnv {}\n');
        expect(await run(world, ['init']), 0);
        expect(world.fs.fileExists(world.abs('lib/app_env.dart')), isTrue);
        expect(world.console.stdoutText, isNot(contains('already defines')));
      });

      test('a file that cannot be read is passed over', () async {
        final world = defined('lib/core/env.dart', own)
          ..fs.put(world0('lib/a_broken.dart'), [0xC3, 0x28, 0xFF]);
        expect(await run(world, ['init']), 0, reason: world.console.allText);
        expect(
          world.console.stdoutText,
          contains("import 'package:example_app/core/env.dart';"),
        );
        // And when only the broken file is there, init still writes its own.
        final alone = bare(lib: ['lib/main.dart'])
          ..fs.put(world0('lib/a_broken.dart'), [0xC3, 0x28, 0xFF]);
        expect(await run(alone, ['init']), 0, reason: alone.console.allText);
        expect(alone.fs.fileExists(alone.abs('lib/app_env.dart')), isTrue);
      });

      test('a lib/ folder that cannot be listed does not fail init, and '
          'says what could not be checked', () async {
        final world = bare(lib: ['lib/main.dart']);
        final fs = UnlistableFs();
        expect(await runBuildTool(['init'], world.envOn(fs)), 0);
        expect(fs.fileExists('/repo/lib/app_env.dart'), isTrue);
        final out = world.console.stdoutText;
        expect(
          out,
          contains(
            'note: lib/ could not be read completely (a folder is not readable), so init could not check whether the project already defines an AppEnv. If it does, delete lib/app_env.dart and use that class; give --no-app-env to skip the class.',
          ),
        );
        // The note comes after the lines for main.dart.
        expect(
          out.indexOf('AppEnv.ensureValid();'),
          lessThan(out.indexOf('could not be read completely')),
        );
      });

      test('a dry run on a lib/ that cannot be listed says it too', () async {
        final world = bare(lib: ['lib/main.dart']);
        final fs = UnlistableFs();
        expect(await runBuildTool(['init', '--dry-run'], world.envOn(fs)), 0);
        expect(
          world.console.stdoutText,
          contains('lib/ could not be read completely'),
        );
        expect(fs.fileExists('/repo/lib/app_env.dart'), isFalse);
      });

      test('a complete listing, or no class to write, says nothing', () async {
        final complete = bare(lib: ['lib/main.dart']);
        expect(await run(complete, ['init']), 0);
        expect(
          complete.console.stdoutText,
          isNot(contains('could not be read completely')),
        );

        // init's own text at its place: nothing is written, so nothing is
        // missed, and the folder is not even listed.
        final own = bare(lib: ['lib/main.dart'])
          ..fs.put(world0('lib/app_env.dart'), await initsOwnText());
        final ownFs = UnlistableFs();
        expect(await runBuildTool(['init'], own.envOn(ownFs)), 0);
        expect(
          own.console.stdoutText,
          isNot(contains('could not be read completely')),
        );

        final off = bare(lib: ['lib/main.dart']);
        expect(
          await runBuildTool([
            'init',
            '--no-app-env',
          ], off.envOn(UnlistableFs())),
          0,
        );
        expect(
          off.console.stdoutText,
          isNot(contains('could not be read completely')),
        );
      });

      test('a copy in the usual place wins over another file', () async {
        final world = defined('lib/core/env.dart', own)
          ..fs.put(world0('lib/config/app_env.dart'), await initsOwnText());
        expect(await run(world, ['init']), 0);
        final out = world.console.stdoutText;
        expect(
          out,
          contains(
            'skipped         lib/config/app_env.dart (exists; --force overwrites it)',
          ),
        );
        expect(
          out,
          contains("import 'package:example_app/config/app_env.dart';"),
        );
        expect(out, isNot(contains('already defines')));
      });

      test(
        'the first of several files, in path order, is the one named',
        () async {
          // The real disk lists in no particular order: the choice must not
          // depend on it.
          final world = defined('lib/z/env.dart', own)
            ..fs.put(world0('lib/a/env.dart'), own);
          final fs = ReversedListFs();
          expect(await runBuildTool(['init'], world.envOn(fs)), 0);
          expect(
            world.console.stdoutText,
            contains("import 'package:example_app/a/env.dart';"),
          );
        },
      );
    });

    group('the class text', () {
      test('declaresAppEnv looks at declarations, not at mentions', () {
        expect(declaresAppEnv('class AppEnv {}'), isTrue);
        expect(declaresAppEnv('// x\nfinal class AppEnv {\n}'), isTrue);
        expect(declaresAppEnv('class AppEnvironment {}'), isFalse);
        expect(declaresAppEnv('// class AppEnv {}'), isFalse);
        expect(declaresAppEnv(''), isFalse);
      });

      test('the options of the API write it unless told not to', () async {
        final on = bare();
        expect(await runInit(on.env, const InitOptions()), 0);
        expect(on.fs.fileExists(on.abs('lib/app_env.dart')), isTrue);
        final off = bare();
        expect(await runInit(off.env, const InitOptions(appEnv: false)), 0);
        expect(off.fs.fileExists(off.abs('lib/app_env.dart')), isFalse);
      });
    });
  });

  group('what it cannot infer', () {
    test(
      'a mobile-only project: lists the platform facts, writes none',
      () async {
        final world = bare(templates: false);
        expect(await run(world, ['init']), 0, reason: world.console.allText);
        final out = world.console.stdoutText;
        expect(out, contains('Not inferred'));
        expect(
          out,
          contains('windows.exe: windows/CMakeLists.txt does not exist'),
        );
        expect(
          out,
          contains(
            'macos.appName: macos/Runner/Configs/AppInfo.xcconfig does not exist',
          ),
        );
        expect(
          out,
          contains('windows.installerScript: installer/ has no .iss file'),
        );
        final config = json(world, 'tool/build/build_config.json');
        expect(config.containsKey('windows'), isFalse);
        expect(config.containsKey('macos'), isFalse);
        // The file is valid and apk/web build.
        expect(await run(world, ['apk', 'dev', '--dry-run']), 0);
        expect(await run(world, ['web', 'dev', '--dry-run']), 0);
        expect(await run(world, ['windows', 'dev', '--dry-run']), 1);
      },
    );

    test('a pubspec without a name is an error', () async {
      final world = bare()..fs.put(world0('pubspec.yaml'), 'version: 1.0.0\n');
      expect(await run(world, ['init']), 1);
      expect(world.console.stderrText, contains('has no top-level "name:"'));
      expect(
        world.fs.fileExists(world.abs('tool/build/build_config.json')),
        isFalse,
      );
    });
  });

  group('notes', () {
    test('.gitignore without dist/ is pointed out', () async {
      final world = bare();
      await run(world, ['init']);
      expect(
        world.console.stdoutText,
        contains('.gitignore does not ignore dist/'),
      );
    });

    test('.gitignore with dist/ is not', () async {
      final world = bare()..fs.put(world0('.gitignore'), '/build/\ndist/\n');
      await run(world, ['init']);
      expect(world.console.stdoutText, isNot(contains('.gitignore')));
    });

    test('on Windows there is no chmod, and git needs the bit', () async {
      final world = bare(host: HostOs.windows);
      expect(await run(world, ['init']), 0, reason: world.console.allText);
      expect(chmodCalls(world), isEmpty);
      expect(
        world.console.stdoutText,
        contains('git update-index --chmod=+x scripts/build.sh'),
      );
    });

    test('a failing chmod is a note, not a failure', () async {
      final world = bare();
      world.runner.onCapture(
        (s) => s.executable == 'chmod',
        (_) => const CapturedProcess(1, '', 'denied'),
        first: true,
      );
      expect(await run(world, ['init']), 0);
      expect(
        world.console.stdoutText,
        contains(
          'could not make scripts/build.sh executable; run: chmod +x scripts/build.sh',
        ),
      );
      expect(world.fs.fileExists(world.abs('scripts/build.sh')), isTrue);
    });

    test('the next steps use the invocation of a shim', () async {
      final world = bare();
      // options.invocation is what a shim passes; the CLI default is used here.
      await run(world, ['init']);
      expect(
        world.console.stdoutText,
        contains('dart run flutter_build_tools apk dev --dry-run'),
      );
    });
  });

  group('files git ignores', () {
    void gitSays(TestWorld world, int code, String stdout) {
      world.runner.onCapture(
        (s) => s.executable == 'git' && s.args.first == 'check-ignore',
        (_) => CapturedProcess(code, stdout, ''),
        first: true,
      );
    }

    test('a rule that hides the config is pointed out, with the fix', () async {
      final world = bare();
      gitSays(world, 0, '.gitignore:1:build/\ttool/build/build_config.json\n');
      expect(await run(world, ['init']), 0);
      final out = world.console.stdoutText;
      expect(
        out,
        contains(
          'note: tool/build/build_config.json is git-ignored (.gitignore:1:build/); a clone or CI checkout will not have it and will infer every fact it holds',
        ),
      );
      expect(out, contains('Anchor the rule (for example "/build/"'));
      expect(out, contains('git add -f tool/build/build_config.json'));
      final query = world.runner.calls.singleWhere(
        (c) => c.executable == 'git',
      );
      expect(query.args, [
        'check-ignore',
        '-v',
        '--',
        'tool/build/build_config.json',
        'config/env/dev.json',
        'config/env/preprod.json',
        'config/env/prod.json',
        'config/env/local.json',
      ]);
      expect(query.workingDirectory, '/repo');
    });

    test('an ignored env file is pointed out too', () async {
      final world = bare();
      gitSays(world, 0, '.gitignore:4:config/\tconfig/env/prod.json\n');
      expect(await run(world, ['init']), 0);
      final out = world.console.stdoutText;
      expect(
        out,
        contains(
          'note: config/env/prod.json is git-ignored (.gitignore:4:config/); a clone or CI checkout will not have this env file',
        ),
      );
      expect(out, isNot(contains('build_config.json is git-ignored')));
    });

    for (final (label, code, stdout) in <(String, int, String)>[
      ('nothing is ignored', 1, ''),
      ('this is not a repository', 128, 'fatal: not a git repository'),
    ]) {
      test('$label: nothing is said', () async {
        final world = bare();
        gitSays(world, code, stdout);
        expect(await run(world, ['init']), 0);
        expect(world.console.stdoutText, isNot(contains('git-ignored')));
      });
    }

    test('git is not installed: nothing is said', () async {
      final world = bare();
      world.runner.onCapture(
        (s) => s.executable == 'git' && s.args.first == 'check-ignore',
        (s) => throw ProcessStartException(s, 'No such file'),
        first: true,
      );
      expect(await run(world, ['init']), 0);
      expect(world.console.stdoutText, isNot(contains('git-ignored')));
    });

    test('init stays read-only for git', () async {
      final world = bare();
      await run(world, ['init']);
      final gitCalls = [
        for (final call in world.runner.calls)
          if (call.executable == 'git') call.args.first,
      ];
      expect(gitCalls, ['check-ignore']);
    });
  });

  group('a write that fails', () {
    test('is exit 1 that names the file and what was already written', () async {
      final world = bare();
      final fs = DenyingFs((path) => path.contains('/config/env/'));
      final code = await runBuildTool(['init'], world.envOn(fs));
      expect(code, 1);
      final err = world.console.stderrText;
      expect(
        err,
        startsWith(
          'error: could not write config/env/dev.json: Permission denied. Already written: tool/build/build_config.json.',
        ),
      );
      expect(err, contains('run init again'));
      expect(err, isNot(contains('Unhandled')));
      expect(fs.fileExists('/repo/tool/build/build_config.json'), isTrue);
      expect(fs.fileExists('/repo/config/env/dev.json'), isFalse);
      // The rest is not attempted, and a second run finishes the job.
      expect(fs.fileExists('/repo/scripts/build.sh'), isFalse);
      world.console.errLines.clear();
      final retry = DenyingFs((_) => false)
        ..files.addAll(fs.files)
        ..dirs.addAll(fs.dirs);
      expect(await runBuildTool(['init'], world.envOn(retry)), 0);
      expect(retry.fileExists('/repo/scripts/build.sh'), isTrue);
    });

    test('of the AppEnv file also says how to do without the class', () async {
      final world = bare();
      final fs = DenyingFs((path) => path.endsWith('/lib/app_env.dart'));
      expect(await runBuildTool(['init'], world.envOn(fs)), 1);
      final err = world.console.stderrText;
      expect(
        err,
        contains('could not write lib/app_env.dart: Permission denied.'),
      );
      expect(err, contains('Already written: tool/build/build_config.json'));
      expect(err, contains('run init again'));
      expect(
        err,
        contains('Or run init --no-app-env to skip the AppEnv class.'),
      );
      // The way out works: the class was the only file that was missing.
      world.console.errLines.clear();
      expect(
        await runBuildTool(['init', '--no-app-env'], world.envOn(fs)),
        0,
        reason: world.console.allText,
      );
      expect(fs.fileExists('/repo/lib/app_env.dart'), isFalse);
      expect(fs.fileExists('/repo/scripts/build.ps1'), isTrue);
    });

    test('of another file does not mention the AppEnv class', () async {
      final world = bare();
      final fs = DenyingFs((path) => path.contains('/scripts/'));
      expect(await runBuildTool(['init'], world.envOn(fs)), 1);
      final err = world.console.stderrText;
      expect(err, contains('could not write scripts/build.sh'));
      expect(err, isNot(contains('--no-app-env')));
    });

    test('before anything is written it says so', () async {
      final world = bare();
      final fs = DenyingFs((path) => path.contains('/tool/'));
      expect(await runBuildTool(['init'], world.envOn(fs)), 1);
      expect(
        world.console.stderrText,
        contains(
          'could not write tool/build/build_config.json: Permission denied. Nothing was written.',
        ),
      );
    });
  });

  group('env files with keys the config does not declare', () {
    void localWith(TestWorld world, Map<String, Object?> extra) {
      world.fs.put(
        world.abs('config/env/local.json'),
        jsonEncode({
          'APP_ENV': 'local',
          'BASE_URL': 'http://127.0.0.1:8081',
          ...extra,
        }),
      );
    }

    test('are listed with the snippet that declares them', () async {
      final world = bare();
      localWith(world, {'USE_DUMMY': 'true'});
      expect(await run(world, ['init']), 0, reason: world.console.allText);
      final out = world.console.stdoutText;
      expect(
        out,
        contains(
          'Not accepted yet: these env file keys are not declared in tool/build/build_config.json',
        ),
      );
      expect(out, contains(RegExp(r'USE_DUMMY +config/env/local\.json')));
      expect(out, contains('"envFile": {"extraKeys": ["USE_DUMMY"]}'));
      expect(out, contains('never secrets'));

      // The problem is real, and the snippet is the fix.
      expect(await run(world, ['--list']), 1);
      expect(world.console.stdoutText, contains('unknown key "USE_DUMMY"'));
      final config = json(world, 'tool/build/build_config.json');
      config['envFile'] = {
        'extraKeys': ['USE_DUMMY'],
      };
      world.fs.put(
        world.abs('tool/build/build_config.json'),
        jsonEncode(config),
      );
      world.console.outLines.clear();
      expect(await run(world, ['--list']), 0, reason: world.console.allText);
      await run(world, ['init']);
      expect(world.console.stdoutText, isNot(contains('Not accepted yet')));
    });

    test(
      'a URL goes under extraUrlKeys, a bad name cannot be declared',
      () async {
        final world = bare();
        localWith(world, {'SHOP_URL': 'https://shop.test', 'my-key': 'x'});
        expect(await run(world, ['init']), 0);
        final out = world.console.stdoutText;
        expect(out, contains('"envFile": {"extraUrlKeys": ["SHOP_URL"]}'));
        expect(
          out,
          contains(
            'my-key    config/env/local.json   (cannot be declared: keys are UPPER_SNAKE_CASE; rename it)',
          ),
        );
        expect(out, isNot(contains('"my-key"')));
      },
    );

    test('a key the existing config declares is not reported', () async {
      final world = bare();
      world.fs.put(
        world.abs('tool/build/build_config.json'),
        jsonEncode({
          'envFile': {
            'extraKeys': ['USE_DUMMY'],
          },
        }),
      );
      localWith(world, {'USE_DUMMY': 'true'});
      expect(await run(world, ['init']), 0);
      expect(world.console.stdoutText, isNot(contains('Not accepted yet')));
    });

    test('a fresh project has none to report', () async {
      final world = bare();
      expect(await run(world, ['init']), 0);
      expect(world.console.stdoutText, isNot(contains('Not accepted yet')));
    });
  });

  group('the command line', () {
    for (final (args, text) in <(List<String>, String)>[
      (
        ['init', 'apk'],
        'init takes no platform, environment or mode (got "apk")',
      ),
      (['init', '--mode', 'debug'], 'init does not take --mode'),
      (['init', '--release'], 'init does not take --release'),
      (
        ['init', '--base-url', 'https://x.test'],
        'init does not take --base-url',
      ),
      (['apk', 'dev', '--force'], '--force only applies to the init command'),
      (
        ['apk', 'dev', '--app-env'],
        '--app-env only applies to the init command',
      ),
      (
        ['apk', 'dev', '--no-app-env'],
        '--no-app-env only applies to the init command',
      ),
      (
        ['init', '--app-env', '--no-app-env'],
        '--app-env and --no-app-env contradict each other',
      ),
    ]) {
      test('${args.join(' ')} is a usage error (exit 2)', () async {
        final world = bare();
        expect(await run(world, args), 2);
        expect(world.console.stderrText, contains(text));
        expect(
          world.fs.fileExists(world.abs('tool/build/build_config.json')),
          isFalse,
        );
      });
    }

    test('init --help shows the usage', () async {
      final world = bare();
      expect(await run(world, ['init', '--help']), 0);
      expect(world.console.stdoutText, contains('Usage:'));
      expect(world.fs.fileExists(world.abs('scripts/build.sh')), isFalse);
    });

    test(
      '--help shows init with --no-app-env and says AppEnv is written',
      () async {
        final world = bare();
        expect(await run(world, ['--help']), 0);
        final out = world.console.stdoutText;
        expect(out, contains('init [--force] [--dry-run] [--no-app-env]'));
        expect(out, contains('--no-app-env skips AppEnv'));
        expect(out, contains('lib/config/app_env.dart'));
        expect(out, isNot(contains('[--app-env]')));
      },
    );

    test('INIT is accepted in any case', () async {
      final world = bare();
      expect(await run(world, ['INIT', '--dry-run']), 0);
    });
  });
}

/// `/repo/<relative>` for the tests that build a path before the world exists.
String world0(String relative) => '/repo/$relative';

/// The `AppEnv` text of this version, as `init` writes it for `config/env`.
Future<String> initsOwnText() async {
  final world = bare();
  expect(await run(world, ['init']), 0);
  return world.fs.readString(world.abs('lib/app_env.dart'));
}

/// The `AppEnv` text that `init --app-env` of 0.2.0 wrote: no startup guard.
const String _appEnv020 =
    r'''/// Build-time settings, compiled in by `flutter_build_tools` from the env file
/// of the environment that was built (`--dart-define-from-file`).
///
/// Running from the IDE or `flutter run` has no env file unless you pass one:
/// `flutter run --dart-define-from-file=config/env/dev.json`.
class AppEnv {
  AppEnv._();

  /// `dev`, `preprod`, `prod` or `local`; empty when no env file was passed.
  static const String name = String.fromEnvironment('APP_ENV');

  /// The API origin of this environment; empty when no env file was passed.
  static const String baseUrl = String.fromEnvironment('BASE_URL');

  /// The short git commit of the build (`-dirty` when the tree had changes).
  static const String buildSha = String.fromEnvironment('BUILD_SHA');

  /// One line for a log: `dev https://... 1a2b3c4`.
  static String get summary => '$name $baseUrl $buildSha';
}
''';

/// Remembers every folder that was listed.
class ListCountingFs extends MemoryFs {
  final List<String> listed = [];

  @override
  List<String> listFiles(String dir, {bool recursive = false}) {
    listed.add(dir);
    return super.listFiles(dir, recursive: recursive);
  }
}

/// A `lib/` folder that the operating system refuses to list.
class UnlistableFs extends MemoryFs {
  @override
  List<String> listFiles(String dir, {bool recursive = false}) {
    if (dir.endsWith('/lib')) {
      throw FileSystemException('Directory listing failed', dir);
    }
    return super.listFiles(dir, recursive: recursive);
  }
}

/// Lists files in reverse path order, as a disk may.
class ReversedListFs extends MemoryFs {
  @override
  List<String> listFiles(String dir, {bool recursive = false}) =>
      super.listFiles(dir, recursive: recursive).reversed.toList();
}
