/// Process-level entry shared by `bin/flutter_build_tools.dart` and by the
/// in-repo shim `tool/build/build.dart` of a project.
library;

import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:flutter_build_tools/src/cli.dart';
import 'package:flutter_build_tools/src/environment.dart';
import 'package:flutter_build_tools/src/options.dart';

/// Runs the tool for the Flutter project at [projectRoot] and returns the exit
/// code (0 ok, 1 build or guard failure, 2 bad command line).
///
/// The command shown in help and examples is the running script relative to
/// the project (`dart run tool/build/build.dart` for a shim inside the
/// project) and `dart run flutter_build_tools` otherwise; pass [options] to
/// say it yourself. [environment] replaces the real machine
/// ([BuildEnvironment.system]); embedders and tests use it to inject a file
/// system, process runner and console.
Future<int> runBuildToolCli(
  List<String> args, {
  required String projectRoot,
  BuildToolOptions? options,
  BuildEnvironment? environment,
}) async {
  final env = environment ?? BuildEnvironment.system(projectRoot);
  final resolved =
      options ??
      BuildToolOptions(
        invocation: invocationFor(root: projectRoot, script: _runningScript()),
      );
  if (!env.fs.fileExists(env.abs('pubspec.yaml'))) {
    env.console.err(
      'error: expected pubspec.yaml at $projectRoot; run this tool from the Flutter project (${resolved.invocation} ...).',
    );
    return 2;
  }
  return runBuildTool(args, env, options: resolved);
}

/// The command a person types to run the script at [script] for the project
/// at [root]: `dart run tool/build/build.dart` when the script is a `.dart`
/// file inside [root], the package's own `dart run flutter_build_tools`
/// otherwise (no script, a script outside the project, or the snapshot that
/// `dart run flutter_build_tools` keeps under `.dart_tool/`, which is not a
/// command anyone types).
String invocationFor({required String root, required String? script}) {
  if (script != null &&
      script.endsWith('.dart') &&
      p.isWithin(root, script) &&
      !p.isWithin(p.join(root, '.dart_tool'), script)) {
    final relative = p.split(p.relative(script, from: root)).join('/');
    return 'dart run $relative';
  }
  return BuildToolOptions.defaultInvocation;
}

/// Path of the running script, or null when it is not a file (for example a
/// `data:` URI or an unusual embedder).
String? _runningScript() {
  try {
    return Platform.script.toFilePath();
  } on UnsupportedError {
    return null;
  }
}
