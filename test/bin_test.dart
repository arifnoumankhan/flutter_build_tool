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

  test('outside a Flutter project it says so and exits 2', () async {
    // The system temp folder has no pubspec.yaml above it.
    final result = await tool(['--list'], cwd: temp.path);
    expect(result.exitCode, 2, reason: '${result.stdout}${result.stderr}');
    expect(result.stderr, contains('error: no pubspec.yaml in '));
    expect(result.stderr, contains('or any parent folder.'));
    expect(result.stdout, isEmpty);
  });

  test('--help works in a project that has no build config yet', () async {
    File(p.join(temp.path, 'pubspec.yaml')).writeAsStringSync('name: demo\n');
    final result = await tool(['--help'], cwd: temp.path);
    expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
    expect(result.stdout, startsWith('Flutter build tool: one command'));
    expect(result.stdout, contains('dart run flutter_build_tools <platform>'));
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
