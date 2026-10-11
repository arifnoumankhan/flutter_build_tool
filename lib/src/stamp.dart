/// A small marker written after every real Flutter build recording what the
/// output was compiled for. `--no-build` re-packages existing output; without
/// the marker it could label a binary built for another environment with the
/// wrong name, so it is refused unless the marker matches the requested
/// profile.
library;

import 'dart:convert';

import 'package:flutter_build_tools/src/git.dart';
import 'package:flutter_build_tools/src/profile.dart';

/// Proof of what an existing build output was compiled for, written after
/// every real build and compared by `--no-build`.
class BuildStamp {
  /// Creates a stamp.
  const BuildStamp({
    required this.platform,
    required this.mode,
    required this.version,
    required this.buildNumber,
    required this.defines,
    required this.builtAt,
    required this.gitSha,
    required this.gitDirty,
  });

  /// The stamp of a build made with [profile].
  factory BuildStamp.of(BuildProfile profile) => BuildStamp(
    platform: profile.request.platform.name,
    mode: profile.request.mode.name,
    version: profile.version,
    buildNumber: profile.buildNumber,
    defines: profile.defines,
    builtAt: profile.buildTime,
    gitSha: profile.git.sha,
    gitDirty: profile.git.dirty,
  );

  /// Platform name (`apk`, `web`, ...).
  final String platform;

  /// Mode name (`release`, ...).
  final String mode;

  /// `x.y.z` the build was named with.
  final String version;

  /// The build number, null when none was passed.
  final int? buildNumber;

  /// The defines the binary was compiled with (APP_ENV, BASE_URL, ...).
  final Map<String, String> defines;

  /// UTC ISO-8601 time the build ran; kept here and in the manifest, not in
  /// the defines (see mergeDefines).
  final String builtAt;

  /// Short commit hash at build time.
  final String gitSha;

  /// Whether the tree was dirty; null when git could not tell.
  final bool? gitDirty;

  /// [gitSha] and [gitDirty] as a [GitInfo].
  GitInfo get git => GitInfo(sha: gitSha, dirty: gitDirty);

  /// The JSON written to `build/build_tool/stamp-*.json`.
  Map<String, Object?> toJson() => {
    'platform': platform,
    'mode': mode,
    'version': version,
    'buildNumber': buildNumber,
    'defines': defines,
    'builtAt': builtAt,
    'gitSha': gitSha,
    'gitDirty': gitDirty,
  };

  /// Parses stamp JSON; null when it is not a stamp this tool wrote.
  static BuildStamp? tryParse(String text) {
    try {
      final json = jsonDecode(text);
      if (json is! Map<String, Object?>) return null;
      final defines = json['defines'];
      if (defines is! Map<String, Object?>) return null;
      return BuildStamp(
        platform: json['platform'] as String,
        mode: json['mode'] as String,
        version: json['version'] as String,
        buildNumber: json['buildNumber'] as int?,
        defines: defines.map((key, value) => MapEntry(key, value as String)),
        // Stamps written before BUILD_TIME left the defines carry it there.
        builtAt:
            json['builtAt'] as String? ??
            (defines['BUILD_TIME'] as String?) ??
            'unknown',
        gitSha: json['gitSha'] as String,
        gitDirty: json['gitDirty'] as bool?,
      );
    } on FormatException {
      return null;
    } on TypeError {
      return null;
    }
  }

  /// What differs between what the output was built for and [profile]; empty
  /// when it is safe to re-package. BUILD_SHA is expected to differ and is not
  /// compared.
  List<String> differencesFrom(BuildProfile profile) {
    final differences = <String>[];
    void compare(String label, Object? built, Object? wanted) {
      if (built != wanted) {
        differences.add('$label: built $built, requested $wanted');
      }
    }

    compare('platform', platform, profile.request.platform.name);
    compare('mode', mode, profile.request.mode.name);
    compare('version', version, profile.version);
    compare('build number', buildNumber, profile.buildNumber);
    for (final key in profile.app.envSchema.allowedKeys) {
      compare(key, defines[key], profile.defines[key]);
    }
    return differences;
  }
}
