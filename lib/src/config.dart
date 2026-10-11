/// Per-app facts (`tool/build/build_config.json`) and the pubspec version.
library;

import 'dart:convert';

import 'package:flutter_build_tools/src/env_file.dart';
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
class AppConfig {
  /// Creates a config; [AppConfig.parse] is the normal way to get one.
  const AppConfig({
    required this.app,
    required this.slug,
    required this.displayName,
    required this.envDir,
    required this.windowsExe,
    required this.installerScript,
    required this.macosAppName,
    this.cleanupPrefix,
    this.devHostMarkers = const [],
    this.envSchema = EnvSchema.standard,
    this.docs,
    this.wrappers = const [],
  });

  /// Short app id; written to the manifest as `app`.
  final String app;

  /// Prefix of every artifact name, e.g. `ExampleApp`.
  final String slug;

  /// Human name; also the DMG volume name and the title of `--help`.
  final String displayName;

  /// Folder with the `<env>.json` files, '/'-separated, relative to the repo.
  final String envDir;

  /// File name of the Windows runner, e.g. `example_app.exe`.
  final String windowsExe;

  /// Inno Setup script, '/'-separated, relative to the repo.
  final String installerScript;

  /// macOS bundle name without `.app`, e.g. `Example App`.
  final String macosAppName;

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

  /// The default folder of the env files.
  static const String defaultEnvDir = 'config/env';

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
  factory AppConfig.parse(String jsonText) {
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

    Map<String, Object?> section(String key) {
      final value = root[key];
      if (value is! Map<String, Object?>) {
        throw BuildException('$configPath: "$key" must be an object.');
      }
      return value;
    }

    Map<String, Object?>? optionalSection(String key) {
      if (!root.containsKey(key)) return null;
      return section(key);
    }

    onlyKeys(root, _topLevelKeys, '');
    final slug = text(root, 'slug', 'slug');
    if (!RegExp(r'^[A-Za-z0-9]+$').hasMatch(slug)) {
      throw BuildException(
        '$configPath: "slug" must be letters and digits only (it prefixes every file name), got "$slug".',
      );
    }
    final windows = section('windows');
    onlyKeys(windows, const {
      'exe',
      'installerScript',
      'cleanupPrefix',
    }, 'windows');
    final macos = section('macos');
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
    if (envFile != null) {
      onlyKeys(envFile, const {'extraKeys', 'extraUrlKeys'}, 'envFile');
    }
    final extraKeys = envFile == null
        ? const <String>[]
        : textList(envFile, 'extraKeys', 'envFile.extraKeys');
    final extraUrlKeys = envFile == null
        ? const <String>[]
        : textList(envFile, 'extraUrlKeys', 'envFile.extraUrlKeys');
    final schema = EnvSchema.validated(
      extraKeys: extraKeys,
      extraUrlKeys: extraUrlKeys,
      fail: (message) => throw BuildException('$configPath: $message'),
    );

    final cli = optionalSection('cli');
    if (cli != null) onlyKeys(cli, const {'docs', 'wrappers'}, 'cli');
    final wrappers = <WrapperScript>[];
    final rawWrappers = cli?['wrappers'];
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

    return AppConfig(
      app: text(root, 'app', 'app'),
      slug: slug,
      displayName: text(root, 'displayName', 'displayName'),
      envDir: text(root, 'envDir', 'envDir'),
      windowsExe: text(windows, 'exe', 'windows.exe'),
      installerScript: text(
        windows,
        'installerScript',
        'windows.installerScript',
      ),
      macosAppName: text(macos, 'appName', 'macos.appName'),
      cleanupPrefix: cleanupPrefix,
      devHostMarkers: textList(root, 'devHostMarkers', 'devHostMarkers'),
      envSchema: schema,
      docs: optionalText(cli ?? const {}, 'docs', 'cli.docs'),
      wrappers: List.unmodifiable(wrappers),
    );
  }
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
