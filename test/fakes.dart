// Test doubles for the build tool: in-memory file system, scripted process
// runner and console, bundled in [TestWorld] with a seeded repository.
import 'dart:async';
import 'dart:convert';
import 'dart:io' show FileSystemException, OSError;

import 'package:flutter_build_tools/src/environment.dart';
import 'package:flutter_build_tools/src/fs.dart';
import 'package:flutter_build_tools/src/model.dart';
import 'package:flutter_build_tools/src/runner.dart';

/// Files and folders in a map; paths are compared as exact strings, so tests
/// can use Windows-style paths on any machine.
class MemoryFs implements BuildFs {
  MemoryFs({this.separator = '/', this.tempRoot = '/tmp'});

  final String separator;
  final String tempRoot;
  final Map<String, List<int>> files = {};
  final Set<String> dirs = {};
  int _temp = 0;

  bool _under(String path, String dir) => path.startsWith('$dir$separator');

  void _registerParents(String path) {
    var index = path.lastIndexOf(separator);
    while (index > 0) {
      dirs.add(path.substring(0, index));
      index = path.lastIndexOf(separator, index - 1);
    }
  }

  void put(String path, Object content) {
    files[path] = content is String
        ? utf8.encode(content)
        : List<int>.of(content as List<int>);
    _registerParents(path);
  }

  @override
  bool fileExists(String path) => files.containsKey(path);

  @override
  bool dirExists(String path) =>
      dirs.contains(path) || files.keys.any((f) => _under(f, path));

  @override
  String readString(String path) => utf8.decode(readBytes(path));

  @override
  List<int> readBytes(String path) =>
      files[path] ?? (throw StateError('MemoryFs: no file $path'));

  @override
  Stream<List<int>> openRead(String path) async* {
    final bytes = readBytes(path);
    for (var i = 0; i < bytes.length; i += 7) {
      yield bytes.sublist(i, i + 7 > bytes.length ? bytes.length : i + 7);
    }
  }

  @override
  int length(String path) => readBytes(path).length;

  @override
  void createDir(String path) {
    dirs.add(path);
    _registerParents(path);
  }

  @override
  void writeString(String path, String content) => put(path, content);

  @override
  void writeBytes(String path, List<int> bytes) => put(path, bytes);

  @override
  void deleteFile(String path) => files.remove(path);

  @override
  void deleteDir(String path) {
    files.removeWhere((file, _) => _under(file, path));
    dirs.removeWhere((dir) => dir == path || _under(dir, path));
  }

  @override
  void copyFile(String from, String to) => put(to, readBytes(from));

  @override
  List<String> listFiles(String dir, {bool recursive = false}) => [
    for (final file in files.keys)
      if (_under(file, dir) &&
          (recursive || !file.substring(dir.length + 1).contains(separator)))
        file,
  ]..sort();

  @override
  String? findFile(String root, String name) {
    final matches =
        files.keys
            .where(
              (f) =>
                  _under(f, root) &&
                  f.split(separator).last.toLowerCase() == name.toLowerCase(),
            )
            .toList()
          ..sort();
    return matches.isEmpty ? null : matches.first;
  }

  @override
  String createTempDir(String prefix) {
    final path = '$tempRoot$separator$prefix${_temp++}';
    createDir(path);
    return path;
  }

  /// Copy of the current state, to prove nothing changed.
  Map<String, String> snapshot() => {
    for (final e in files.entries) e.key: base64.encode(e.value),
    for (final d in dirs) '$d/': 'dir',
  };
}

/// A file system that cannot be written at the paths [denied] says (a folder
/// without permission, or a file where a folder should be): the write throws a
/// [FileSystemException] like the real disk does.
class DenyingFs extends MemoryFs {
  DenyingFs(this.denied, {super.separator, super.tempRoot});

  final bool Function(String path) denied;

  void _check(String path) {
    if (denied(path)) {
      throw FileSystemException(
        'Creation failed',
        path,
        OSError('Permission denied', 13),
      );
    }
  }

  @override
  void writeString(String path, String content) {
    _check(path);
    super.writeString(path, content);
  }

  @override
  void writeBytes(String path, List<int> bytes) {
    _check(path);
    super.writeBytes(path, bytes);
  }
}

class _Handler<T> {
  _Handler(this.matches, this.run);

  final bool Function(ProcessSpec) matches;
  final FutureOr<T> Function(ProcessSpec) run;
}

/// Records every command; answers from scripted handlers (first match wins).
/// Unscripted `stream` calls succeed with exit 0; unscripted `capture` calls
/// fail like a missing executable.
class FakeRunner implements ProcessRunner {
  final List<ProcessSpec> calls = [];
  final List<_Handler<int>> _streamHandlers = [];
  final List<_Handler<CapturedProcess>> _captureHandlers = [];

  /// Only the commands run through [stream] (the long builds).
  final List<ProcessSpec> streamed = [];

