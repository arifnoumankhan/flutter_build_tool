/// The command-line driver: parse, resolve the profile, run the guards, then
/// print the plan (`--dry-run`) or build.
library;

import 'dart:io' show FileSystemException;

import 'package:flutter_build_tools/src/args.dart';
import 'package:flutter_build_tools/src/config.dart';
import 'package:flutter_build_tools/src/disk.dart';
import 'package:flutter_build_tools/src/env_file.dart';
import 'package:flutter_build_tools/src/environment.dart';
import 'package:flutter_build_tools/src/executor.dart';
import 'package:flutter_build_tools/src/fs.dart';
import 'package:flutter_build_tools/src/guards.dart';
import 'package:flutter_build_tools/src/init.dart';
import 'package:flutter_build_tools/src/job.dart';
import 'package:flutter_build_tools/src/keystore.dart';
import 'package:flutter_build_tools/src/model.dart';
import 'package:flutter_build_tools/src/options.dart';
import 'package:flutter_build_tools/src/picker.dart';
import 'package:flutter_build_tools/src/profile.dart';
import 'package:flutter_build_tools/src/web_zip.dart';

/// Runs the tool and returns the process exit code: 0 ok, 1 build or guard
/// failure, 2 bad command line.
Future<int> runBuildTool(
  List<String> args,
  BuildEnvironment env, {
  BuildToolOptions options = const BuildToolOptions(),
}) async {
  final console = env.console;
  try {
    final ParsedArgs parsed;
    if (args.isEmpty) {
      if (!console.isInteractive) {
        throw UsageError(
          'Missing arguments: expected <platform> <env> [mode], e.g. "apk release preprod". (The interactive picker needs a terminal.)',
        );
      }
      final picked = pickRequest(env, invocation: options.invocation);
      if (picked == null) {
        console.out('Cancelled; nothing was built.');
        return 1;
      }
      parsed = BuildArgs(picked);
    } else {
      parsed = parseArgs(args, invocation: options.invocation);
    }
    switch (parsed) {
      case HelpArgs():
        console.out(_usage(env, options));
        return 0;
      case ListArgs():
        return listEnvironments(env);
      case InitArgs(:final force, :final dryRun, :final appEnv):
        return await runInit(
          env,
          InitOptions(force: force, dryRun: dryRun, appEnv: appEnv),
          invocation: options.invocation,
        );
      case BuildArgs(:final request):
        return await _build(env, request);
    }
  } on UsageError catch (e) {
    console.err('error: ${e.message}');
    console.err('Run with --help for usage.');
    return 2;
  } on BuildException catch (e) {
    console.err('error: ${e.message}');
    return 1;
  } on FileSystemException catch (e) {
    // A folder or file the tool cannot read or write is an environment
    // failure like any other (exit 1 with what to do), never a stack trace.
    final where = e.path == null || e.path!.isEmpty ? '' : ' (${e.path})';
    console.err(
      'error: file system problem: ${fileProblem(e)}$where. Check that the path exists and that you may read and write there, then run the command again.',
    );
    return 1;
  }
}

/// The help text. It must work without a readable `build_config.json` (a
/// broken config is exactly when a person asks for help), so the project's
/// facts are used when they load and defaults otherwise.
String _usage(BuildEnvironment env, BuildToolOptions options) {
  AppConfig? app;
  try {
    app = loadAppConfig(env);
  } on Exception {
    // BuildException (missing or invalid config) or a file that cannot be read.
    app = null;
  }
  return usageText(
    title: app?.displayName ?? 'Flutter',
    invocation: options.invocation,
    envDir: app?.envDir ?? AppConfig.defaultEnvDir,
    docs: app?.docs,
    wrappers: app?.wrappers ?? const [],
    // A project that already has its config does not need the first-run hint.
    initHint: !env.fs.fileExists(env.abs(AppConfig.configPath)),
  );
}

Future<int> _build(BuildEnvironment env, BuildRequest request) async {
  final console = env.console;
  final profile = await resolveProfile(env, request);
  final keystore = request.platform == BuildPlatform.apk
      ? inspectKeystore(fs: env.fs, path: env.path, root: env.root)
      : null;
  final job = BuildJob(env, profile, keystore: keystore);
  final findings = evaluateGuards(
    GuardInput(
      request: request,
      envFileLabel: profile.envFile.path,
      fileAppEnv: profile.envFile.appEnv,
      baseUrl: profile.baseUrl,
      posWebUrl: profile.posWebUrl,
      extraUrls: profile.extraUrls,
      devHostMarkers: profile.app.devHostMarkers,
      envDir: profile.app.envDir,
      gitDirty: profile.git.dirty,
      host: env.host,
      keystore: keystore,
      // --no-build runs no flutter, so there is nothing for a full disk to break.
      freeDiskBytes: request.noBuild ? null : await freeDiskBytes(env),
    ),
  );

  for (final line in _profileLines(job)) {
    console.out(line);
  }
  for (final warning in findings.where((f) => !f.isError)) {
    console.err('warning [${warning.code}]: ${warning.message}');
  }

  // A dry run also checks, read-only, what the real run checks before it
  // starts building, so "dry run ok" means a real run would not be refused.
  final preflightProblems = <String>[];
  String? isccPath;
  if (request.dryRun) {
    try {
      if (request.noBuild) verifiedStamp(job);
      if (request.platform == BuildPlatform.windows &&
          env.host == HostOs.windows) {
        isccPath = prepareWindows(job);
      }
    } on BuildException catch (e) {
      preflightProblems.add(e.message);
    }
    console.out('');
    console.out('Plan:');
    var number = 1;
    for (final step in describePlan(job, isccPath: isccPath)) {
      console.out('  ${number++}. $step');
    }
  }

  final errors = findings.where((f) => f.isError).toList();
  final problems = errors.length + preflightProblems.length;
  if (problems > 0) {
    for (final error in errors) {
      console.err('error [${error.code}]: ${error.message}');
    }
    for (final problem in preflightProblems) {
      console.err('error: $problem');
    }
    console.err(
      request.dryRun
          ? 'dry run: a real run would be refused ($problems problem(s)).'
          : 'Refusing to build: $problems problem(s) above.',
    );
    return 1;
  }
  if (request.dryRun) {
    console.out('');
    console.out('dry run: nothing was built.');
    return 0;
  }
  console.out('');
  await executeJob(job);
  return 0;
}

