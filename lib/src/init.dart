/// The `init` command: writes every file a Flutter project needs to be built
/// with this tool, inferred from the project itself.
///
/// It creates only what is missing (an existing file is skipped unless
/// `--force`), reads and writes through [BuildFs], and never touches
/// `lib/main.dart`. The `AppEnv` class is part of it unless `--no-app-env`.
library;

import 'dart:convert';
import 'dart:io' show FileSystemException;

import 'package:flutter_build_tools/src/config.dart';
import 'package:flutter_build_tools/src/env_file.dart';
import 'package:flutter_build_tools/src/environment.dart';
import 'package:flutter_build_tools/src/fs.dart';
import 'package:flutter_build_tools/src/inference.dart';
import 'package:flutter_build_tools/src/model.dart';
import 'package:flutter_build_tools/src/options.dart';
import 'package:flutter_build_tools/src/runner.dart';

/// What `init` was asked to do.
class InitOptions {
  /// Creates the options; the defaults are a plain `init`.
  const InitOptions({
    this.force = false,
    this.dryRun = false,
    this.appEnv = true,
  });

  /// Overwrite files that already exist (the default skips them).
  final bool force;

  /// List what would be written and write nothing.
  final bool dryRun;

  /// Write `AppEnv`, a small class that reads `APP_ENV` and `BASE_URL` (the
  /// default; `false` is `--no-app-env`).
  final bool appEnv;
}

/// One file `init` may write.
class _Item {
  const _Item(
    this.path,
    this.content, {
    this.executable = false,
    this.buildEnv,
    this.keepsSettings = false,
    this.kept,
  });

  /// '/'-separated, relative to the project root.
  final String path;
  final String content;
  final bool executable;

  /// Set for an env file: its environment. Overwriting an existing one resets
  /// `APP_ENV` and `BASE_URL` only and keeps every other key.
  final BuildEnv? buildEnv;

  /// True when overwriting loses nothing the project wrote: the config and the
  /// env files keep its keys, and `AppEnv` is only ever replaced when it is
  /// `init`'s own text. Nothing is said about replaced content.
  final bool keepsSettings;

  /// Set when `init` must not write the file, not even with `--force`: the
  /// reason, as it is reported. Used for a file of the project's (its own
  /// `AppEnv`, or a file where `AppEnv` would go), which `init` never replaces.
  final String? kept;
}

/// The wrapper scripts: thin, so the tool stays one command.
const String _shellWrapper = r'''#!/usr/bin/env bash
# Thin wrapper over flutter_build_tools (written by `dart run flutter_build_tools init`).
#   scripts/build.sh <platform> <env> [mode] [options]
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
exec dart run flutter_build_tools "$@"
''';

const String _powerShellWrapper =
    r'''# Thin wrapper over flutter_build_tools (written by `dart run flutter_build_tools init`).
#   scripts\build.ps1 <platform> <env> [mode] [options]
$ErrorActionPreference = 'Stop'
Set-Location (Join-Path $PSScriptRoot '..')
dart run flutter_build_tools @args
exit $LASTEXITCODE
''';

/// The `AppEnv` class `init` writes, with [_envDirToken] and
/// [_envDirLiteralToken] standing for the folder of the env files.
///
/// `name`, `baseUrl`, `buildSha` and `summary` are what the first version of
/// the class had, and apps read them: they stay as they are.
const String _appEnvTemplate =
    r'''import 'package:flutter/foundation.dart' show kReleaseMode;

/// Build-time settings, compiled in by `flutter_build_tools` from the env file
/// of the environment that was built (`--dart-define-from-file`).
///
/// Call [ensureValid] first in `main()`. Running from the IDE or `flutter run`
/// passes no env file unless you add one, and then [name] and [baseUrl] are
/// empty: `flutter run --dart-define-from-file=@ENV_DIR@/dev.json`.
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

  /// Stops a release build that was made without an env file.
  ///
  /// Throws a [StateError] in a release build when [name] or [baseUrl] is
  /// empty. Does nothing in debug and profile builds, so a plain `flutter run`
  /// keeps working (with an empty [baseUrl]).
  static void ensureValid() {
    if (!kReleaseMode) return;
    final missing = [
      if (name.isEmpty) 'APP_ENV',
      if (baseUrl.isEmpty) 'BASE_URL',
    ];
    if (missing.isEmpty) return;
    throw StateError(
      'AppEnv: this release build has no ${missing.join(' and ')}. APP_ENV and '
      'BASE_URL come from the env file of the build: build with '
      '"dart run flutter_build_tools <platform> <env>", or pass '
      '--dart-define-from-file=@ENV_DIR_LITERAL@/<env>.json to flutter build.',
    );
  }
}
''';

