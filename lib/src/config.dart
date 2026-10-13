/// Per-app facts (`tool/build/build_config.json`) and the pubspec version.
library;

import 'dart:convert';

import 'package:flutter_build_tools/src/env_file.dart';
import 'package:flutter_build_tools/src/inference.dart';
import 'package:flutter_build_tools/src/model.dart';

/// A wrapper script of the project (`scripts/build.sh`), listed in `--help`.
class WrapperScript {
  /// Creates a wrapper entry; [label] is the text in parentheses.
  const WrapperScript(this.script, this.label);

  /// Path of the script, relative to the project root.
  final String script;

  /// Short description, for example `macOS/Linux wrapper`.
  final String label;
}

/// The facts of one project (`tool/build/build_config.json`): everything that
/// differs between two apps built with the same tool.
///
/// Every fact a project can state in `build_config.json` can also be read from
/// the project itself ([ProjectFacts]); the file wins key by key. The Windows
/// and macOS facts are only needed when that platform is built: reading one
/// that could not be set or inferred throws a [BuildException] that names it.
class AppConfig {
  /// Creates a config; [AppConfig.parse] is the normal way to get one.
  ///
  /// [windowsExe], [installerScript] and [macosAppName] may be null for a
  /// project that never builds that platform; [unresolved] says why a null
  /// fact is null (keyed by its `build_config.json` name) and is quoted in the
  /// error of the first read.
  const AppConfig({
    required this.app,
    required this.slug,
    required this.displayName,
    required this.envDir,
    String? windowsExe,
    String? installerScript,
    String? macosAppName,
    this.cleanupPrefix,
    this.devHostMarkers = const [],
    this.envSchema = EnvSchema.standard,
    this.docs,
    this.wrappers = const [],
    this.unresolved = const {},
  }) : _windowsExe = windowsExe,
       _installerScript = installerScript,
       _macosAppName = macosAppName;

  /// Short app id; written to the manifest as `app`.
  final String app;

  /// Prefix of every artifact name, e.g. `ExampleApp`.
  final String slug;

  /// Human name; also the DMG volume name and the title of `--help`.
  final String displayName;

  /// Folder with the `<env>.json` files, '/'-separated, relative to the repo.
  final String envDir;

  final String? _windowsExe;
  final String? _installerScript;
  final String? _macosAppName;

  /// File name of the Windows runner, e.g. `example_app.exe`. Throws a
  /// [BuildException] naming `windows.exe` when it is neither set nor
  /// inferable.
  String get windowsExe => _windowsExe ?? _missing('windows.exe');

  /// Inno Setup script, '/'-separated, relative to the repo. Throws a
  /// [BuildException] naming `windows.installerScript` when it is neither set
  /// nor inferable.
  String get installerScript =>
      _installerScript ?? _missing('windows.installerScript');

  /// macOS bundle name without `.app`, e.g. `Example App`. Throws a
  /// [BuildException] naming `macos.appName` when it is neither set nor
  /// inferable.
  String get macosAppName => _macosAppName ?? _missing('macos.appName');

  /// Why a Windows or macOS fact is not set, keyed by its `build_config.json`
  /// name; empty when every fact is known.
  final Map<String, String> unresolved;

  /// Installers in the Inno output folder whose name starts with this are
  /// deleted before a new one is compiled. Null means [slug].
  final String? cleanupPrefix;

  /// The prefix [cleanupPrefix] resolves to.
  String get installerCleanupPrefix => cleanupPrefix ?? slug;

  /// Substrings (compared case-insensitively) that make a prod URL look like
  /// a dev server, in addition to the built-in markers.
  final List<String> devHostMarkers;

  /// Keys an env file may hold beyond the built-in ones.
  final EnvSchema envSchema;

  /// Where the long documentation lives (`tool/build/README.md`), for help
  /// and error messages. Null means the package README.
  final String? docs;

  /// Wrapper scripts listed in `--help`.
  final List<WrapperScript> wrappers;

  /// Checks that every fact [platform] needs is known and throws one
  /// [BuildException] that names the missing ones and how to set them. A
  /// platform other than windows and macos needs no extra fact.
  void requireFactsFor(BuildPlatform platform) {
    final keys = switch (platform) {
      BuildPlatform.windows => [
        if (_windowsExe == null) 'windows.exe',
        if (_installerScript == null) 'windows.installerScript',
      ],
      BuildPlatform.macos => [if (_macosAppName == null) 'macos.appName'],
      _ => const <String>[],
    };
    if (keys.isEmpty) return;
    final lines = [
      for (final key in keys)
        '$key is not set in $configPath and could not be inferred: ${unresolved[key] ?? 'the project does not state it'}.',
    ];
    throw BuildException(
      'Cannot build ${platform.name}. ${lines.join(' ')}\n'
      '${_setItHint(keys)}',
    );
  }

  Never _missing(String key) {
    throw BuildException(
      '$key is not set in $configPath and could not be inferred: ${unresolved[key] ?? 'the project does not state it'}.\n'
      '${_setItHint([key])}',
    );
  }

