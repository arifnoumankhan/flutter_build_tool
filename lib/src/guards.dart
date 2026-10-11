/// The checks that stop a binary from silently pointing at the wrong server or
/// shipping from an unverified tree. Pure: all facts come in as [GuardInput].
library;

import 'package:flutter_build_tools/src/config.dart';
import 'package:flutter_build_tools/src/keystore.dart';
import 'package:flutter_build_tools/src/model.dart';

/// How a [Finding] affects the build.
enum Severity {
  /// Stops the build (exit code 1).
  error,

  /// Is printed and does not stop the build.
  warning,
}

/// One result of [evaluateGuards].
class Finding {
  /// Creates a finding.
  const Finding(this.code, this.severity, this.message);

  /// Stable identifier, used by tests and the docs.
  final String code;

  /// Whether the finding stops the build.
  final Severity severity;

  /// What is wrong and what to do about it.
  final String message;

  /// True when [severity] is [Severity.error].
  bool get isError => severity == Severity.error;
}

/// Below this many free bytes on the build volume the `low-disk` warning fires.
const int lowDiskThresholdBytes = 3 * 1024 * 1024 * 1024;

/// Everything [evaluateGuards] needs to know, gathered by the caller.
class GuardInput {
  /// Creates the input; only the facts every build has are required.
  const GuardInput({
    required this.request,
    required this.envFileLabel,
    required this.fileAppEnv,
    required this.baseUrl,
    required this.posWebUrl,
    required this.gitDirty,
    required this.host,
    required this.keystore,
    this.freeDiskBytes,
    this.extraUrls = const {},
    this.devHostMarkers = const [],
    this.envDir = AppConfig.defaultEnvDir,
  });

  /// What was asked for.
  final BuildRequest request;

  /// Env file name used in messages.
  final String envFileLabel;

  /// APP_ENV as written in the env file.
  final String fileAppEnv;

  /// Effective BASE_URL (after `--base-url`).
  final String baseUrl;

  /// Effective POS_WEB_URL; null when the env file has none.
  final String? posWebUrl;

  /// Null when git could not tell.
  final bool? gitDirty;

  /// The machine the tool runs on.
  final HostOs host;

  /// Needed for apk builds; null otherwise.
  final KeystoreStatus? keystore;

  /// Free bytes on the build volume; null when unknown or not checked.
  final int? freeDiskBytes;

  /// The project's extra URL keys (`envFile.extraUrlKeys`) and their values.
  final Map<String, String> extraUrls;

  /// The project's dev host markers (`devHostMarkers`).
  final List<String> devHostMarkers;

  /// The project's env folder, only used to say which file to edit.
  final String envDir;
}

/// Which dev/local marker [url] contains, or null when it looks like a real
/// server. Prod refuses URLs that match. [extraMarkers] are the project's own
/// dev host names (`devHostMarkers` in build_config.json), checked first.
String? devLookingMarker(String url, {List<String> extraMarkers = const []}) {
  final lower = url.toLowerCase();
  final host = Uri.tryParse(lower)?.host ?? lower;
  for (final marker in extraMarkers) {
    if (lower.contains(marker.toLowerCase())) return marker;
  }
  if (lower.contains('localhost')) return 'localhost';
  if (host == '127.0.0.1') return '127.0.0.1';
  if (host == '::1') return '::1';
  if (host == '10.0.2.2') return '10.0.2.2';
  if (host.startsWith('192.168.')) return '192.168.';
  if (host.startsWith('10.')) return '10.x';
  return null;
}

