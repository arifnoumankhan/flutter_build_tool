// The init command: what it writes, what it never overwrites, and that the
// project builds right after it.
import 'dart:convert';

import 'package:test/test.dart';

import 'package:flutter_build_tools/src/cli.dart';
import 'package:flutter_build_tools/src/config.dart';
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
      ]) {
        expect(out, contains(row('created', path)));
        expect(world.fs.fileExists(world.abs(path)), isTrue, reason: path);
      }
      expect(out, contains('7 created, 0 overwritten, 0 skipped.'));
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
        contains('Nothing to do: every file already exists (7 skipped).'),
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
      expect(out, contains('1 created, 0 overwritten, 6 skipped.'));
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
      expect(out, contains('0 created, 7 overwritten, 0 skipped.'));
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
      expect(out, contains('7 file(s) would be written, 0 skipped.'));
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

  group('--app-env', () {
    test('writes lib/app_env.dart when lib/config does not exist', () async {
      final world = bare(lib: ['lib/main.dart']);
      expect(
        await run(world, ['init', '--app-env']),
        0,
        reason: world.console.allText,
      );
      final source = world.fs.readString(world.abs('lib/app_env.dart'));
      expect(source, contains("String.fromEnvironment('APP_ENV')"));
      expect(source, contains("String.fromEnvironment('BASE_URL')"));
      expect(source, contains('class AppEnv'));
      expect(
        world.fs.fileExists(world.abs('lib/config/app_env.dart')),
        isFalse,
      );
    });

    test('writes lib/config/app_env.dart when lib/config exists', () async {
      final world = bare(lib: ['lib/main.dart', 'lib/config/theme.dart']);
      expect(await run(world, ['init', '--app-env']), 0);
      expect(world.fs.fileExists(world.abs('lib/config/app_env.dart')), isTrue);
      expect(world.fs.fileExists(world.abs('lib/app_env.dart')), isFalse);
    });

    test('prints the main.dart one-liner and never edits main.dart', () async {
      final world = bare(lib: ['lib/main.dart', 'lib/config/theme.dart']);
      final mainBefore = world.fs.readString(world.abs('lib/main.dart'));
      await run(world, ['init', '--app-env']);
      expect(world.fs.readString(world.abs('lib/main.dart')), mainBefore);
      final out = world.console.stdoutText;
      expect(
        out,
        contains("import 'package:example_app/config/app_env.dart';"),
      );
      expect(out, contains('debugPrint(AppEnv.summary);'));
      expect(out, contains('init never edits lib/main.dart'));
    });

    test(
      'is not written again, also when it lives in the other place',
      () async {
        final world = bare(lib: ['lib/config/theme.dart', 'lib/app_env.dart']);
        expect(await run(world, ['init', '--app-env']), 0);
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
        final world = bare(lib: ['lib/config/theme.dart', 'lib/app_env.dart']);
        expect(await run(world, ['init', '--app-env']), 0);
        final out = world.console.stdoutText;
        expect(out, contains("import 'package:example_app/app_env.dart';"));
        expect(out, isNot(contains('config/app_env.dart')));
      },
    );

    test(
      '--force replaces the copy that exists, it never adds a second class',
      () async {
        final world = bare(lib: ['lib/config/theme.dart', 'lib/app_env.dart']);
        expect(await run(world, ['init', '--force', '--app-env']), 0);
        expect(
          world.fs.fileExists(world.abs('lib/config/app_env.dart')),
          isFalse,
        );
        expect(
          world.fs.readString(world.abs('lib/app_env.dart')),
          contains('class AppEnv'),
        );
        final out = world.console.stdoutText;
        expect(
          out,
          contains(
            row('overwrote', 'lib/app_env.dart (custom content replaced)'),
          ),
        );
        expect(out, contains("import 'package:example_app/app_env.dart';"));
      },
    );

    test(
      'the copy in lib/config/ is the one used when lib/ has none',
      () async {
        final world = bare(lib: ['lib/config/app_env.dart']);
        expect(await run(world, ['init', '--app-env']), 0);
        expect(world.fs.fileExists(world.abs('lib/app_env.dart')), isFalse);
        expect(
          world.console.stdoutText,
          contains("import 'package:example_app/config/app_env.dart';"),
        );
      },
    );

    test('is not written without the flag', () async {
      final world = bare(lib: ['lib/main.dart']);
      await run(world, ['init']);
      expect(world.fs.fileExists(world.abs('lib/app_env.dart')), isFalse);
      expect(world.console.stdoutText, isNot(contains('debugPrint')));
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

    test('INIT is accepted in any case', () async {
      final world = bare();
      expect(await run(world, ['INIT', '--dry-run']), 0);
    });
  });
}

/// `/repo/<relative>` for the tests that build a path before the world exists.
String world0(String relative) => '/repo/$relative';
