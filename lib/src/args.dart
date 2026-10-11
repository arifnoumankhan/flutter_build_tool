/// Command-line parsing and the usage text.
library;

import 'package:flutter_build_tools/src/config.dart';
import 'package:flutter_build_tools/src/model.dart';
import 'package:flutter_build_tools/src/options.dart';

/// What the command line asked for.
sealed class ParsedArgs {
  /// Base constructor of the cases below.
  const ParsedArgs();
}

/// `--help` / `-h`: print the usage text.
class HelpArgs extends ParsedArgs {
  /// Creates the case.
  const HelpArgs();
}

/// `--list`: show platforms, environments and their resolved URLs.
class ListArgs extends ParsedArgs {
  /// Creates the case.
  const ListArgs();
}

/// A build (or a dry run of one).
class BuildArgs extends ParsedArgs {
  /// Creates the case.
  const BuildArgs(this.request);

  /// What to build.
  final BuildRequest request;
}

const Set<String> _flags = {
  '--release',
  '--debug',
  '--profile',
  '--no-build',
  '--release-signing',
  '--allow-dirty',
  '--allow-prod-override',
  '--dry-run',
  '--msix',
  '--list',
  '--help',
  '-h',
};

const Set<String> _valued = {
  '--mode',
  '--base-url',
  '--env-file',
  '--version',
  '--build-number',
};

const String _expected =
    'Expected a platform (apk, web, windows, macos), an environment (dev, preprod, prod, local) and optionally a mode (release, debug, profile), in any order.';

String _example(String invocation) =>
    'Example: $invocation apk release preprod';

/// One example per option that takes a value, for the error messages.
const Map<String, String> _valueExamples = {
  '--mode': '--mode debug',
  '--base-url': '--base-url https://host/public',
  '--env-file': '--env-file config/env/custom.json',
  '--version': '--version 1.0.47',
  '--build-number': '--build-number 48',
};

/// Parses [args] (without the program name). Throws [UsageError] on anything
/// that is not understood. [invocation] only appears in the error messages.
ParsedArgs parseArgs(
  List<String> args, {
  String invocation = BuildToolOptions.defaultInvocation,
}) {
  final positionals = <String>[];
  final flags = <String>{};
  final values = <String, String>{};
  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    if (!arg.startsWith('-')) {
      positionals.add(arg);
      continue;
    }
    final equals = arg.indexOf('=');
    final name = equals == -1 ? arg : arg.substring(0, equals);
    if (_flags.contains(name)) {
      if (equals != -1) {
        throw UsageError(
          '$name does not take a value (write just $name, without "=").',
        );
      }
      flags.add(name);
    } else if (_valued.contains(name)) {
      final String value;
      if (equals != -1) {
        value = arg.substring(equals + 1);
      } else if (i + 1 < args.length && !args[i + 1].startsWith('--')) {
        value = args[++i];
      } else {
        throw UsageError('$name needs a value (e.g. ${_valueExamples[name]}).');
      }
      if (value.isEmpty) {
        throw UsageError(
          '$name needs a non-empty value (e.g. ${_valueExamples[name]}).',
        );
      }
      if (values.containsKey(name)) {
        throw UsageError('$name was given twice; give it once.');
      }
      values[name] = value;
    } else {
      throw UsageError(
        'Unknown option "$arg". Options start with "--" and are listed by --help (for example --dry-run, --debug, --base-url URL). ${_example(invocation)}',
      );
    }
  }

  if (flags.contains('--help') || flags.contains('-h')) return const HelpArgs();
  if (flags.contains('--list')) {
    if (positionals.isNotEmpty || flags.length > 1 || values.isNotEmpty) {
      throw UsageError(
        '--list takes no other arguments. Run it alone: $invocation --list',
      );
    }
    return const ListArgs();
  }

  final words = _readWords(positionals, invocation);
  final platform = words.platform;

  final request = BuildRequest(
    platform: platform,
    env: words.env,
    mode: _mode(flags, values['--mode'], words.modes, invocation),
    baseUrlOverride: values['--base-url'],
    envFilePath: values['--env-file'],
    versionOverride: _version(values['--version']),
    buildNumberOverride: _buildNumber(values['--build-number']),
    noBuild: flags.contains('--no-build'),
    releaseSigning: flags.contains('--release-signing'),
    allowDirty: flags.contains('--allow-dirty'),
    allowProdOverride: flags.contains('--allow-prod-override'),
    dryRun: flags.contains('--dry-run'),
    msix: flags.contains('--msix'),
  );
  if (request.msix && platform != BuildPlatform.windows) {
    throw UsageError(
      '--msix only applies to the windows platform (e.g. windows prod --msix), not ${platform.name}.',
    );
  }
  if (request.releaseSigning && platform != BuildPlatform.apk) {
    throw UsageError(
      '--release-signing only applies to the apk platform (e.g. apk prod --release-signing), not ${platform.name}.',
    );
  }
  return BuildArgs(request);
}