List<String> _profileLines(BuildJob job) {
  final env = job.env;
  final profile = job.profile;
  final request = job.request;
  final baseSource = request.baseUrlOverride != null
      ? '--base-url override'
      : profile.envFile.path;
  final lines = <String>[
    'Build profile',
    '  app          ${profile.app.app} (${profile.app.displayName})',
    // Without the file every fact is inferred, and the guards that only the
    // file can switch on (devHostMarkers) are off: say so, so a file that was
    // never committed (or is git-ignored) does not go unnoticed in CI.
    if (!env.fs.fileExists(env.abs(AppConfig.configPath)))
      '  config       inferred from the project (no ${AppConfig.configPath})',
    '  target       ${request.platform.name} / ${request.env.name} / ${request.mode.name}',
    '  version      ${profile.version}${profile.buildNumber == null ? '' : ' (build ${profile.buildNumber})'}',
    '  APP_ENV      ${profile.defines['APP_ENV']}',
    '  BASE_URL     ${profile.baseUrl}   [$baseSource]',
    for (final key in profile.app.envSchema.optionalUrlKeys)
      if (profile.defines[key] case final value?)
        '  ${_label(key)}$value   [${profile.envFile.path}]',
    '  BUILD_SHA    ${profile.defines['BUILD_SHA']}',
    '  build time   ${profile.buildTime}   [manifest only, not compiled in]',
    '  output       ${job.distFile(request.platform.extension)}',
    if (request.msix) '  output       ${job.distFile('msix')}',
    if (job.signing != null)
      '  signing      ${job.signing!.releaseKeystore ? 'release keystore' : 'debug key'}',
  ];
  if (request.platform == BuildPlatform.web) {
    final indexHtml = env.abs('web/index.html');
    final raw = env.fs.fileExists(indexHtml)
        ? parseBaseHref(env.fs.readString(indexHtml))
        : null;
    final href = servedBaseHref(raw);
    // The template placeholder is not a path: say what Flutter fills in.
    final note = raw == flutterBaseHrefPlaceholder
        ? ': $raw becomes / (no --base-href is passed)'
        : '';
    lines.add('  base href    ${href ?? '<none>'}   [web/index.html$note]');
  }
  return lines;
}

/// `--list`: platforms, environments and their resolved URLs. Returns 1 when
/// an env file is broken, so CI notices.
int listEnvironments(BuildEnvironment env) {
  final console = env.console;
  final app = loadAppConfig(env);
  final version = loadPubspecVersion(env);
  console.out(
    '${app.displayName} (${app.slug}) version ${version.name}${version.buildNumber == null ? '' : '+${version.buildNumber}'}, host ${env.host.name}',
  );
  console.out('');
  console.out('Platforms');
  final available = BuildPlatform.availableOn(env.host);
  const aliases = {
    BuildPlatform.windows: ' (alias exe)',
    BuildPlatform.macos: ' (alias dmg)',
  };
  for (final platform in BuildPlatform.values) {
    final label = '${platform.name}${aliases[platform] ?? ''}'.padRight(20);
    console.out(
      '  $label ${available.contains(platform) ? 'buildable on this host' : 'not buildable on this host (${_hostFor(platform)} only)'}',
    );
  }
  console.out('');
  console.out('Environments (${app.envDir})');
  var broken = false;
  for (final buildEnv in BuildEnv.values) {
    try {
      final file = loadEnvFile(env, app, buildEnv);
      final warning = file.appEnv == buildEnv.name
          ? ''
          : '   (APP_ENV is "${file.appEnv}": builds will be refused)';
      console.out(
        '  ${buildEnv.name.padRight(8)} BASE_URL     ${file.baseUrl}$warning${_placeholderNote(app, buildEnv, file.baseUrl)}',
      );
      for (final key in app.envSchema.optionalUrlKeys) {
        final value = file.values[key];
        if (value != null) {
          console.out(
            '  ${''.padRight(8)} ${_label(key)}$value${_placeholderNote(app, buildEnv, value)}',
          );
        }
      }
    } on BuildException catch (e) {
      broken = true;
      console.out('  ${buildEnv.name.padRight(8)} INVALID: ${e.message}');
    }
  }
  return broken ? 1 : 0;
}

/// `   (placeholder: edit config/env/dev.json)` for a URL `init` wrote and the
/// project has not replaced yet; empty otherwise.
String _placeholderNote(AppConfig app, BuildEnv buildEnv, String url) =>
    isPlaceholderUrl(url)
    ? '   (placeholder: edit ${app.envDir}/${buildEnv.name}.json)'
    : '';

/// A define name padded to the value column of the profile and `--list`.
String _label(String key) => key.length >= 12 ? '$key ' : key.padRight(13);

String _hostFor(BuildPlatform platform) =>
    platform == BuildPlatform.windows ? 'Windows' : 'macOS';
