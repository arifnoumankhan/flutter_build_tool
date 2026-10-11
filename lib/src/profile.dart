/// Resolves a [BuildRequest] into a [BuildProfile]: the app facts, the version,
/// the env file, the overrides and the generated BUILD_* values, merged into
/// the single define map the app is compiled with.
library;

import 'package:flutter_build_tools/src/config.dart';
import 'package:flutter_build_tools/src/env_file.dart';
import 'package:flutter_build_tools/src/environment.dart';
import 'package:flutter_build_tools/src/git.dart';
import 'package:flutter_build_tools/src/model.dart';
import 'package:flutter_build_tools/src/naming.dart';

/// Everything a build needs to know, resolved once: the request, the
/// project's facts, the version, the env file and the git state.
class BuildProfile {
  /// Creates the profile and merges the defines.
  BuildProfile({
    required this.request,
    required this.app,
    required this.version,
    required this.buildNumber,
    required this.envFile,
    required this.git,
    required this.buildTime,
  }) : baseUrl = request.baseUrlOverride ?? envFile.baseUrl,
       defines = mergeDefines(
         fileValues: envFile.values,
         env: request.env,
         baseUrlOverride: request.baseUrlOverride,
         buildSha: git.buildSha,
       );

  /// What was asked for.
  final BuildRequest request;

  /// The project's facts (`tool/build/build_config.json`).
  final AppConfig app;

  /// `x.y.z`, from `--version` or pubspec.yaml; also passed as `--build-name`.
  final String version;

  /// Passed as `--build-number` when not null.
  final int? buildNumber;

  /// The env file the profile was read from.
  final EnvFile envFile;

  /// Commit and tree state.
  final GitInfo git;

  /// UTC, ISO-8601, seconds precision. Recorded in the build stamp and the
  /// manifest only: it must never become a dart-define (see [mergeDefines]).
  final String buildTime;

  /// Effective API base URL (override, else env file).
  final String baseUrl;

  /// The one `--dart-define-from-file` payload, sorted by key.
  final Map<String, String> defines;

  /// `POS_WEB_URL`, null when the env file has none.
  String? get posWebUrl => defines['POS_WEB_URL'];

  /// The project's extra URL keys that the env file has, in config order.
  Map<String, String> get extraUrls => {
    for (final key in app.envSchema.extraUrlKeys) key: ?defines[key],
  };

  /// The project's extra plain keys that the env file has, in config order.
  Map<String, String> get extraDefines => {
    for (final key in app.envSchema.extraKeys) key: ?defines[key],
  };

  /// Artifact name without extension.
  String get baseName => artifactBaseName(
    slug: app.slug,
    env: request.env,
    version: version,
    mode: request.mode,
  );

  /// Artifact file name for [extension].
  String fileName(String extension) => artifactFileName(
    slug: app.slug,
    env: request.env,
    version: version,
    mode: request.mode,
    extension: extension,
  );

  /// Where the temporary define file lives, relative to the repo.
  String get defineFilePath =>
      'build/build_tool/defines-${request.platform.name}-${request.env.name}.json';
}

/// Precedence, lowest to highest: env file, `--base-url`, generated values
/// (APP_ENV is always the requested environment; a mismatching file is
/// refused by a guard before anything is built).
///
/// Every value here is hashed by Flutter into a cache folder under
/// `.dart_tool/flutter_build/` that is never pruned (100-230 MB each), so the
/// defines must be identical between two builds of the same commit and
/// environment. Nothing that changes on every run (a timestamp) may be added.
Map<String, String> mergeDefines({
  required Map<String, String> fileValues,
  required BuildEnv env,
  required String? baseUrlOverride,
  required String buildSha,
}) {
  final merged = <String, String>{
    ...fileValues,
    'BASE_URL': ?baseUrlOverride,
    'APP_ENV': env.name,
    'BUILD_SHA': buildSha,
  };
  return Map.fromEntries(
    merged.entries.toList()..sort((a, b) => a.key.compareTo(b.key)),
  );
}

/// Reads and validates `tool/build/build_config.json` of the project.
AppConfig loadAppConfig(BuildEnvironment env) {
  final path = env.abs(AppConfig.configPath);
  if (!env.fs.fileExists(path)) {
    throw BuildException(
      '${AppConfig.configPath} not found. It holds the per-app facts (slug, display name, installer).',
    );
  }
  return AppConfig.parse(env.fs.readString(path));
}

/// Reads the `version:` of the project's pubspec.yaml.
PubspecVersion loadPubspecVersion(BuildEnvironment env) {
  final path = env.abs('pubspec.yaml');
  if (!env.fs.fileExists(path)) {
    throw BuildException('pubspec.yaml not found at $path.');
  }
  return PubspecVersion.parse(env.fs.readString(path));
}

/// Loads `<envDir>/<env>.json`, or [customPath] (absolute, or relative to the
/// repo root) when given.
EnvFile loadEnvFile(
  BuildEnvironment env,
  AppConfig app,
  BuildEnv buildEnv, {
  String? customPath,
}) {
  final String absolute;
  if (customPath != null) {
    absolute = env.path.isAbsolute(customPath)
        ? customPath
        : env.path.join(env.root, customPath);
  } else {
    absolute = env.abs('${app.envDir}/${buildEnv.name}.json');
  }
  final shown = env.rel(absolute);
  if (!env.fs.fileExists(absolute)) {
    throw BuildException(
      customPath != null
          ? 'Env file $shown not found. Check the --env-file path.'
          : 'Env file $shown not found. Create it ({"APP_ENV": "${buildEnv.name}", "BASE_URL": "https://..."}), see ${app.docs ?? 'the flutter_build_tools README'}.',
    );
  }
  return EnvFile.parse(
    shown,
    env.fs.readString(absolute),
    schema: app.envSchema,
  );
}

/// `2026-10-06T12:34:56Z`: UTC, ISO-8601, no fractional seconds.
String formatBuildTime(DateTime moment) =>
    moment.toUtc().toIso8601String().replaceFirst(RegExp(r'\.\d+Z$'), 'Z');

/// Resolves [request] against the project: config, pubspec, env file, git.
/// Throws [BuildException] with a message that says what to fix.
Future<BuildProfile> resolveProfile(
  BuildEnvironment env,
  BuildRequest request,
) async {
  final app = loadAppConfig(env);
  final pubspec = loadPubspecVersion(env);
  final override = request.baseUrlOverride;
  if (override != null) {
    final problem = urlProblem(override);
    if (problem != null) {
      throw BuildException('--base-url "$override" $problem');
    }
  }
  final envFile = loadEnvFile(
    env,
    app,
    request.env,
    customPath: request.envFilePath,
  );
  final git = await readGitInfo(env.runner, env.root);
  return BuildProfile(
    request: request,
    app: app,
    version: request.versionOverride ?? pubspec.name,
    buildNumber: request.buildNumberOverride ?? pubspec.buildNumber,
    envFile: envFile,
    git: git,
    buildTime: formatBuildTime(env.now()),
  );
}