/// Sorts the bare words into platform, env and mode. They are told apart by
/// vocabulary (the three sets are disjoint), so they may come in any order:
/// "apk release preprod", "apk preprod release" and "release apk preprod" are
/// the same request. [modes] collects the mode words; [_mode] merges them with
/// `--mode` and the `--release` / `--debug` / `--profile` switches.
({BuildPlatform platform, BuildEnv env, Set<BuildMode> modes}) _readWords(
  List<String> words,
  String invocation,
) {
  String quoted(List<String> list) => list.map((w) => '"$w"').join(', ');
  final platformWords = <String>[];
  final envWords = <String>[];
  final modes = <BuildMode>{};
  for (final word in words) {
    final mode = BuildMode.parse(word);
    if (BuildPlatform.parse(word) != null) {
      platformWords.add(word);
    } else if (BuildEnv.parse(word) != null) {
      envWords.add(word);
    } else if (mode != null) {
      modes.add(mode);
    } else {
      throw UsageError(
        'Unknown word "$word": it is not a platform, an environment or a mode. $_expected ${_example(invocation)}',
      );
    }
  }
  if (platformWords.length > 1) {
    throw UsageError(
      'Two platforms given (${quoted(platformWords)}): build one at a time. $_expected ${_example(invocation)}',
    );
  }
  if (envWords.length > 1) {
    throw UsageError(
      'Two environments given (${quoted(envWords)}): build one at a time. $_expected ${_example(invocation)}',
    );
  }
  if (platformWords.isEmpty || envWords.isEmpty) {
    final missing = [
      if (platformWords.isEmpty) 'platform',
      if (envWords.isEmpty) 'environment',
    ].join(' and no ');
    throw UsageError(
      'Missing arguments: no $missing given${words.isEmpty ? '' : ' (got ${quoted(words)})'}. $_expected ${_example(invocation)}',
    );
  }
  return (
    platform: BuildPlatform.parse(platformWords.single)!,
    env: BuildEnv.parse(envWords.single)!,
    modes: modes,
  );
}

BuildMode _mode(
  Set<String> flags,
  String? modeValue,
  Set<BuildMode> modeWords,
  String invocation,
) {
  final requested = <BuildMode>{
    ...modeWords,
    for (final mode in BuildMode.values)
      if (flags.contains('--${mode.name}')) mode,
  };
  if (modeValue != null) {
    final mode = BuildMode.parse(modeValue);
    if (mode == null) {
      throw UsageError(
        'Unknown mode "$modeValue". Use release, debug or profile (e.g. --mode debug, or the bare word: apk debug dev).',
      );
    }
    requested.add(mode);
  }
  if (requested.length > 1) {
    throw UsageError(
      'Conflicting modes: ${requested.map((m) => m.name).join(', ')}. Give exactly one: a bare word (release, debug or profile), --mode <mode>, or --release / --debug / --profile. ${_example(invocation)}',
    );
  }
  return requested.isEmpty ? BuildMode.release : requested.single;
}

String? _version(String? value) {
  if (value == null) return null;
  if (!versionPattern.hasMatch(value)) {
    throw UsageError(
      '--version "$value" is not x.y.z (e.g. 1.0.47, without a leading "v").',
    );
  }
  return value;
}

int? _buildNumber(String? value) {
  if (value == null) return null;
  final number = int.tryParse(value);
  if (number == null || number < 1) {
    throw UsageError(
      '--build-number "$value" must be a positive integer (e.g. --build-number 48).',
    );
  }
  return number;
}

/// The `--help` text. [title] is the tool's name in the first line (the app's
/// display name when its config is readable), [invocation] the command a
/// person types, [envDir] the env folder, [docs] where the long documentation
/// lives and [wrappers] the optional wrapper scripts of the project.
String usageText({
  String title = 'Flutter',
  String invocation = BuildToolOptions.defaultInvocation,
  String envDir = AppConfig.defaultEnvDir,
  String? docs,
  List<WrapperScript> wrappers = const [],
}) {
  // The notes of the "Usage:" lines start in one column.
  const noteColumn = 54;
  const arguments = '<platform> <env> [mode] [options]';
  // At least one space separates a command from its note, however long it is.
  String note(String command, String text) {
    final left = '  $command';
    return left.length >= noteColumn
        ? '$left $text'
        : '${left.padRight(noteColumn)}$text';
  }

  final usage = [
    '  $invocation $arguments',
    note(invocation, '(interactive picker, in a terminal)'),
    for (final wrapper in wrappers)
      note('${wrapper.script} $arguments', '(${wrapper.label})'),
  ].join('\n');
  return '''
$title build tool: one command to build an app for any platform and environment.

Usage:
$usage

Platforms: apk | web | windows (alias exe) | macos (alias dmg)
Envs:      dev | preprod | prod | local        ($envDir/<env>.json)
Modes:     release (default) | debug | profile
The three words may come in any order: "apk release preprod" = "apk preprod release" = "release apk preprod".

Examples:
  apk release preprod          release APK for preprod -> dist/android/<Slug>-preprod-v<version>.apk
  web release dev              release web zip for dev
  windows release prod         Inno Setup installer for prod (on Windows only)
  apk preprod                  the same as "apk release preprod" (release is the default)
  apk local debug --base-url http://192.168.1.20:8011

Options:
  --mode release|debug|profile   Build mode (default release); also the bare word, or --release --debug --profile
  --base-url URL                 Override BASE_URL for this build (https unless env local)
  --env-file PATH                Use another env json (absolute or relative to the repo root)
  --version x.y.z                Override the pubspec version (file name AND binary version)
  --build-number N               Override the pubspec +N (default: the +N of pubspec.yaml)
  --no-build                     Skip flutter, re-package the existing output (needs a matching build stamp)
  --release-signing              apk: sign with the release keystore (android/key.properties)
  --msix                         windows: also build an MSIX package (release only, see ${docs ?? 'the flutter_build_tools README'})
  --allow-dirty                  prod: allow a dirty git tree
  --allow-prod-override          prod: allow --base-url / --env-file
  --dry-run                      Print the resolved profile and exact commands, build nothing
  --list                         Show platforms, envs and their resolved URLs
  -h, --help                     This text

Exit codes: 0 ok, 1 build or guard failure, 2 bad command line.
''';
}