  /// [first] puts the handler ahead of the ones registered before.
  void onStream(
    bool Function(ProcessSpec) matches,
    FutureOr<int> Function(ProcessSpec) run, {
    bool first = false,
  }) {
    final handler = _Handler(matches, run);
    first ? _streamHandlers.insert(0, handler) : _streamHandlers.add(handler);
  }

  /// [first] puts the handler ahead of the ones registered before (for
  /// overriding the defaults).
  void onCapture(
    bool Function(ProcessSpec) matches,
    CapturedProcess Function(ProcessSpec) run, {
    bool first = false,
  }) {
    final handler = _Handler(matches, run);
    first ? _captureHandlers.insert(0, handler) : _captureHandlers.add(handler);
  }

  /// Scripts git and `flutter --version --machine`.
  void scriptDefaults({String sha = 'abc1234', bool dirty = false}) {
    onCapture(
      (s) => s.executable == 'git' && s.args.first == 'rev-parse',
      (_) => CapturedProcess(0, '$sha\n', ''),
    );
    onCapture(
      (s) => s.executable == 'git' && s.args.first == 'status',
      (_) => CapturedProcess(0, dirty ? ' M lib/main.dart\n' : '', ''),
    );
    onCapture(
      (s) => s.executable == 'flutter' && s.args.first == '--version',
      (_) => const CapturedProcess(
        0,
        '{"frameworkVersion":"3.47.0","channel":"stable","dartSdkVersion":"3.13.0"}\n',
        '',
      ),
    );
  }

  @override
  Future<int> stream(ProcessSpec spec) async {
    calls.add(spec);
    streamed.add(spec);
    for (final handler in _streamHandlers) {
      if (handler.matches(spec)) return handler.run(spec);
    }
    return 0;
  }

  @override
  Future<CapturedProcess> capture(ProcessSpec spec) async {
    calls.add(spec);
    for (final handler in _captureHandlers) {
      if (handler.matches(spec)) return handler.run(spec);
    }
    throw ProcessStartException(spec, 'not scripted in this test');
  }
}

class FakeConsole implements Console {
  FakeConsole({this.interactive = false, List<String> inputs = const []})
    : _inputs = List.of(inputs);

  final bool interactive;
  final List<String> _inputs;
  final List<String> outLines = [];
  final List<String> errLines = [];
  final List<String> prompts = [];

  String get stdoutText => outLines.join('\n');
  String get stderrText => errLines.join('\n');
  String get allText => '$stdoutText\n$stderrText';

  @override
  void out(String line) => outLines.add(line);

  @override
  void err(String line) => errLines.add(line);

  @override
  bool get isInteractive => interactive;

  @override
  void prompt(String text) => prompts.add(text);

  @override
  String? readLine() => _inputs.isEmpty ? null : _inputs.removeAt(0);
}

/// The project facts of the fake repository (`tool/build/build_config.json`).
const exampleAppConfig = {
  'app': 'admin',
  'slug': 'ExampleApp',
  'displayName': 'Example App',
  'envDir': 'config/env',
  'windows': {
    'exe': 'example_app.exe',
    'installerScript': 'installer/example_app.iss',
    'cleanupPrefix': 'Example',
  },
  'devHostMarkers': ['devexample'],
  'macos': {'appName': 'Example App'},
  'cli': {
    'docs': 'tool/build/README.md',
    'wrappers': [
      {'script': 'scripts/build.sh', 'label': 'macOS/Linux wrapper'},
      {'script': 'scripts/build.ps1', 'label': 'Windows wrapper'},
    ],
  },
};

const _envFiles = {
  'dev': {
    'APP_ENV': 'dev',
    'BASE_URL': 'https://devexample.example.com/public',
    'POS_WEB_URL': 'https://devexample.example.com/web_pos',
  },
  'preprod': {
    'APP_ENV': 'preprod',
    'BASE_URL': 'https://preprod.example.com/public',
    'POS_WEB_URL': 'https://preprod.example.com/public/web_pos',
  },
  'prod': {
    'APP_ENV': 'prod',
    'BASE_URL': 'https://v1.example.com/public',
    'POS_WEB_URL': 'https://pos.example.com',
  },
  'local': {
    'APP_ENV': 'local',
    'BASE_URL': 'http://127.0.0.1:8011',
    'POS_WEB_URL': 'http://127.0.0.1:8011/web_pos',
  },
};

const fixedNow = '2026-10-06T12:34:56Z';

