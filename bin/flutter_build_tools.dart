import 'dart:io';

import 'package:flutter_build_tools/flutter_build_tools.dart';

/// `dart run flutter_build_tools <platform> <env> ...`: the project root is the
/// nearest folder (from the working directory upwards) with a pubspec.yaml.
Future<void> main(List<String> args) async {
  var dir = Directory.current.absolute;
  while (!File(
    '${dir.path}${Platform.pathSeparator}pubspec.yaml',
  ).existsSync()) {
    final parent = dir.parent;
    if (parent.path == dir.path) {
      stderr.writeln(
        'error: no pubspec.yaml in ${Directory.current.path} or any parent folder.',
      );
      exitCode = 2;
      return;
    }
    dir = parent;
  }
  exitCode = await runBuildToolCli(args, projectRoot: dir.path);
}
