import 'dart:io';

import 'package:flutter_build_tools/flutter_build_tools.dart';

/// `dart run flutter_build_tools <platform> <env> ...`: the project root is the
/// nearest folder (from the working directory upwards) with a pubspec.yaml.
Future<void> main(List<String> args) async {
  exitCode = await runBuildToolFromDirectory(
    args,
    directory: Directory.current.absolute.path,
  );
}
