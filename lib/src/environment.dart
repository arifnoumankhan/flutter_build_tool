/// Everything the tool needs from the outside world, bundled so tests can
/// replace it: console, file system, process runner, clock, sleep and host.
library;

import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:flutter_build_tools/src/fs.dart';
import 'package:flutter_build_tools/src/model.dart';
import 'package:flutter_build_tools/src/runner.dart';

/// Where the tool prints and asks. Replace it in tests to capture output and
/// to script the answers of the interactive picker.
abstract class Console {
  /// Prints [line] to standard output.
  void out(String line);

  /// Prints [line] to standard error (warnings and errors).
  void err(String line);

  /// Prints a question without a trailing newline.
  void prompt(String text);

  /// True when a person can answer prompts (stdin and stdout are terminals).
  bool get isInteractive;

  /// One line from the person, or null at end of input.
  String? readLine();
}

/// The real terminal: stdout, stderr and stdin.
class StdConsole implements Console {
  /// Creates the console.
  const StdConsole();

  @override
  void out(String line) => stdout.writeln(line);

  @override
  void err(String line) => stderr.writeln(line);

  @override
  void prompt(String text) => stdout.write(text);

  @override
  bool get isInteractive => stdin.hasTerminal && stdout.hasTerminal;

  @override
  String? readLine() => stdin.readLineSync();
}

/// The project being built and the machine around it. The tool touches the
/// outside world only through this object, so tests run the real code against
/// fakes (see the package tests).
class BuildEnvironment {
  /// Creates an environment. [now] and [sleep] default to the real clock.
  BuildEnvironment({
    required this.root,
    required this.host,
    required this.vars,
    required this.fs,
    required this.runner,
    required this.console,
    DateTime Function()? now,
    Future<void> Function(Duration)? sleep,
  }) : now = now ?? DateTime.now,
       sleep = sleep ?? Future<void>.delayed,
       path = p.Context(
         style: host == HostOs.windows ? p.Style.windows : p.Style.posix,
         current: root,
       );

  /// The real machine. [root] is the repository root.
  factory BuildEnvironment.system(String root) => BuildEnvironment(
    root: root,
    host: HostOs.fromDartName(Platform.operatingSystem),
    vars: Platform.environment,
    fs: const IoFs(),
    runner: const IoProcessRunner(),
    console: const StdConsole(),
  );

  /// Absolute repository root.
  final String root;

  /// The operating system the tool runs on.
  final HostOs host;

  /// Process environment variables (used to find Inno Setup on Windows).
  final Map<String, String> vars;

  /// File system access.
  final BuildFs fs;

  /// Starts git, flutter and the packaging tools.
  final ProcessRunner runner;

  /// Output and prompts.
  final Console console;

  /// The clock, for the build time in the manifest.
  final DateTime Function() now;

  /// Waits between retries (the Inno Setup compiler is retried once).
  final Future<void> Function(Duration) sleep;

  /// Path rules of the host, so a Windows host composes `C:\...` paths even
  /// when the tests run on macOS.
  final p.Context path;

  /// Absolute path of [relative], a '/'-separated path inside the repository.
  String abs(String relative) => path.joinAll([root, ...relative.split('/')]);

  /// [absolute] relative to the repository root with '/' separators when it
  /// is inside it, otherwise unchanged. For display and for flutter args.
  String rel(String absolute) {
    if (!path.isWithin(root, absolute)) return absolute;
    return path.split(path.relative(absolute, from: root)).join('/');
  }
}
