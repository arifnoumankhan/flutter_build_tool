// The AppEnv class that init writes: it must be valid Dart that passes the
// lints of a Flutter app, the lines init prints for main.dart must compile
// against it, and its startup guard must do what it says.
//
// The checks run on a scratch package that has a stub of
// package:flutter/foundation.dart (kReleaseMode is defined as Flutter defines
// it, `bool.fromEnvironment('dart.vm.product')`), so no Flutter SDK is needed.
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'package:flutter_build_tools/src/cli.dart';
import 'fakes.dart';

/// Where the `lints` package of this package's own dependencies lives.
String _lintsRoot() {
  final file = File(
    p.join(Directory.current.path, '.dart_tool', 'package_config.json'),
  );
  final config = jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
  for (final entry in (config['packages'] as List<Object?>)) {
    final package = entry as Map<String, Object?>;
    if (package['name'] == 'lints') {
      return file.uri.resolve(package['rootUri'] as String).toFilePath();
    }
  }
  throw StateError('lints is not in ${file.path}');
}

Future<ProcessResult> _dart(List<String> args, {required String cwd}) =>
    Process.run(
      Platform.resolvedExecutable,
      args,
      workingDirectory: cwd,
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
    );

void main() {
  late Directory temp;
  late String app;
  late String packages;

  /// The AppEnv text that `init` writes for a project of the fake world.
  Future<String> generated() async {
    final world = TestWorld();
    expect(await runBuildTool(['init'], world.env), 0);
    return world.fs.readString(world.abs('lib/app_env.dart'));
  }

  setUpAll(() async {
    temp = Directory.systemTemp.createTempSync('fbt_app_env_');
    final stub = p.join(temp.path, 'stub_flutter');
    Directory(p.join(stub, 'lib')).createSync(recursive: true);
    File(
      p.join(stub, 'pubspec.yaml'),
    ).writeAsStringSync('name: flutter\nenvironment:\n  sdk: ^3.8.0\n');
    File(p.join(stub, 'lib', 'foundation.dart')).writeAsStringSync(
      "const bool kReleaseMode = bool.fromEnvironment('dart.vm.product');\n"
      'void debugPrint(String? message) {}\n',
    );

    app = p.join(temp.path, 'app');
    Directory(p.join(app, 'lib')).createSync(recursive: true);
    Directory(p.join(app, '.dart_tool')).createSync(recursive: true);
    File(p.join(app, 'pubspec.yaml')).writeAsStringSync(
      'name: scratch_app\nenvironment:\n  sdk: ^3.8.0\n'
      'dependencies:\n  flutter:\n    path: ../stub_flutter\n',
    );
    File(p.join(app, 'analysis_options.yaml')).writeAsStringSync(
      'include: package:lints/recommended.yaml\n'
      'analyzer:\n  language:\n    strict-casts: true\n    strict-raw-types: true\n',
    );
    packages = p.join(app, '.dart_tool', 'package_config.json');
    File(packages).writeAsStringSync(
      jsonEncode({
        'configVersion': 2,
        'packages': [
          {
            'name': 'flutter',
            'rootUri': p.toUri(stub).toString(),
            'packageUri': 'lib/',
            'languageVersion': '3.8',
          },
          {
            'name': 'lints',
            'rootUri': p.toUri(_lintsRoot()).toString(),
            'packageUri': 'lib/',
            'languageVersion': '3.8',
          },
          {
            'name': 'scratch_app',
            'rootUri': '../',
            'packageUri': 'lib/',
            'languageVersion': '3.8',
          },
        ],
      }),
    );

    File(
      p.join(app, 'lib', 'app_env.dart'),
    ).writeAsStringSync(await generated());
    // The lines init prints for main.dart, in a main().
    File(p.join(app, 'lib', 'main.dart')).writeAsStringSync('''
import 'package:flutter/foundation.dart';
import 'package:scratch_app/app_env.dart';

void main() {
  AppEnv.ensureValid();
  debugPrint(AppEnv.summary);
  debugPrint(AppEnv.name + AppEnv.baseUrl + AppEnv.buildSha);
}
''');
    File(p.join(app, 'lib', 'probe.dart')).writeAsStringSync('''
import 'package:flutter/foundation.dart';

void main() => print(kReleaseMode);
''');
  });

  tearDownAll(() => temp.deleteSync(recursive: true));

  test(
    'the file and the main.dart lines pass dart analyze with lints/recommended',
    () async {
      final result = await _dart([
        'analyze',
        '--fatal-infos',
        '--fatal-warnings',
      ], cwd: app);
      expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
      expect(result.stdout, contains('No issues found!'));
    },
  );

  group('an env folder that needs escaping', () {
    // What a project may put in `envDir`: it goes into a `///` comment and a
    // single-quoted string of the generated file.
    const folders = <String>[
      "cfg/it's",
      r'cfg/$env',
      r'cfg/a${b}c',
      r'cfg\users',
      r'cfg\win',
      'cfg\nlines',
      r"a\new$x'q",
    ];

    Future<String> generatedFor(String folder) async {
      final world = TestWorld();
      world.fs.put(
        world.abs('tool/build/build_config.json'),
        jsonEncode({'envDir': folder}),
      );
      expect(
        await runBuildTool(['init'], world.env),
        0,
        reason: world.console.allText,
      );
      return world.fs.readString(world.abs('lib/app_env.dart'));
    }

    setUpAll(() async {
      for (var i = 0; i < folders.length; i++) {
        File(
          p.join(app, 'lib', 'env_dir_$i.dart'),
        ).writeAsStringSync(await generatedFor(folders[i]));
      }
      // A main that stops on the last folder, to read the message it prints.
      File(p.join(app, 'lib', 'env_dir_main.dart')).writeAsStringSync('''
import 'package:scratch_app/env_dir_${folders.length - 1}.dart';

void main() => AppEnv.ensureValid();
''');
    });

    test('every file is valid Dart that passes the lints', () async {
      final result = await _dart([
        'analyze',
        '--fatal-infos',
        '--fatal-warnings',
      ], cwd: app);
      expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
      expect(result.stdout, contains('No issues found!'));
    });

    test('the message names the folder as it is', () async {
      final result = await _dart([
        '--packages=$packages',
        '-Ddart.vm.product=true',
        p.join(app, 'lib', 'env_dir_main.dart'),
      ], cwd: app);
      expect(result.exitCode, isNot(0));
      expect(
        result.stderr,
        contains(r"--dart-define-from-file=a\new$x'q/<env>.json"),
      );
    });
  });

  group('the startup guard', () {
    Future<ProcessResult> main_(List<String> defines) => _dart([
      '--packages=$packages',
      ...defines,
      p.join(app, 'lib', 'main.dart'),
    ], cwd: app);

    const release = '-Ddart.vm.product=true';

    setUpAll(() async {
      final probe = await _dart([
        '--packages=$packages',
        release,
        p.join(app, 'lib', 'probe.dart'),
      ], cwd: app);
      expect(
        probe.stdout.toString().trim(),
        'true',
        reason:
            'this SDK does not take dart.vm.product from -D: '
            '${probe.stdout}${probe.stderr}',
      );
    });

    test(
      'is a no-op in debug and profile: a plain run needs no env file',
      () async {
        final result = await main_([]);
        expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
        expect(result.stderr, isEmpty);
      },
    );

    test('stops a release build without APP_ENV and BASE_URL', () async {
      final result = await main_([release]);
      expect(result.exitCode, isNot(0));
      final err = result.stderr as String;
      expect(
        err,
        contains(
          'Bad state: AppEnv: this release build has no APP_ENV and BASE_URL.',
        ),
      );
      expect(err, contains('"dart run flutter_build_tools <platform> <env>"'));
      expect(err, contains('--dart-define-from-file=config/env/<env>.json'));
    });

    test('names the one that is missing', () async {
      final noUrl = await main_([release, '-DAPP_ENV=dev']);
      expect(noUrl.exitCode, isNot(0));
      expect(noUrl.stderr, contains('has no BASE_URL.'));
      expect(noUrl.stderr, isNot(contains('has no APP_ENV')));
      final noEnv = await main_([release, '-DBASE_URL=https://x.test']);
      expect(noEnv.exitCode, isNot(0));
      expect(noEnv.stderr, contains('has no APP_ENV.'));
      expect(noEnv.stderr, isNot(contains('has no BASE_URL')));
    });

    test('lets a complete release build through', () async {
      final result = await main_([
        release,
        '-DAPP_ENV=dev',
        '-DBASE_URL=https://dev.example.com',
      ]);
      expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
    });
  });
}
