/// Interactive picker for the tool without arguments in a terminal: platform,
/// environment, mode, confirm.
library;

import 'package:flutter_build_tools/src/environment.dart';
import 'package:flutter_build_tools/src/model.dart';
import 'package:flutter_build_tools/src/options.dart';

/// Resolves what a person typed against [options]: the 1-based number, the
/// option name (case-insensitive), an alias, or empty input for
/// [defaultValue]. Null when the input matches nothing.
String? parseChoice(
  String input,
  List<String> options, {
  String? defaultValue,
  Map<String, String> aliases = const {},
}) {
  final text = input.trim().toLowerCase();
  if (text.isEmpty) return defaultValue;
  final number = int.tryParse(text);
  if (number != null) {
    return number >= 1 && number <= options.length ? options[number - 1] : null;
  }
  final aliased = aliases[text] ?? text;
  for (final option in options) {
    if (option.toLowerCase() == aliased) return option;
  }
  return null;
}

/// True for yes/y, false for no/n, [defaultValue] for empty input, null when
/// the answer is not understood.
bool? parseYesNo(String input, {required bool defaultValue}) =>
    switch (input.trim().toLowerCase()) {
      '' => defaultValue,
      'y' || 'yes' => true,
      'n' || 'no' => false,
      _ => null,
    };

/// The command line equivalent to [request], printed before confirming so the
/// person learns the non-interactive form.
String equivalentCommand(
  BuildRequest request, {
  String invocation = BuildToolOptions.defaultInvocation,
}) {
  final mode = request.mode == BuildMode.release
      ? ''
      : ' --${request.mode.name}';
  return '$invocation ${request.platform.name} ${request.env.name}$mode';
}

/// Asks the questions. Returns null when the person declines at the end.
/// Throws [BuildException] at end of input or after repeated invalid answers.
BuildRequest? pickRequest(
  BuildEnvironment env, {
  String invocation = BuildToolOptions.defaultInvocation,
}) {
  final console = env.console;
  final platforms = BuildPlatform.availableOn(
    env.host,
  ).map((platform) => platform.name).toList();
  final platform = BuildPlatform.parse(
    _ask(
      console,
      'Platform',
      platforms,
      defaultValue: platforms.first,
      aliases: const {'exe': 'windows', 'dmg': 'macos'},
    ),
  )!;
  final environment = BuildEnv.parse(
    _ask(
      console,
      'Environment',
      BuildEnv.values.map((e) => e.name).toList(),
      defaultValue: BuildEnv.dev.name,
    ),
  )!;
  final mode = BuildMode.parse(
    _ask(
      console,
      'Mode',
      BuildMode.values.map((m) => m.name).toList(),
      defaultValue: BuildMode.release.name,
    ),
  )!;
  final request = BuildRequest(
    platform: platform,
    env: environment,
    mode: mode,
  );

  console.out('');
  console.out('Build: ${equivalentCommand(request, invocation: invocation)}');
  final proceed = _askYesNo(
    console,
    'Proceed?',
    defaultValue: !environment.isProd,
  );
  return proceed ? request : null;
}

const int _maxAttempts = 3;

String _ask(
  Console console,
  String title,
  List<String> options, {
  required String defaultValue,
  Map<String, String> aliases = const {},
}) {
  console.out('');
  console.out('$title:');
  for (var i = 0; i < options.length; i++) {
    console.out(
      '  ${i + 1}) ${options[i]}${options[i] == defaultValue ? '  (default)' : ''}',
    );
  }
  for (var attempt = 0; attempt < _maxAttempts; attempt++) {
    console.prompt('Choose [${options.indexOf(defaultValue) + 1}]: ');
    final line = console.readLine();
    if (line == null) throw BuildException('Aborted: no input.');
    final choice = parseChoice(
      line,
      options,
      defaultValue: defaultValue,
      aliases: aliases,
    );
    if (choice != null) return choice;
    console.out(
      'Not a valid choice: "${line.trim()}". Type a number or a name from the list.',
    );
  }
  throw BuildException(
    'Aborted: no valid $title choice. Pass the arguments instead, see --help.',
  );
}

bool _askYesNo(Console console, String question, {required bool defaultValue}) {
  for (var attempt = 0; attempt < _maxAttempts; attempt++) {
    console.prompt('$question [${defaultValue ? 'Y/n' : 'y/N'}]: ');
    final line = console.readLine();
    if (line == null) throw BuildException('Aborted: no input.');
    final answer = parseYesNo(line, defaultValue: defaultValue);
    if (answer != null) return answer;
    console.out('Please answer y or n.');
  }
  throw BuildException('Aborted: no valid answer.');
}