  /// How to set [keys] explicitly, for the errors above.
  static String _setItHint(List<String> keys) {
    final values = <String, Map<String, String>>{};
    for (final key in keys) {
      final parts = key.split('.');
      values.putIfAbsent(parts.first, () => {})[parts.last] = switch (key) {
        'windows.exe' => '<BINARY_NAME>.exe',
        'windows.installerScript' => 'installer/<name>.iss',
        _ => '<PRODUCT_NAME>',
      };
    }
    final them = keys.length == 1 ? 'it' : 'them';
    return 'Set $them in $configPath, for example ${jsonEncode(values)} ("dart run flutter_build_tools init" writes that file from the project; see the "build_config.json" section of the flutter_build_tools README).';
  }

  /// The default folder of the env files.
  static const String defaultEnvDir = defaultEnvDirectory;

  /// Where the project facts live, relative to the project root.
  static const String configPath = 'tool/build/build_config.json';

  static const Set<String> _topLevelKeys = {
    'app',
    'slug',
    'displayName',
    'envDir',
    'windows',
    'macos',
    'devHostMarkers',
    'envFile',
    'cli',
  };

  /// Parses and validates [jsonText]; throws [BuildException] with a message
  /// that names the key to fix.
  ///
  /// Without [inferred] every key of `app`, `slug`, `displayName` and `envDir`
  /// is required, as in 0.1.0. With [inferred] (what the project itself
  /// states, see [inferProjectFacts]) each key the file leaves out takes the
  /// inferred value, so the file may be as short as `{}`. The `windows` and
  /// `macos` sections are optional either way: a fact that is neither set nor
  /// inferred is only reported when that platform is built.
  factory AppConfig.parse(String jsonText, {ProjectFacts? inferred}) {
    final Object? decoded;
    try {
      decoded = jsonDecode(jsonText);
    } on FormatException catch (e) {
      throw BuildException('$configPath is not valid JSON: ${e.message}');
    }
    if (decoded is! Map<String, Object?>) {
      throw BuildException('$configPath must contain a JSON object.');
    }
    final Map<String, Object?> root = decoded;
    String text(Map<String, Object?> from, String key, String where) {
      final value = from[key];
      if (value is! String || value.trim().isEmpty) {
        throw BuildException(
          '$configPath: "$where" must be a non-empty string.',
        );
      }
      return value;
    }

    String? optionalText(Map<String, Object?> from, String key, String where) {
      if (!from.containsKey(key)) return null;
      return text(from, key, where);
    }

    // The key of the file when it is there, else what the project states.
    String withDefault(String key, String? inferredValue, String how) {
      if (root.containsKey(key)) return text(root, key, key);
      if (inferred == null) return text(root, key, key);
      if (inferredValue == null) {
        throw BuildException(
          '$configPath: "$key" is not set and cannot be inferred: $how. Set "$key" in $configPath (or fix the pubspec).',
        );
      }
      return inferredValue;
    }

    List<String> textList(Map<String, Object?> from, String key, String where) {
      final value = from[key];
      if (value == null) return const [];
      if (value is! List<Object?> ||
          value.any((e) => e is! String || e.trim().isEmpty)) {
        throw BuildException(
          '$configPath: "$where" must be a list of non-empty strings.',
        );
      }
      return List.unmodifiable(value.cast<String>().map((e) => e.trim()));
    }

    void onlyKeys(Map<String, Object?> map, Set<String> known, String where) {
      for (final key in map.keys) {
        if (key.startsWith(r'$') || key.startsWith('_')) continue;
        if (!known.contains(key)) {
          final scope = where.isEmpty ? configPath : '$configPath: "$where"';
          throw BuildException(
            '$scope has unknown key "$key". Known keys: ${(known.toList()..sort()).join(', ')}.',
          );
        }
      }
    }

    Map<String, Object?> optionalSection(String key) {
      if (!root.containsKey(key)) return const {};
      final value = root[key];
      if (value is! Map<String, Object?>) {
        throw BuildException('$configPath: "$key" must be an object.');
      }
      return value;
    }

    onlyKeys(root, _topLevelKeys, '');
    const noName = 'pubspec.yaml has no top-level "name:" to derive it from';
    final slug = withDefault('slug', inferred?.slug, noName);
    if (!RegExp(r'^[A-Za-z0-9]+$').hasMatch(slug)) {
      throw BuildException(
        '$configPath: "slug" must be letters and digits only (it prefixes every file name), got "$slug".',
      );
    }
    final windows = optionalSection('windows');
    onlyKeys(windows, const {
      'exe',
      'installerScript',
      'cleanupPrefix',
    }, 'windows');
    final macos = optionalSection('macos');
    onlyKeys(macos, const {'appName'}, 'macos');

    final cleanupPrefix = optionalText(
      windows,
      'cleanupPrefix',
      'windows.cleanupPrefix',
    );
    if (cleanupPrefix != null &&
        !RegExp(r'^[A-Za-z0-9][A-Za-z0-9 ._-]*$').hasMatch(cleanupPrefix)) {
      throw BuildException(
        '$configPath: "windows.cleanupPrefix" must start with a letter or digit and hold no path separators or wildcards, got "$cleanupPrefix".',
      );
    }

    final envFile = optionalSection('envFile');
    onlyKeys(envFile, const {'extraKeys', 'extraUrlKeys'}, 'envFile');
    final schema = EnvSchema.validated(
      extraKeys: textList(envFile, 'extraKeys', 'envFile.extraKeys'),
      extraUrlKeys: textList(envFile, 'extraUrlKeys', 'envFile.extraUrlKeys'),
      fail: (message) => throw BuildException('$configPath: $message'),
    );

    final cli = optionalSection('cli');
    onlyKeys(cli, const {'docs', 'wrappers'}, 'cli');
    final wrappers = <WrapperScript>[];
    final rawWrappers = cli['wrappers'];
    if (rawWrappers != null) {
      if (rawWrappers is! List<Object?>) {
        throw BuildException(
          '$configPath: "cli.wrappers" must be a list of {"script", "label"} objects.',
        );
      }
      for (final raw in rawWrappers) {
        if (raw is! Map<String, Object?>) {
          throw BuildException(
            '$configPath: "cli.wrappers" must be a list of {"script", "label"} objects.',
          );
        }
        onlyKeys(raw, const {'script', 'label'}, 'cli.wrappers');
        wrappers.add(
          WrapperScript(
            text(raw, 'script', 'cli.wrappers[].script'),
            text(raw, 'label', 'cli.wrappers[].label'),
          ),
        );
      }
    }

    // The platform facts: the file, else the project, else null (an error
    // only when that platform is built).
    final unresolved = <String, String>{};
    String? platformFact(
      Map<String, Object?> section,
      String key,
      String where,
      String? inferredValue,
    ) {
      if (section.containsKey(key)) return text(section, key, where);
      if (inferredValue != null) return inferredValue;
      unresolved[where] =
          inferred?.problems[where] ??
          'the project was not read (nothing to infer it from)';
      return null;
    }

    return AppConfig(
      app: withDefault('app', inferred == null ? null : defaultAppId, ''),
      slug: slug,
      displayName: withDefault('displayName', inferred?.displayName, noName),
      envDir: withDefault(
        'envDir',
        inferred == null ? null : defaultEnvDirectory,
        '',
      ),
      windowsExe: platformFact(
        windows,
        'exe',
        'windows.exe',
        inferred?.windowsExe,
      ),
      installerScript: platformFact(
        windows,
        'installerScript',
        'windows.installerScript',
        inferred?.installerScript,
      ),
      macosAppName: platformFact(
        macos,
        'appName',
        'macos.appName',
        inferred?.macosAppName,
      ),
      cleanupPrefix: cleanupPrefix,
      devHostMarkers: textList(root, 'devHostMarkers', 'devHostMarkers'),
      envSchema: schema,
      docs: optionalText(cli, 'docs', 'cli.docs'),
      wrappers: List.unmodifiable(wrappers),
      unresolved: Map.unmodifiable(unresolved),
    );
  }

