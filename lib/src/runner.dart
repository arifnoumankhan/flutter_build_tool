/// Process seam: the build tool starts external programs (git, flutter, ISCC,
/// hdiutil, ...) only through [ProcessRunner], so tests never launch anything.
library;

import 'dart:convert';
import 'dart:io';

/// One external command. [shell] is for tools that are batch shims on Windows
/// (flutter.bat); everything else is started directly.
class ProcessSpec {
  /// Creates a command description.
  const ProcessSpec(
    this.executable,
    this.args, {
    this.workingDirectory,
    this.shell = false,
  });

  /// The program to start.
  final String executable;

  /// Its arguments, one per element (no shell quoting needed).
  final List<String> args;

  /// Where to run it; null means the current directory.
  final String? workingDirectory;

  /// Run through the shell on Windows (for `.bat` shims such as flutter.bat).
  final bool shell;

  /// The command as a user would type it.
  String get display => [executable, ...args].map(_quote).join(' ');

  static String _quote(String arg) =>
      RegExp(r'[\s"]').hasMatch(arg) ? '"${arg.replaceAll('"', r'\"')}"' : arg;

  @override
  String toString() => display;
}

/// The result of a command run through [ProcessRunner.capture].
class CapturedProcess {
  /// Creates a result.
  const CapturedProcess(this.exitCode, this.stdout, this.stderr);

  /// The process exit code (0 is success).
  final int exitCode;

  /// Everything it wrote to standard output.
  final String stdout;

  /// Everything it wrote to standard error.
  final String stderr;
}

/// The executable could not be started (not installed, not on PATH).
class ProcessStartException implements Exception {
  /// Creates the exception for [spec].
  ProcessStartException(this.spec, this.reason);

  /// The command that could not be started.
  final ProcessSpec spec;

  /// Why, as reported by the operating system.
  final String reason;

  @override
  String toString() => 'could not start "${spec.executable}": $reason';
}

/// Starts external programs; the only place that does.
abstract class ProcessRunner {
  /// Runs [spec] with its output attached to this console and returns the
  /// exit code. Used for the long builds so progress is visible.
  Future<int> stream(ProcessSpec spec);

  /// Runs [spec] and captures its output.
  Future<CapturedProcess> capture(ProcessSpec spec);
}

/// [ProcessRunner] that really starts the programs.
class IoProcessRunner implements ProcessRunner {
  /// Creates the runner.
  const IoProcessRunner();

  @override
  Future<int> stream(ProcessSpec spec) async {
    // Our own output must reach the console before the child's, even when it
    // is piped (CI logs).
    await stdout.flush();
    await stderr.flush();
    try {
      final process = await Process.start(
        spec.executable,
        spec.args,
        workingDirectory: spec.workingDirectory,
        runInShell: spec.shell && Platform.isWindows,
        mode: ProcessStartMode.inheritStdio,
      );
      return await process.exitCode;
    } on ProcessException catch (e) {
      throw ProcessStartException(spec, e.message);
    }
  }

  @override
  Future<CapturedProcess> capture(ProcessSpec spec) async {
    try {
      final result = await Process.run(
        spec.executable,
        spec.args,
        workingDirectory: spec.workingDirectory,
        runInShell: spec.shell && Platform.isWindows,
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      );
      return CapturedProcess(
        result.exitCode,
        result.stdout as String,
        result.stderr as String,
      );
    } on ProcessException catch (e) {
      throw ProcessStartException(spec, e.message);
    }
  }
}
