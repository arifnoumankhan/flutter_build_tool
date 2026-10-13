// `dart run flutter_build_tools` as a process: bin/flutter_build_tools.dart
// finds the project by walking up from the working directory.
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  // `dart test` runs from the package root.
  final script = p.join(
    Directory.current.path,
    'bin',
    'flutter_build_tools.dart',
  );
  late Directory temp;

  setUp(() => temp = Directory.systemTemp.createTempSync('fbt_bin_test_'));
  tearDown(() => temp.deleteSync(recursive: true));

  Future<ProcessResult> tool(List<String> args, {required String cwd}) =>
      Process.run(
        Platform.resolvedExecutable,
        [script, ...args],
        workingDirectory: cwd,
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      );

  void project() {
    File(
      p.join(temp.path, 'pubspec.yaml'),
    ).writeAsStringSync('name: demo\nversion: 2.1.0+9\n');
    Directory(p.join(temp.path, 'tool', 'build')).createSync(recursive: true);
    File(
      p.join(temp.path, 'tool', 'build', 'build_config.json'),
    ).writeAsStringSync(
      jsonEncode({
        'app': 'demo',
        'slug': 'DemoApp',
        'displayName': 'Demo App',
        'envDir': 'config/env',
        'windows': {'exe': 'demo.exe', 'installerScript': 'installer/demo.iss'},
        'macos': {'appName': 'Demo App'},
      }),
    );
    Directory(p.join(temp.path, 'config', 'env')).createSync(recursive: true);
    for (final env in ['dev', 'preprod', 'prod', 'local']) {
      File(p.join(temp.path, 'config', 'env', '$env.json')).writeAsStringSync(
        jsonEncode({
          'APP_ENV': env,
          'BASE_URL': env == 'local'
              ? 'http://127.0.0.1:8080'
              : 'https://$env.demo.test/api',
        }),
      );
    }
  }

  // "Outside a Flutter project exits 2" is tested in entry_test.dart against
  // an in-memory file system: a real process could only prove it on a machine
  // that has no pubspec.yaml above the system temp folder.

  test('--help works in a project that has no build config yet', () async {
    File(p.join(temp.path, 'pubspec.yaml')).writeAsStringSync('name: demo\n');
    final result = await tool(['--help'], cwd: temp.path);
    expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
    // Nothing is configured, so the title is inferred from the pubspec name
    // and the first-run command is listed.
    expect(result.stdout, startsWith('Demo build tool: one command'));
    expect(result.stdout, contains('dart run flutter_build_tools <platform>'));
    expect(result.stdout, contains('dart run flutter_build_tools init'));
  });

  test('a project with no tool/ and no config/ builds after init', () async {
    File(
      p.join(temp.path, 'pubspec.yaml'),
    ).writeAsStringSync('name: demo_shop\nversion: 3.0.1+12\n');
    final before = await tool(['web', 'dev', '--dry-run'], cwd: temp.path);
    expect(before.exitCode, 1, reason: '${before.stdout}${before.stderr}');
    expect(
      before.stderr,
      contains(
        'Run "dart run flutter_build_tools init" to create every missing',
      ),
    );

    final init = await tool(['init'], cwd: temp.path);
    expect(init.exitCode, 0, reason: '${init.stdout}${init.stderr}');
    expect(
      File(
        p.join(temp.path, 'tool', 'build', 'build_config.json'),
      ).existsSync(),
      isTrue,
    );

    final after = await tool(['web', 'dev', '--dry-run'], cwd: temp.path);
    expect(after.exitCode, 0, reason: '${after.stdout}${after.stderr}');
    expect(after.stdout, contains('DemoShop-dev-v3.0.1.zip'));
    expect(after.stderr, contains('warning [placeholder-url]'));

    final prod = await tool(['web', 'prod', '--dry-run'], cwd: temp.path);
    expect(prod.exitCode, 1);
    expect(prod.stderr, contains('error [placeholder-url]'));
  });

  test('--list reads the project facts', () async {
    project();
    final result = await tool(['--list'], cwd: temp.path);
    expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
    expect(result.stdout, contains('Demo App (DemoApp) version 2.1.0+9'));
    expect(
      result.stdout,
      contains('prod     BASE_URL     https://prod.demo.test/api'),
    );
  });

  test('from a subfolder the nearest pubspec.yaml is the project', () async {
    project();
    final sub = Directory(p.join(temp.path, 'lib', 'src'))
      ..createSync(recursive: true);
    final result = await tool(['--list'], cwd: sub.path);
    expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
    expect(result.stdout, contains('Demo App (DemoApp)'));
  });

  test(
    'a bad command line exits 2 with the example of the package command',
    () async {
      project();
      final result = await tool(['apk', 'staging'], cwd: temp.path);
      expect(result.exitCode, 2);
      expect(
        result.stderr,
        contains('Example: dart run flutter_build_tools apk release preprod'),
      );
    },
  );

  test('--dry-run prints the plan and builds nothing', () async {
    project();
    final result = await tool(['web', 'dev', '--dry-run'], cwd: temp.path);
    // The temp folder is not a git repository, which is only a warning here.
    expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
    expect(result.stdout, contains('DemoApp-dev-v2.1.0.zip'));
    expect(result.stdout, contains('flutter build web'));
    expect(Directory(p.join(temp.path, 'dist')).existsSync(), isFalse);
    expect(Directory(p.join(temp.path, 'build')).existsSync(), isFalse);
  });
}