/// `web/index.html` as `flutter create` writes it (Flutter's own template,
/// with the multi-line comment): `<base href>` is the placeholder Flutter
/// replaces at build time.
const stockIndexHtml = r'''<!DOCTYPE html>
<html>
<head>
  <!--
    If you are serving your web app in a path other than the root, change the
    href value below to reflect the base path you are serving from.

    The path provided below has to start and end with a slash "/" in order for
    it to work correctly.

    For more details:
    * https://developer.mozilla.org/en-US/docs/Web/HTML/Element/base

    This is a placeholder for base href that will be replaced by the value of
    the `--base-href` argument provided to `flutter build`.
  -->
  <base href="$FLUTTER_BASE_HREF">

  <meta charset="UTF-8">
  <meta content="IE=Edge" http-equiv="X-UA-Compatible">
  <meta name="description" content="A new Flutter project.">

  <!-- iOS meta tags & icons -->
  <meta name="mobile-web-app-capable" content="yes">
  <meta name="apple-mobile-web-app-status-bar-style" content="black">
  <meta name="apple-mobile-web-app-title" content="example_app">
  <link rel="apple-touch-icon" href="icons/Icon-192.png">

  <!-- Favicon -->
  <link rel="icon" type="image/png" href="favicon.png"/>

  <title>example_app</title>
  <link rel="manifest" href="manifest.json">
</head>
<body>
  <!--
    You can customize the "flutter_bootstrap.js" script.
    This is useful to provide a custom configuration to the Flutter loader
    or to give the user feedback during the initialization process.

    For more details:
    * https://docs.flutter.dev/platform-integration/web/initialization
  -->
  <script src="flutter_bootstrap.js" async></script>
</body>
</html>
''';

/// A repository on a fake machine: environment, file system, runner, console.
class TestWorld {
  TestWorld({
    this.host = HostOs.macos,
    bool dirty = false,
    bool interactive = false,
    List<String> inputs = const [],
    Map<String, String> vars = const {},
  }) : fs = MemoryFs(
         separator: host == HostOs.windows ? r'\' : '/',
         tempRoot: host == HostOs.windows ? r'C:\Temp' : '/tmp',
       ),
       runner = FakeRunner(),
       console = FakeConsole(interactive: interactive, inputs: inputs) {
    runner.scriptDefaults(dirty: dirty);
    env = BuildEnvironment(
      root: host == HostOs.windows ? r'C:\repo' : '/repo',
      host: host,
      vars: vars,
      fs: fs,
      runner: runner,
      console: console,
      now: () => DateTime.utc(2026, 10, 6, 12, 34, 56),
      sleep: (d) async => sleeps.add(d),
    );
    seedRepo();
  }

  final HostOs host;
  final MemoryFs fs;
  final FakeRunner runner;
  final FakeConsole console;
  late final BuildEnvironment env;
  final List<Duration> sleeps = [];

  String abs(String relative) => env.abs(relative);

  /// The environment of this world on [other] instead of its own file system,
  /// holding the same files: for a test that needs a disk that misbehaves.
  BuildEnvironment envOn(MemoryFs other) {
    other
      ..files.addAll(fs.files)
      ..dirs.addAll(fs.dirs);
    return BuildEnvironment(
      root: env.root,
      host: host,
      vars: env.vars,
      fs: other,
      runner: runner,
      console: console,
      now: env.now,
      sleep: env.sleep,
    );
  }

  /// Writes pubspec, app config, the four env files, web/index.html and the
  /// Inno script, like a real checkout.
  void seedRepo({String version = '1.0.47+47'}) {
    fs.put(
      abs('pubspec.yaml'),
      'name: example_app\nversion: $version\n\ndependencies:\n  flutter:\n    sdk: flutter\n  version: ^1.0.0\ndev_dependencies:\n  msix: ^3.16.12\n',
    );
    fs.put(abs('tool/build/build_config.json'), jsonEncode(exampleAppConfig));
    for (final entry in _envFiles.entries) {
      fs.put(abs('config/env/${entry.key}.json'), jsonEncode(entry.value));
    }
    fs.put(
      abs('web/index.html'),
      '<!DOCTYPE html>\n<!--  <base href="\$FLUTTER_BASE_HREF">-->\n  <base href="/web_admin/">\n',
    );
    fs.put(
      abs('installer/example_app.iss'),
      '#ifndef MyBuildMode\n#define MyBuildMode "Release"\n#endif\nOutputBaseFilename={#MyOutputName}\n',
    );
  }

  /// Replaces `tool/build/build_config.json`.
  void writeConfig(Map<String, Object?> config) =>
      fs.put(abs('tool/build/build_config.json'), jsonEncode(config));

  /// Replaces one env file.
  void writeEnvFile(String env, Map<String, Object?> content) =>
      fs.put(abs('config/env/$env.json'), jsonEncode(content));

  /// Makes `flutter build <target>` succeed and leave [outputs] behind.
  void flutterBuilds(
    String target,
    Map<String, Object> outputs, {
    void Function(ProcessSpec)? inspect,
  }) {
    runner.onStream(
      (s) =>
          s.executable == 'flutter' &&
          s.args.first == 'build' &&
          s.args[1] == target,
      (s) {
        inspect?.call(s);
        outputs.forEach(fs.put);
        return 0;
      },
    );
  }

  /// A valid release keystore in android/key.properties.
  void seedKeystore({bool optIn = false}) {
    fs.put(
      abs('android/key.properties'),
      'storePassword=secret-store\nkeyPassword=secret-key\nkeyAlias=release\nstoreFile=../release.jks\n${optIn ? 'useReleaseSigning=true\n' : ''}',
    );
    fs.put(abs('android/release.jks'), 'jks');
  }
}