/// The place of the env folder in a comment of [_appEnvTemplate].
const String _envDirToken = '@ENV_DIR@';

/// The place of the env folder in a single-quoted string of
/// [_appEnvTemplate].
const String _envDirLiteralToken = '@ENV_DIR_LITERAL@';

/// The text of the `AppEnv` file for a project whose env files are in
/// [envDir]. The folder is the project's own text, so it is made safe for the
/// two places it goes to: a line break would end the comment, and a quote, a
/// `$` or a `\` would change the string literal.
String _appEnvSource(String envDir) {
  final comment = envDir.replaceAll(RegExp(r'[\r\n]'), ' ');
  final literal = envDir
      .replaceAll(r'\', r'\\')
      .replaceAll("'", r"\'")
      .replaceAll(r'$', r'\$')
      .replaceAll('\n', r'\n')
      .replaceAll('\r', r'\r');
  return _appEnvTemplate.replaceAllMapped(
    RegExp('$_envDirLiteralToken|$_envDirToken'),
    (match) => match[0] == _envDirToken ? comment : literal,
  );
}

/// [text] with CRLF line endings as LF, so a file that a checkout with
/// `autocrlf` converted still equals the text `init` wrote.
String _lf(String text) => text.replaceAll('\r\n', '\n');

/// The text `--app-env` of 0.2.0 wrote. It is init's own, so `--force`
/// replaces it without calling it custom content, and a file that still holds
/// it is the one that has no `ensureValid`.
const String _appEnvSourceV020 =
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

/// A line that declares a type called `AppEnv`: a class (with any modifiers),
/// an enum, a mixin, an extension type or a typedef. Anchored to the start of
/// the line, so a commented-out declaration, `AppEnvironment` and `AppEnv2` do
/// not count.
final RegExp _appEnvDeclaration = RegExp(
  r'^[ \t]*(?:(?:abstract|base|final|interface|sealed)[ \t]+)*'
  r'(?:mixin[ \t]+class|class|enum|mixin|typedef|extension[ \t]+type(?:[ \t]+const)?)'
  r'[ \t]+AppEnv(?![\w$])',
  multiLine: true,
);

/// True when the Dart [source] declares a type called `AppEnv` (a class, enum,
/// mixin, extension type or typedef), which `init` must not define a second
/// time.
bool declaresAppEnv(String source) => _appEnvDeclaration.hasMatch(source);

String _json(Map<String, Object?> value) =>
    '${const JsonEncoder.withIndent('  ').convert(value)}\n';

/// The `BASE_URL` `init` writes for [buildEnv].
String _placeholderUrl(BuildEnv buildEnv) => buildEnv.isLocal
    ? 'http://127.0.0.1'
    : 'https://${buildEnv.name}.$placeholderDomain';

/// An env file: `APP_ENV` and the placeholder `BASE_URL`, on top of the keys
/// of the [existing] file when `--force` replaces one (`POS_WEB_URL` and the
/// project's own `envFile.extraKeys` / `extraUrlKeys` are not init's to
/// reset).
String _envFileText(BuildEnv buildEnv, [Map<String, Object?>? existing]) {
  final merged = <String, Object?>{...?existing};
  merged['APP_ENV'] = buildEnv.name;
  merged['BASE_URL'] = _placeholderUrl(buildEnv);
  return _json(merged);
}

/// The content of the config file `init` writes: the inferred facts, then the
/// keys of the [existing] file (when `--force` replaces a working one) on top,
/// so no explicit setting is lost.
String _configText(ProjectFacts facts, Map<String, Object?>? existing) {
  Map<String, Object?> section(Object? value) =>
      value is Map<String, Object?> ? {...value} : <String, Object?>{};

  final windows = <String, Object?>{
    'exe': ?facts.windowsExe,
    'installerScript': ?facts.installerScript,
    ...section(existing?['windows']),
  };
  final macos = <String, Object?>{
    'appName': ?facts.macosAppName,
    ...section(existing?['macos']),
  };
  final known = <String, Object?>{
    r'$comment':
        'Facts of this project for flutter_build_tools, written by "dart run flutter_build_tools init" from pubspec.yaml, windows/, macos/ and installer/. Edit freely: a key set here wins over what the tool infers. Keys starting with \$ or _ are ignored. See the "build_config.json" section of the flutter_build_tools README.',
    'app': defaultAppId,
    'slug': facts.slug,
    'displayName': facts.displayName,
    'envDir': defaultEnvDirectory,
    if (windows.isNotEmpty) 'windows': windows,
    if (macos.isNotEmpty) 'macos': macos,
  };
  final result = <String, Object?>{...known};
  for (final entry in (existing ?? const <String, Object?>{}).entries) {
    if (entry.key == 'windows' || entry.key == 'macos') continue;
    result[entry.key] = entry.value;
  }
  return _json(result);
}

/// Runs `init` for the project of [env] and returns the exit code (0 ok, 1
/// when the project cannot be read). [invocation] is the command shown in the
/// next steps.
Future<int> runInit(
  BuildEnvironment env,
  InitOptions options, {
  String invocation = BuildToolOptions.defaultInvocation,
}) async {
  final console = env.console;
  final facts = inferProjectFacts(fs: env.fs, path: env.path, root: env.root);
  final name = facts.pubspecName;
  if (name == null) {
    throw BuildException(
      'pubspec.yaml has no top-level "name:", so nothing can be inferred. Add the name (for example "name: my_app") and run init again.',
    );
  }

  // An existing config may already move the env folder or hold extra keys.
  final configFile = env.abs(AppConfig.configPath);
  final configExists = env.fs.fileExists(configFile);
  Map<String, Object?>? existing;
  if (configExists) {
    try {
      final decoded = jsonDecode(env.fs.readString(configFile));
      if (decoded is Map<String, Object?>) existing = decoded;
    } on FormatException {
      existing = null;
    }
    if (existing == null && !options.force) {
      throw BuildException(
        '${AppConfig.configPath} exists but is not a JSON object, so init cannot read where your env files are. Fix it, or run init --force to replace it with the inferred facts.',
      );
    }
  }
  // The effective env folder: the file's own when it has one.
  final fileEnvDir = existing?['envDir'];
  final envDir = fileEnvDir is String && fileEnvDir.trim().isNotEmpty
      ? fileEnvDir
      : defaultEnvDirectory;

  // AppEnv is written unless --no-app-env. A project that defines its own
  // AppEnv is never given a second one, and a file of the project's is never
  // replaced: only init's own text (this version's, or 0.2.0's) is.
  final appEnvText = _appEnvSource(envDir);
  final appEnvPlace = options.appEnv
      ? _locateAppEnv(env, initsOwn: [appEnvText, _appEnvSourceV020])
      : null;

  final items = <_Item>[
    _Item(
      AppConfig.configPath,
      _configText(facts, existing),
      keepsSettings: true,
    ),
    for (final buildEnv in BuildEnv.values)
      _Item(
        '$envDir/${buildEnv.name}.json',
        _envFileText(buildEnv),
        buildEnv: buildEnv,
        keepsSettings: true,
      ),
    const _Item('scripts/build.sh', _shellWrapper, executable: true),
    const _Item('scripts/build.ps1', _powerShellWrapper),
    if (appEnvPlace != null)
      _Item(
        appEnvPlace.path,
        appEnvText,
        keepsSettings: true,
        kept: appEnvPlace.kept,
      ),
  ];

  console.out(
    'init${options.dryRun ? ' (dry run: nothing is written)' : ''}: ${facts.displayName} ($name)',
  );
  console.out('');

  final created = <String>[];
  final skipped = <String>[];
  final overwritten = <String>[];
  var executableFailed = false;
  void report(String verb, String path, [String note = '']) =>
      console.out('  ${verb.padRight(15)} $path$note');
  for (final item in items) {
    final absolute = env.abs(item.path);
    final kept = item.kept;
    if (kept != null) {
      skipped.add(item.path);
      report('skipped', item.path, ' ($kept)');
      continue;
    }
    final exists = env.fs.fileExists(absolute);
    if (exists && !options.force) {
      skipped.add(item.path);
      report('skipped', item.path, ' (exists; --force overwrites it)');
      continue;
    }
    // What an overwrite changes, said before the file is touched so a dry run
    // shows it too: the real URL an env file loses (its other keys are kept),
    // or that a script that is not init's own text is replaced.
    var content = item.content;
    var note = '';
    if (exists) {
      final old = env.fs.readString(absolute);
      final buildEnv = item.buildEnv;
      if (buildEnv != null) {
        final oldValues = _jsonObject(old);
        content = _envFileText(buildEnv, oldValues);
        final previous = oldValues?['BASE_URL'];
        // A placeholder, or what the new file says too, is not worth a note.
        if (previous is String &&
            !isPlaceholderUrl(previous) &&
            previous != _placeholderUrl(buildEnv)) {
          note = ' (BASE_URL was $previous)';
        }
        if (oldValues == null) note = ' (custom content replaced)';
      } else if (!item.keepsSettings && _lf(old) != _lf(item.content)) {
        note = ' (custom content replaced)';
      }
    }
    if (options.dryRun) {
      report(exists ? 'would overwrite' : 'would create', item.path, note);
      (exists ? overwritten : created).add(item.path);
      continue;
    }
    try {
      env.fs.writeString(absolute, content);
    } on FileSystemException catch (e) {
      final written = [...created, ...overwritten];
      // The class is the one file of init that lives in the project's source:
      // when it cannot be written, there is a way to do without it.
      final skipClass = item.path == appEnvPlace?.path
          ? ' Or run init --no-app-env to skip the AppEnv class.'
          : '';
      throw BuildException(
        'could not write ${item.path}: ${fileProblem(e)}. ${written.isEmpty ? 'Nothing was written.' : 'Already written: ${written.join(', ')}.'} Fix the path (permissions, or a file where a folder should be) and run init again; without --force it only creates what is missing.$skipClass',
      );
    }
    if (item.executable && env.host != HostOs.windows) {
      executableFailed |= !await _makeExecutable(env, absolute);
    }
    (exists ? overwritten : created).add(item.path);
    report(exists ? 'overwrote' : 'created', item.path, note);
  }
  console.out('');

  if (created.isEmpty && overwritten.isEmpty) {
    console.out(
      'Nothing to do: every file already exists (${skipped.length} skipped).',
    );
  } else if (options.dryRun) {
    console.out(
      '${created.length + overwritten.length} file(s) would be written, ${skipped.length} skipped.',
    );
  } else {
    console.out(
      '${created.length} created, ${overwritten.length} overwritten, ${skipped.length} skipped.',
    );
  }

  _printInferred(console, facts, configExists && !options.force);
  _printUndeclaredKeys(env, envDir, existing);
  if (executableFailed) {
    console.out('');
    console.out(
      'note: could not make scripts/build.sh executable; run: chmod +x scripts/build.sh',
    );
  }
  if (env.host == HostOs.windows && created.contains('scripts/build.sh')) {
    console.out('');
    console.out(
      'note: on Windows git cannot see the executable bit; after "git add" run: git update-index --chmod=+x scripts/build.sh',
    );
  }

  console.out('');
  console.out('Next steps');
  var step = 1;
  // Only the env files that still hold a placeholder need editing: the ones
  // init just wrote, and the existing ones nobody has edited yet.
  final toEdit = <String>[];
  for (final buildEnv in BuildEnv.values) {
    if (buildEnv.isLocal) continue;
    final path = '$envDir/${buildEnv.name}.json';
    final justWritten = created.contains(path) || overwritten.contains(path);
    final url = justWritten ? null : _baseUrlOfFile(env, path);
    if (justWritten || (url != null && isPlaceholderUrl(url))) {
      toEdit.add(path);
    }
  }
  if (toEdit.isNotEmpty) {
    console.out(
      '  ${step++}. Edit BASE_URL in ${toEdit.join(', ')} (a .invalid placeholder cannot be reached, and prod refuses it; local is http://127.0.0.1).',
    );
  }
  console.out('  ${step++}. $invocation --list');
  console.out(
    '  ${step++}. $invocation apk dev --dry-run   (then without --dry-run)',
  );
  if (appEnvPlace != null) {
    final path = appEnvPlace.path;
    final written = created.contains(path) || overwritten.contains(path);
    _printAppEnvHint(
      console,
      packageName: name,
      path: path,
      source: written ? appEnvText : _readOrNull(env, path),
    );
    if (!appEnvPlace.scanned && created.contains(path)) {
      console
        ..out('')
        ..out(
          'note: lib/ could not be read completely (a folder is not readable), so init could not check whether the project already defines an AppEnv. If it does, delete $path and use that class; give --no-app-env to skip the class.',
        );
    }
  }
  final gitignore = env.abs('.gitignore');
  final ignoresDist =
      env.fs.fileExists(gitignore) &&
      RegExp(
        r'^/?dist/?\s*$',
        multiLine: true,
      ).hasMatch(env.fs.readString(gitignore));
  if (!ignoresDist) {
    console.out('');
    console.out(
      'note: .gitignore does not ignore dist/ (where artifacts are written). Add the line "dist/", or the next prod build refuses the tree as dirty.',
    );
  }
  await _printGitIgnoredNotes(env, envDir);
  return 0;
}

/// The text of [relative], or null when it cannot be read (missing, or not
/// UTF-8).
String? _readOrNull(BuildEnvironment env, String relative) {
  final file = env.abs(relative);
  if (!env.fs.fileExists(file)) return null;
  try {
    return env.fs.readString(file);
  } on Exception {
    return null;
  }
}

/// The Dart files under `lib/` of [env], '/'-separated and sorted, and whether
/// the listing was complete. A folder that cannot be listed is "no files", not
/// a failure: `complete` is false then, and the files may be missing.
({List<String> files, bool complete}) _dartFilesUnderLib(BuildEnvironment env) {
  final List<String> files;
  try {
    files = env.fs.listFiles(env.abs('lib'), recursive: true);
  } on Exception {
    return (files: const [], complete: false);
  }
  return (
    files: [
      for (final file in files)
        if (file.endsWith('.dart')) env.rel(file),
    ]..sort(),
    complete: true,
  );
}

/// Why `init` keeps a class that the project defines (anywhere under `lib/`).
const String _keptOwnClass =
    'already defines AppEnv; init writes no second one';

/// Why `init` keeps a file at the place where it would write `AppEnv`.
const String _keptNoClass =
    'exists but defines no AppEnv; init does not replace it, not even with --force';

/// Where `AppEnv` lives in the project of [env], and whether `init` writes it.
///
/// `path` ('/'-separated) is `lib/config/app_env.dart` when the project has
/// `lib/config/`, else `lib/app_env.dart`; a copy that already exists in the
/// other place is the one to use (and to name in the `main.dart` import),
/// never a second class. When neither place declares an `AppEnv` and another
/// file under `lib/` does, that file is the project's own.
///
/// `kept` is set when `init` writes nothing at `path`, with or without
/// `--force`: the file is the project's, not one of [initsOwn] (the texts
/// `init` wrote, line endings aside), so replacing it would destroy source. It
/// is null when there is no file yet or the file holds only `init`'s own text.
/// `scanned` is false when `lib/` could not be listed completely, so a class
/// of the project's may have been missed.
({String path, String? kept, bool scanned}) _locateAppEnv(
  BuildEnvironment env, {
  required List<String> initsOwn,
}) {
  final hasConfigDir = env.fs.dirExists(env.abs('lib/config'));
  final preferred = hasConfigDir
      ? 'lib/config/app_env.dart'
      : 'lib/app_env.dart';
  final other = hasConfigDir ? 'lib/app_env.dart' : 'lib/config/app_env.dart';

  // The two places first: a class that is there is the one to use.
  for (final relative in [preferred, other]) {
    final text = _readOrNull(env, relative);
    if (text == null || !declaresAppEnv(text)) continue;
    final own = initsOwn.map(_lf).contains(_lf(text));
    return (path: relative, kept: own ? null : _keptOwnClass, scanned: true);
  }

  // Neither holds one: one look at the rest of lib/, which stops at the first
  // file that declares it.
  final listing = _dartFilesUnderLib(env);
  for (final relative in listing.files) {
    if (relative == preferred || relative == other) continue;
    final text = _readOrNull(env, relative);
    if (text != null && declaresAppEnv(text)) {
      return (path: relative, kept: _keptOwnClass, scanned: true);
    }
  }

  // None: init's file. A file that is already there and is not an AppEnv is
  // the project's (an enum of another name, say), so it stays.
  final path =
      !env.fs.fileExists(env.abs(preferred)) &&
          env.fs.fileExists(env.abs(other))
      ? other
      : preferred;
  return (
    path: path,
    kept: env.fs.fileExists(env.abs(path)) ? _keptNoClass : null,
    scanned: listing.complete,
  );
}

/// The `main.dart` lines for the `AppEnv` in [path], whose text is [source]
/// (null when it cannot be read). Only the members that [source] has are
/// shown: a file that is not the one `init` writes may lack them, and a line
/// that does not compile is worse than none. A file that defines no `AppEnv`
/// has no lines at all.
void _printAppEnvHint(
  Console console, {
  required String packageName,
  required String path,
  required String? source,
}) {
  console.out('');
  if (source == null || !declaresAppEnv(source)) {
    console.out(
      'note: $path exists but ${source == null ? 'cannot be read as text' : 'defines no AppEnv'}, so init wrote none and there is nothing to add to lib/main.dart. Delete or move it and run init again to get one (init does not replace it, not even with --force), or give --no-app-env to skip the class.',
    );
    return;
  }
  final hasGuard = RegExp(r'\bensureValid\s*\(').hasMatch(source);
  final hasSummary = RegExp(r'\bsummary\b').hasMatch(source);
  console.out(
    'To read the settings in the app (init never edits lib/main.dart), add to lib/main.dart:',
  );
  final importPath = path.substring('lib/'.length);
  console.out("    import 'package:$packageName/$importPath';");
  if (hasGuard || hasSummary) console.out('    // in main(), before runApp:');
  if (hasGuard) {
    console.out(
      '    AppEnv.ensureValid();   // a release build without APP_ENV or BASE_URL stops here',
    );
  }
  if (hasSummary) {
    console.out(
      '    debugPrint(AppEnv.summary);   // needs package:flutter/foundation.dart',
    );
  }
  if (!hasGuard) {
    console.out('');
    console.out(
      _lf(source) == _lf(_appEnvSourceV020)
          ? 'note: $path was written by an earlier init and has no ensureValid(), so a release build made without an env file is not stopped at startup. Delete it and run init again to get the one with the guard.'
          : 'note: $path is your own AppEnv and init did not change it. It has no ensureValid(), so a release build made without an env file is not stopped at startup; add one ("The AppEnv class" in the README shows it).',
    );
  }
}

/// The JSON object in [text]; null when it is not valid JSON or not an object
/// (the person has to look at such a file anyway).
Map<String, Object?>? _jsonObject(String text) {
  try {
    final decoded = jsonDecode(text);
    if (decoded is Map<String, Object?>) return decoded;
  } on FormatException {
    // Handled by the caller as "no object".
  }
  return null;
}

/// `BASE_URL` of an env file's [text]; null when it is not a JSON object with
/// a string `BASE_URL`.
String? _baseUrlIn(String text) {
  final url = _jsonObject(text)?['BASE_URL'];
  return url is String ? url : null;
}

/// `BASE_URL` of the env file at [relative]; null when the file is missing or
/// has none.
String? _baseUrlOfFile(BuildEnvironment env, String relative) {
  final file = env.abs(relative);
  return env.fs.fileExists(file) ? _baseUrlIn(env.fs.readString(file)) : null;
}

/// Lists the keys of the existing env files that the project's config does
/// not declare, which `--list` and every build refuse ("unknown key"), with
/// the snippet that declares them. It only lists: an env file is committed, so
/// whether a key is a secret is the person's decision, not init's.
void _printUndeclaredKeys(
  BuildEnvironment env,
  String envDir,
  Map<String, Object?>? existingConfig,
) {
  List<String> declared(String key) {
    final section = existingConfig?['envFile'];
    final list = section is Map<String, Object?> ? section[key] : null;
    return list is List<Object?> ? [for (final e in list) '$e'] : const [];
  }

  final accepted = {
    ...EnvSchema.standard.allowedKeys,
    ...generatedDefineKeys,
    ...declared('extraKeys'),
    ...declared('extraUrlKeys'),
  };
  final namePattern = RegExp(r'^[A-Z][A-Z0-9_]*$');
  // key -> the files that hold it, in file order.
  final files = <String, List<String>>{};
  final urlKeys = <String>{};
  for (final buildEnv in BuildEnv.values) {
    final path = '$envDir/${buildEnv.name}.json';
    final absolute = env.abs(path);
    if (!env.fs.fileExists(absolute)) continue;
    final values = _jsonObject(env.fs.readString(absolute));
    if (values == null) continue;
    for (final entry in values.entries) {
      if (accepted.contains(entry.key)) continue;
      files.putIfAbsent(entry.key, () => []).add(path);
      final value = entry.value;
      if (value is String && RegExp(r'^https?://').hasMatch(value)) {
        urlKeys.add(entry.key);
      }
    }
  }
  if (files.isEmpty) return;

  final console = env.console;
  console.out('');
  console.out(
    'Not accepted yet: these env file keys are not declared in ${AppConfig.configPath}, so --list and every build refuse the file:',
  );
  final width = files.keys.fold(0, (w, key) => key.length > w ? key.length : w);
  final plain = <String>[];
  final urls = <String>[];
  for (final entry in files.entries) {
    final declarable = namePattern.hasMatch(entry.key);
    console.out(
      '  ${entry.key.padRight(width)}  ${entry.value.join(', ')}${declarable ? '' : '   (cannot be declared: keys are UPPER_SNAKE_CASE; rename it)'}',
    );
    if (declarable) (urlKeys.contains(entry.key) ? urls : plain).add(entry.key);
  }
  if (plain.isNotEmpty || urls.isNotEmpty) {
    final parts = [
      if (plain.isNotEmpty) '"extraKeys": ${jsonEncode(plain)}',
      if (urls.isNotEmpty) '"extraUrlKeys": ${jsonEncode(urls)}',
    ];
    console.out(
      'If they are settings (never secrets: an env file is committed), declare them in ${AppConfig.configPath}:',
    );
    console.out('  "envFile": {${parts.join(', ')}}');
  }
}

/// A note for every file `init` is about to depend on that a `.gitignore`
/// rule hides: a clone or CI checkout would not have it. Asks git, read-only,
/// through the process seam; silent when git is missing or this is not a
/// repository.
Future<void> _printGitIgnoredNotes(BuildEnvironment env, String envDir) async {
  final paths = [
    AppConfig.configPath,
    for (final buildEnv in BuildEnv.values) '$envDir/${buildEnv.name}.json',
  ];
  final CapturedProcess result;
  try {
    result = await env.runner.capture(
      ProcessSpec('git', [
        'check-ignore',
        '-v',
        '--',
        ...paths,
      ], workingDirectory: env.root),
    );
  } on ProcessStartException {
    return;
  }
  // Exit 0: at least one is ignored. 1: none is. Anything else (128: not a
  // repository) is not an answer.
  if (result.exitCode != 0) return;
  for (final line in result.stdout.split('\n')) {
    final tab = line.indexOf('\t');
    if (tab < 0) continue;
    final rule = line.substring(0, tab).trim();
    final path = line.substring(tab + 1).trim();
    if (!paths.contains(path)) continue;
    final consequence = path == AppConfig.configPath
        ? 'a clone or CI checkout will not have it and will infer every fact it holds (the artifact name may differ, and devHostMarkers is empty)'
        : 'a clone or CI checkout will not have this env file, so every build of that environment stops';
    env.console
      ..out('')
      ..out(
        'note: $path is git-ignored ($rule); $consequence. Anchor the rule (for example "/build/" instead of "build/", which also matches tool/build/) or add the file with: git add -f $path',
      );
  }
}

void _printInferred(Console console, ProjectFacts facts, bool configKept) {
  console.out('');
  if (configKept) {
    console.out(
      '${AppConfig.configPath} already exists, so its facts are used (and, for a key it leaves out, what the project states).',
    );
    return;
  }
  console.out('Inferred from the project:');
  final rows = <(String, String, String)>[
    if (facts.slug != null) ('slug', facts.slug!, 'pubspec name'),
    if (facts.displayName != null)
      ('displayName', facts.displayName!, 'pubspec name'),
    if (facts.windowsExe != null)
      ('windows.exe', facts.windowsExe!, 'windows/CMakeLists.txt'),
    if (facts.installerScript != null)
      ('windows.installerScript', facts.installerScript!, 'installer/*.iss'),
    if (facts.macosAppName != null)
      (
        'macos.appName',
        facts.macosAppName!,
        'macos/Runner/Configs/AppInfo.xcconfig',
      ),
  ];
  final keyWidth = rows.fold(
    0,
    (w, row) => row.$1.length > w ? row.$1.length : w,
  );
  final valueWidth = rows.fold(
    0,
    (w, row) => row.$2.length > w ? row.$2.length : w,
  );
  for (final (key, value, source) in rows) {
    console.out(
      '  ${key.padRight(keyWidth)}  ${value.padRight(valueWidth)}  $source',
    );
  }
  if (facts.problems.isNotEmpty) {
    console.out('');
    console.out(
      'Not inferred (only needed to build that platform; set it in ${AppConfig.configPath} when you do):',
    );
    for (final entry in facts.problems.entries) {
      console.out('  ${entry.key}: ${entry.value}');
    }
  }
}

/// `chmod +x` through the process seam; false when it did not work.
Future<bool> _makeExecutable(BuildEnvironment env, String absolute) async {
  try {
    final result = await env.runner.capture(
      ProcessSpec('chmod', ['+x', absolute]),
    );
    return result.exitCode == 0;
  } on ProcessStartException {
    return false;
  }
}