  /// A config made only of what the project states ([inferred]), as if
  /// `build_config.json` were `{}`. Throws [BuildException] when the pubspec
  /// has no `name:`.
  factory AppConfig.fromFacts(ProjectFacts inferred) =>
      AppConfig.parse('{}', inferred: inferred);
}

/// `version: x.y.z+N` from pubspec.yaml.
class PubspecVersion {
  /// Creates a version; [PubspecVersion.parse] reads it from the pubspec.
  const PubspecVersion(this.name, this.buildNumber);

  /// `x.y.z`.
  final String name;

  /// The `+N` part, null when the pubspec has none.
  final int? buildNumber;

  /// Reads the top-level `version:` line. Pre-release suffixes are rejected
  /// because Flutter's `--build-name` and the artifact names are `x.y.z`.
  factory PubspecVersion.parse(String pubspecText) {
    final line = RegExp(
      r'^version:[ \t]*(.*?)[ \t]*(?:#.*)?$',
      multiLine: true,
    ).firstMatch(pubspecText);
    if (line == null) {
      throw BuildException(
        'pubspec.yaml has no top-level "version:" line. Add e.g. "version: 1.0.0+1" or pass --version x.y.z.',
      );
    }
    final raw = line.group(1)!.replaceAll('"', '').replaceAll("'", '');
    final match = RegExp(r'^(\d+\.\d+\.\d+)(?:\+(\d+))?$').firstMatch(raw);
    if (match == null) {
      throw BuildException(
        'pubspec.yaml version "$raw" is not x.y.z or x.y.z+N. Fix it (pre-release suffixes are not supported by the build naming).',
      );
    }
    final number = match.group(2);
    return PubspecVersion(
      match.group(1)!,
      number == null ? null : int.parse(number),
    );
  }
}

/// A plain `x.y.z` version, as `--version` accepts it.
final RegExp versionPattern = RegExp(r'^\d+\.\d+\.\d+$');
