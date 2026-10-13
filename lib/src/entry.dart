/// Process-level entry shared by `bin/flutter_build_tools.dart` and by the
/// in-repo shim `tool/build/build.dart` of a project.
library;

import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:flutter_build_tools/src/cli.dart';
import 'package:flutter_build_tools/src/environment.dart';
import 'package:flutter_build_tools/src/fs.dart';
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

/// The nearest folder from [start] upwards that holds a `pubspec.yaml`, or
/// null when there is none (the working directory is not inside a project).
///
/// [fs] is the file system seam, so the walk is testable without touching the
/// disk; [context] defaults to the host's path style.
String? findProjectRoot(
  String start, {
  BuildFs fs = const IoFs(),
  p.Context? context,
}) {
  final path = context ?? p.context;
  var dir = path.normalize(path.absolute(start));
  while (true) {
    if (fs.fileExists(path.join(dir, 'pubspec.yaml'))) return dir;
    final parent = path.dirname(dir);
    if (parent == dir) return null;
    dir = parent;
  }
}

/// What `dart run flutter_build_tools` does: finds the project from
/// [directory] (the nearest folder upwards with a `pubspec.yaml`, so it works
/// from any subfolder) and runs the tool there. Returns the exit code: 2 when
/// there is no project, with the message printed to [console].
///
/// [fs] and [console] default to the real machine; tests pass their own, so
/// "outside a Flutter project" does not depend on what the test machine has
/// above its temporary folder. [environmentFor] builds the environment for
/// the root that was found (default [BuildEnvironment.system]); [pathContext]
/// is the path style of [directory] (default: the host's).
Future<int> runBuildToolFromDirectory(
  List<String> args, {
  required String directory,
  BuildFs fs = const IoFs(),
  Console console = const StdConsole(),
  BuildEnvironment Function(String root)? environmentFor,
  BuildToolOptions? options,
  p.Context? pathContext,
}) async {
  final root = findProjectRoot(directory, fs: fs, context: pathContext);
  if (root == null) {
    console.err(
      'error: no pubspec.yaml in $directory or any parent folder. Run this from inside a Flutter project (a folder with a pubspec.yaml); for a new project see the "Quick start" section of the flutter_build_tools README.',
    );
    return 2;
  }
  return runBuildToolCli(
    args,
    projectRoot: root,
    options: options,
    environment: environmentFor?.call(root),
  );
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