/// Runs every guard against [input] and returns what it found: errors stop
/// the build, warnings are printed. An empty list means all clear.
List<Finding> evaluateGuards(GuardInput input) {
  final request = input.request;
  final env = request.env;
  final findings = <Finding>[];
  void error(String code, String message) =>
      findings.add(Finding(code, Severity.error, message));
  void warning(String code, String message) =>
      findings.add(Finding(code, Severity.warning, message));

  if (input.fileAppEnv != env.name) {
    error(
      'app-env-mismatch',
      '${input.envFileLabel} has APP_ENV "${input.fileAppEnv}" but the requested env is "${env.name}". '
          'Set "APP_ENV": "${env.name}" in that file (or pass the matching env).',
    );
  }

  final urls = {
    'BASE_URL': input.baseUrl,
    if (input.posWebUrl != null) 'POS_WEB_URL': input.posWebUrl!,
    ...input.extraUrls,
  };
  for (final entry in urls.entries) {
    if (!env.isLocal && Uri.tryParse(entry.value)?.scheme != 'https') {
      error(
        'not-https',
        '${entry.key} "${entry.value}" must be https for env "${env.name}" (only the "local" env may use http). '
            'Fix it in ${input.envFileLabel}${entry.key == 'BASE_URL' && request.baseUrlOverride != null ? ' or --base-url' : ''}, '
            'or build env "local".',
      );
    }
    if (env.isProd) {
      final marker = devLookingMarker(
        entry.value,
        extraMarkers: input.devHostMarkers,
      );
      if (marker != null) {
        error(
          'prod-dev-url',
          'prod ${entry.key} "${entry.value}" looks like a dev/local server (matches "$marker"). '
              'A prod binary must never point there. Fix ${input.envFileLabel}.',
        );
      }
    }
  }

  if (env.isProd && request.overridesProfile && !request.allowProdOverride) {
    error(
      'prod-override',
      'prod refuses ${request.baseUrlOverride != null ? '--base-url' : '--env-file'} unless --allow-prod-override is also given. '
          'Prefer editing ${input.envDir}/prod.json and committing it.',
    );
  }

  if (env.isProd && request.mode != BuildMode.release) {
    error(
      'prod-mode',
      'prod builds must be release builds, got ${request.mode.flutterFlag}. '
          'Run the same command without ${request.mode.flutterFlag} (release is the default).',
    );
  }

  _dirtyGuard(input, error, warning);

  final freeDisk = input.freeDiskBytes;
  if (freeDisk != null && freeDisk < lowDiskThresholdBytes) {
    String gigabytes(int bytes) =>
        (bytes / (1024 * 1024 * 1024)).toStringAsFixed(1);
    warning(
      'low-disk',
      'LOW DISK SPACE: only ${gigabytes(freeDisk)} GB free on the volume holding the repository (a build wants at least ${gigabytes(lowDiskThresholdBytes)} GB; a full disk makes it fail halfway). '
          'Free space first: Flutter keeps one 100-230 MB folder per distinct set of defines in .dart_tool/flutter_build/ and never prunes them, so deleting that folder (it is a cache) or running "flutter clean" is the quickest win.',
    );
  }

  if (request.platform == BuildPlatform.windows &&
      input.host != HostOs.windows) {
    error(
      'host-windows',
      'The windows target can only be built on Windows (this host: ${input.host.name}); Flutter cannot cross-build desktop apps. '
          'Run this command on a Windows machine.',
    );
  }
  if (request.platform == BuildPlatform.macos && input.host != HostOs.macos) {
    error(
      'host-macos',
      'The macos target can only be built on macOS (this host: ${input.host.name}); Flutter cannot cross-build desktop apps. '
          'Run this command on a Mac.',
    );
  }

  if (request.msix && request.mode != BuildMode.release) {
    error(
      'msix-mode',
      '--msix packages release builds only; drop ${request.mode.flutterFlag} or --msix.',
    );
  }

  if (request.releaseSigning && request.mode != BuildMode.release) {
    warning(
      'release-signing-ignored',
      '--release-signing has no effect on ${request.mode.name} builds (they are always signed with the debug key).',
    );
  }

  final keystore = input.keystore;
  if (request.platform == BuildPlatform.apk &&
      request.mode == BuildMode.release &&
      keystore != null) {
    final signing = planApkSigning(request, keystore);
    if (!signing.releaseKeystore) {
      if (env.isProd) {
        error(
          'keystore',
          'A prod APK requires a valid release keystore, but ${keystore.problem}. '
              'Configure android/key.properties (storePassword, keyPassword, keyAlias, storeFile pointing to an existing file; see android/app/build.gradle).',
        );
      } else if (keystore.valid) {
        warning(
          'keystore',
          'This APK will be signed with the DEBUG key. Pass --release-signing to use the release keystore.',
        );
      } else {
        warning(
          'keystore',
          'This APK will be signed with the DEBUG key: ${keystore.problem}.',
        );
      }
    }
  }

  return findings;
}

void _dirtyGuard(
  GuardInput input,
  void Function(String, String) error,
  void Function(String, String) warning,
) {
  final dirty = input.gitDirty;
  if (dirty == false) return;
  final what = dirty == true
      ? 'The git working tree has uncommitted changes'
      : 'Git could not tell whether the working tree is clean';
  if (input.request.env.isProd) {
    if (input.request.allowDirty) {
      warning(
        'dirty-tree',
        '$what; continuing because --allow-dirty was given.',
      );
    } else {
      error(
        'dirty-tree',
        '$what, and prod requires a clean tree so the build is reproducible. Commit or stash first, or pass --allow-dirty to accept the risk.',
      );
    }
  } else {
    warning(
      'dirty-tree',
      '$what; BUILD_SHA is ${dirty == true ? 'marked -dirty' : 'unknown'}.',
    );
  }
}
