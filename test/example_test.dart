// The example/ project is documentation that must keep working: its config
// and env files parse, and the tool runs against it (read-only).
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'package:flutter_build_tools/src/cli.dart';
import 'package:flutter_build_tools/src/config.dart';
import 'package:flutter_build_tools/src/env_file.dart';
import 'package:flutter_build_tools/src/environment.dart';
import 'package:flutter_build_tools/src/fs.dart';
import 'package:flutter_build_tools/src/guards.dart';
import 'package:flutter_build_tools/src/model.dart';
import 'fakes.dart';

void main() {
  // `dart test` runs from the package root.
  final root = p.join(Directory.current.path, 'example');
  String read(String relative) =>
      File(p.join(root, relative)).readAsStringSync();

  AppConfig minimal() => AppConfig.parse(read('tool/build/build_config.json'));
  AppConfig full() =>
      AppConfig.parse(read('tool/build/build_config.full.json'));

  group('the config files', () {
    test('build_config.json holds only the required keys', () {
      final config = minimal();
      expect(config.slug, 'ExampleApp');
      expect(config.displayName, 'Example App');
      expect(config.devHostMarkers, isEmpty);
      expect(config.cleanupPrefix, isNull);
      expect(config.docs, isNull);
      expect(config.wrappers, isEmpty);
      expect(config.envSchema.extraKeys, isEmpty);
      final keys =
          (jsonDecode(read('tool/build/build_config.json'))
                  as Map<String, Object?>)
              .keys;
      expect(keys, [
        'app',
        'slug',
        'displayName',
        'envDir',
        'windows',
        'macos',
      ]);
    });

    test('build_config.full.json sets every optional key', () {
      final config = full();
      expect(config.devHostMarkers, ['devexample']);
      expect(config.cleanupPrefix, 'Example');
      expect(config.docs, 'tool/build/README.md');
      expect(config.wrappers, hasLength(2));
      expect(config.envSchema.extraKeys, ['FEATURE_SET']);
      expect(config.envSchema.extraUrlKeys, ['ANALYTICS_URL']);
    });
  });

  group('the env files', () {
    for (final env in BuildEnv.values) {
      test('${env.name}.json is valid and consistent', () {
        final path = 'config/env/${env.name}.json';
        for (final config in [minimal(), full()]) {
          final file = EnvFile.parse(
            path,
            read(path),
            schema: config.envSchema,
          );
          expect(file.appEnv, env.name, reason: 'APP_ENV must equal the file');
          expect(
            file.baseUrl.startsWith(env.isLocal ? 'http://' : 'https://'),
            isTrue,
          );
          if (env.isProd) {
            expect(
              devLookingMarker(
                file.baseUrl,
                extraMarkers: config.devHostMarkers,
              ),
              isNull,
            );
          }
        }
      });
    }
  });

  group('the Inno Setup script', () {
    test('keeps the contract the Windows target relies on', () {
      final script = read('installer/example_app.iss');
      expect(script, contains('MyAppVersion'));
      expect(script, contains('MyOutputName'));
      expect(script, contains('MyBuildMode'));
      expect(script, contains('OutputBaseFilename={#MyOutputName}'));
      expect(script, contains(r'OutputDir=..\build\windows\installers'));
      expect(script, contains(r'..\build\windows\x64\runner\{#MyBuildMode}\*'));
      expect(script, contains('example_app.exe'));
    });
  });

  group('the tool against the example', () {
    late FakeConsole console;
    late BuildEnvironment env;

    setUp(() {
      console = FakeConsole();
      env = BuildEnvironment(
        root: root,
        host: HostOs.macos,
        vars: const {},
        fs: const IoFs(),
        runner: FakeRunner()..scriptDefaults(),
        console: console,
        now: () => DateTime.utc(2026, 10, 6, 12, 34, 56),
      );
    });

    List<String> snapshot() => [
      for (final e in Directory(root).listSync(recursive: true))
        if (e is File &&
            !e.path.contains('${p.separator}.dart_tool${p.separator}') &&
            !e.path.endsWith('pubspec.lock'))
          p.relative(e.path, from: root),
    ]..sort();

    test('--list shows the four environments', () async {
      expect(await runBuildTool(['--list'], env), 0, reason: console.allText);
      final out = console.stdoutText;
      expect(out, contains('Example App (ExampleApp) version 1.0.0+1'));
      expect(
        out,
        contains('dev      BASE_URL     https://dev.example.com/api'),
      );
      expect(out, contains('local    BASE_URL     http://127.0.0.1:8080'));
    });

    test('--help is titled with the example app', () async {
      expect(await runBuildTool(['--help'], env), 0);
      expect(console.stdoutText, startsWith('Example App build tool:'));
    });

    test('web dev --dry-run plans the build and writes nothing', () async {
      final before = snapshot();
      expect(
        await runBuildTool(['web', 'dev', '--dry-run'], env),
        0,
        reason: console.allText,
      );
      expect(console.stdoutText, contains('ExampleApp-dev-v1.0.0.zip'));
      expect(console.stdoutText, contains('base href    /'));
      expect(snapshot(), before);
      expect(Directory(p.join(root, 'dist')).existsSync(), isFalse);
      expect(Directory(p.join(root, 'build')).existsSync(), isFalse);
    });

    test('web prod --dry-run passes every guard on a clean tree', () async {
      expect(
        await runBuildTool(['web', 'prod', '--dry-run'], env),
        0,
        reason: console.allText,
      );
      expect(console.stderrText, isNot(contains('error')));
    });
  });
}
