import 'package:test/test.dart';

import 'package:flutter_build_tools/src/args.dart';
import 'package:flutter_build_tools/src/config.dart';
import 'package:flutter_build_tools/src/model.dart';

BuildRequest build(List<String> args) => (parseArgs(args) as BuildArgs).request;

/// The message of the [UsageError] that [args] cause.
String _errorOf(List<String> args) {
  try {
    parseArgs(args);
  } on UsageError catch (e) {
    return e.message;
  }
  fail('expected a UsageError for $args');
}

Matcher usageError([String? text]) => throwsA(
  isA<UsageError>().having(
    (e) => e.message,
    'message',
    text == null ? isNotEmpty : contains(text),
  ),
);

void main() {
  group('the sentences the user says', () {
    test('apk preprod: release by default', () {
      final request = build(['apk', 'preprod']);
      expect(request.platform, BuildPlatform.apk);
      expect(request.env, BuildEnv.preprod);
      expect(request.mode, BuildMode.release);
      expect(
        request.noBuild ||
            request.dryRun ||
            request.msix ||
            request.releaseSigning,
        isFalse,
      );
    });

    test('web dev --release', () {
      final request = build(['web', 'dev', '--release']);
      expect(request.platform, BuildPlatform.web);
      expect(request.env, BuildEnv.dev);
      expect(request.mode, BuildMode.release);
    });

    test('windows prod, also as exe', () {
      expect(build(['windows', 'prod']).platform, BuildPlatform.windows);
      expect(build(['exe', 'prod']).platform, BuildPlatform.windows);
      expect(build(['dmg', 'dev']).platform, BuildPlatform.macos);
    });

    test('arguments are case-insensitive and options may come first', () {
      final request = build(['--debug', 'APK', 'Local']);
      expect(request.platform, BuildPlatform.apk);
      expect(request.env, BuildEnv.local);
      expect(request.mode, BuildMode.debug);
    });
  });

  group('modes', () {
    test('shortcuts and --mode', () {
      expect(build(['apk', 'dev', '--debug']).mode, BuildMode.debug);
      expect(build(['apk', 'dev', '--profile']).mode, BuildMode.profile);
      expect(
        build(['apk', 'dev', '--mode', 'profile']).mode,
        BuildMode.profile,
      );
      expect(build(['apk', 'dev', '--mode=debug']).mode, BuildMode.debug);
    });

    test('the same mode twice is fine, different modes conflict', () {
      expect(
        build(['apk', 'dev', '--debug', '--mode', 'debug']).mode,
        BuildMode.debug,
      );
      expect(
        () => parseArgs(['apk', 'dev', '--debug', '--release']),
        usageError('Conflicting modes'),
      );
      expect(
        () => parseArgs(['apk', 'dev', '--mode', 'debug', '--profile']),
        usageError('Conflicting modes'),
      );
    });

    test('unknown mode', () {
      expect(
        () => parseArgs(['apk', 'dev', '--mode', 'fast']),
        usageError('Unknown mode "fast"'),
      );
    });
  });

  group('the mode as a bare word, anywhere among the positionals', () {
    test('the three sentences the user says', () {
      final apk = build(['apk', 'release', 'preprod']);
      expect(
        (apk.platform, apk.mode, apk.env),
        (BuildPlatform.apk, BuildMode.release, BuildEnv.preprod),
      );
      final web = build(['web', 'release', 'dev']);
      expect(
        (web.platform, web.mode, web.env),
        (BuildPlatform.web, BuildMode.release, BuildEnv.dev),
      );
      final windows = build(['windows', 'release', 'prod']);
      expect(
        (windows.platform, windows.mode, windows.env),
        (BuildPlatform.windows, BuildMode.release, BuildEnv.prod),
      );
    });

    test('platform, env and mode in every order give the same request', () {
      const orders = [
        [0, 1, 2],
        [0, 2, 1],
        [1, 0, 2],
        [1, 2, 0],
        [2, 0, 1],
        [2, 1, 0],
      ];
      for (final mode in BuildMode.values) {
        final words = ['apk', 'preprod', mode.name];
        for (final order in orders) {
          final args = [for (final i in order) words[i]];
          final request = build(args);
          expect(
            (request.platform, request.env, request.mode),
            (BuildPlatform.apk, BuildEnv.preprod, mode),
            reason: args.join(' '),
          );
        }
      }
    });

    test('aliases, case and options mixed in', () {
      expect(build(['EXE', 'Release', 'PROD']).platform, BuildPlatform.windows);
      expect(build(['debug', 'dmg', 'dev']).mode, BuildMode.debug);
      final request = build([
        '--dry-run',
        'apk',
        '--version',
        '1.0.5',
        'profile',
        'dev',
        '--no-build',
      ]);
      expect(request.mode, BuildMode.profile);
      expect(request.versionOverride, '1.0.5');
      expect(request.dryRun && request.noBuild, isTrue);
    });

    test('the value of an option is never read as a mode word', () {
      final request = build(['apk', 'dev', '--env-file', 'debug']);
      expect(request.envFilePath, 'debug');
      expect(request.mode, BuildMode.release);
    });

    test('release stays the default without a word', () {
      expect(build(['apk', 'preprod']).mode, BuildMode.release);
    });

    test('the same mode said twice (word and switch) is fine', () {
      expect(
        build(['apk', 'release', 'dev', '--release']).mode,
        BuildMode.release,
      );
      expect(
        build(['apk', 'debug', 'dev', '--mode', 'debug', '--debug']).mode,
        BuildMode.debug,
      );
      expect(build(['apk', 'debug', 'debug', 'dev']).mode, BuildMode.debug);
    });

    test('different modes conflict, whichever way they are given', () {
      for (final args in [
        ['apk', 'release', 'dev', '--debug'],
        ['apk', 'release', 'debug', 'dev'],
        ['apk', 'dev', 'release', '--mode', 'profile'],
        ['profile', 'apk', 'dev', '--release'],
        ['apk', 'dev', 'debug', '--mode=release'],
      ]) {
        expect(
          () => parseArgs(args),
          usageError('Conflicting modes'),
          reason: '$args',
        );
      }
      expect(
        () => parseArgs(['apk', 'release', 'dev', '--debug']),
        usageError('release, debug'),
        reason: 'names the modes that clash',
      );
    });

    test('a platform or an env given twice is refused, even the same one', () {
      expect(
        () => parseArgs(['apk', 'web', 'dev']),
        usageError('Two platforms given ("apk", "web")'),
      );
      expect(
        () => parseArgs(['apk', 'apk', 'dev']),
        usageError('Two platforms given ("apk", "apk")'),
      );
      expect(
        () => parseArgs(['apk', 'dev', 'prod', 'release']),
        usageError('Two environments given ("dev", "prod")'),
      );
      expect(
        () => parseArgs(['exe', 'windows', 'dev']),
        usageError('Two platforms given'),
        reason: 'an alias is the same platform, still two words',
      );
    });

    test('an unknown word is refused wherever it stands', () {
      for (final args in [
        ['fast', 'apk', 'dev'],
        ['apk', 'fast', 'dev'],
        ['apk', 'dev', 'fast'],
        ['apk', 'release', 'dev', 'fast'],
        ['apk', 'releases', 'dev'],
        ['apk', 'dev', 'prduction'],
      ]) {
        expect(
          () => parseArgs(args),
          usageError('Unknown word'),
          reason: '$args',
        );
      }
    });

    test('a missing platform or env says which one', () {
      expect(
        () => parseArgs(['apk', 'release']),
        usageError('no environment given (got "apk", "release")'),
      );
      expect(
        () => parseArgs(['release', 'dev']),
        usageError('no platform given (got "release", "dev")'),
      );
      expect(
        () => parseArgs(['release']),
        usageError('no platform and no environment given (got "release")'),
      );
      expect(
        () => parseArgs([]),
        usageError('no platform and no environment given.'),
      );
    });

    test(
      'every wrong command line says what was expected and shows an example',
      () {
        for (final args in [
          <String>[],
          ['apk'],
          ['apk', 'release'],
          ['apk', 'dev', 'extra'],
          ['apk', 'web', 'dev'],
          ['apk', 'dev', 'prod'],
          ['apk', 'dev', 'release', '--debug'],
          ['apk', 'dev', '--fast'],
        ]) {
          final error = _errorOf(args);
          expect(
            error,
            contains(
              'Example: dart run flutter_build_tools apk release preprod',
            ),
            reason: '$args',
          );
          if (!error.startsWith('Conflicting') &&
              !error.startsWith('Unknown option')) {
            expect(
              error,
              contains('Expected a platform (apk, web, windows, macos)'),
              reason: '$args',
            );
          }
        }
      },
    );

    test('options that need a value show one', () {
      for (final (option, example) in [
        ('--mode', '--mode debug'),
        ('--base-url', '--base-url https://host/public'),
        ('--env-file', '--env-file config/env/custom.json'),
        ('--version', '--version 1.0.47'),
        ('--build-number', '--build-number 48'),
      ]) {
        expect(_errorOf(['apk', 'dev', option]), contains('e.g. $example'));
        expect(_errorOf(['apk', 'dev', '$option=']), contains('e.g. $example'));
      }
      expect(
        _errorOf(['apk', 'dev', '--build-number', '0']),
        contains('e.g. --build-number 48'),
      );
      expect(
        _errorOf(['apk', 'dev', '--debug=yes']),
        contains('write just --debug'),
      );
    });

    test('platform-specific switches name the offending platform', () {
      expect(_errorOf(['apk', 'dev', '--msix']), contains('not apk'));
      expect(
        _errorOf(['web', 'dev', '--release-signing']),
        contains('not web'),
      );
    });

    test('--list must stand alone and says how', () {
      expect(
        _errorOf(['--list', 'apk']),
        contains('Run it alone: dart run flutter_build_tools --list'),
      );
    });
  });

  group('options', () {
    test('every option is read, in both value styles', () {
      final request = build([
        'apk',
        'local',
        '--base-url',
        'http://10.0.2.2:8011',
        '--env-file=other.json',
        '--version',
        '2.0.1',
        '--build-number=9',
        '--no-build',
        '--release-signing',
        '--allow-dirty',
        '--allow-prod-override',
        '--dry-run',
      ]);
      expect(request.baseUrlOverride, 'http://10.0.2.2:8011');
      expect(request.envFilePath, 'other.json');
      expect(request.versionOverride, '2.0.1');
      expect(request.buildNumberOverride, 9);
      expect(
        request.noBuild &&
            request.releaseSigning &&
            request.allowDirty &&
            request.allowProdOverride &&
            request.dryRun,
        isTrue,
      );
      expect(request.overridesProfile, isTrue);
    });

    test('--msix on windows', () {
      expect(build(['windows', 'dev', '--msix']).msix, isTrue);
    });

    test('--help and -h win, --list is exclusive', () {
      expect(parseArgs(['--help']), isA<HelpArgs>());
      expect(parseArgs(['apk', 'dev', '-h']), isA<HelpArgs>());
      expect(parseArgs(['--list']), isA<ListArgs>());
      expect(
        () => parseArgs(['--list', 'apk']),
        usageError('--list takes no other arguments'),
      );
      expect(
        () => parseArgs(['--list', '--dry-run']),
        usageError('--list takes no other arguments'),
      );
    });
  });

  group('rejected command lines', () {
    test('a platform and an environment are required', () {
      expect(() => parseArgs(['apk']), usageError('Missing arguments'));
      expect(() => parseArgs(['--dry-run']), usageError('Missing arguments'));
      expect(() => parseArgs([]), usageError('Missing arguments'));
    });

    test('an extra word is an unknown word, not silently ignored', () {
      expect(
        () => parseArgs(['apk', 'dev', 'extra']),
        usageError('Unknown word "extra"'),
      );
    });

    test('unknown platform and env name the valid ones', () {
      for (final (args, bad) in [
        (['ios', 'dev'], 'ios'),
        (['apk', 'staging'], 'staging'),
      ]) {
        expect(
          () => parseArgs(args),
          usageError('Unknown word "$bad"'),
          reason: '$args',
        );
        for (final valid in [
          'apk, web, windows, macos',
          'dev, preprod, prod, local',
          'release, debug, profile',
        ]) {
          expect(() => parseArgs(args), usageError(valid), reason: '$args');
        }
      }
    });

    test('unknown option', () {
      expect(
        () => parseArgs(['apk', 'dev', '--fast']),
        usageError('Unknown option "--fast"'),
      );
    });

    test('missing and duplicate values', () {
      expect(
        () => parseArgs(['apk', 'dev', '--base-url']),
        usageError('--base-url needs a value'),
      );
      expect(
        () => parseArgs(['apk', 'dev', '--base-url', '--debug']),
        usageError('--base-url needs a value'),
      );
      expect(
        () => parseArgs(['apk', 'dev', '--base-url=']),
        usageError('non-empty'),
      );
      expect(
        () => parseArgs(['apk', 'dev', '--base-url', 'a', '--base-url', 'b']),
        usageError('given twice'),
      );
      expect(
        () => parseArgs(['apk', 'dev', '--debug=yes']),
        usageError('does not take a value'),
      );
    });

    test('--version must be x.y.z', () {
      expect(
        () => parseArgs(['apk', 'dev', '--version', 'v1.0.47']),
        usageError('not x.y.z'),
      );
      expect(
        () => parseArgs(['apk', 'dev', '--version', '1.0']),
        usageError('not x.y.z'),
      );
    });

    test('--build-number must be a positive integer', () {
      expect(
        () => parseArgs(['apk', 'dev', '--build-number', 'x']),
        usageError('positive integer'),
      );
      expect(
        () => parseArgs(['apk', 'dev', '--build-number', '0']),
        usageError('positive integer'),
      );
      expect(
        () => parseArgs(['apk', 'dev', '--build-number=-3']),
        usageError('positive integer'),
      );
    });

    test('platform-specific flags on the wrong platform', () {
      expect(
        () => parseArgs(['apk', 'dev', '--msix']),
        usageError('--msix only applies to the windows'),
      );
      expect(
        () => parseArgs(['windows', 'dev', '--release-signing']),
        usageError('--release-signing only applies to the apk'),
      );
    });
  });

  test('the usage text shows the three sentences with the mode word', () {
    for (final sentence in [
      'apk release preprod',
      'web release dev',
      'windows release prod',
    ]) {
      expect(usageText(), contains(sentence));
    }
    expect(usageText(), contains('<platform> <env> [mode]'));
    expect(usageText(), contains('any order'));
  });

  test('the usage text documents every option', () {
    for (final option in [
      '--mode',
      '--base-url',
      '--env-file',
      '--version',
      '--build-number',
      '--no-build',
      '--release-signing',
      '--msix',
      '--allow-dirty',
      '--allow-prod-override',
      '--dry-run',
      '--list',
      '--help',
    ]) {
      expect(usageText(), contains(option));
    }
  });

  group('usageText parameters', () {
    test('the defaults describe the package command', () {
      final text = usageText();
      expect(text, startsWith('Flutter build tool: one command'));
      expect(
        text,
        contains('  dart run flutter_build_tools <platform> <env> [mode]'),
      );
      expect(text, contains('(config/env/<env>.json)'));
      expect(text, contains('see the flutter_build_tools README'));
      expect(text, isNot(contains('wrapper')));
    });

    test(
      'title, invocation, env folder and docs are used where they belong',
      () {
        final text = usageText(
          title: 'Acme Store',
          invocation: 'make build',
          envDir: 'env',
          docs: 'docs/BUILD.md',
        );
        expect(text, startsWith('Acme Store build tool: one command'));
        expect(
          text,
          contains('  make build <platform> <env> [mode] [options]'),
        );
        expect(text, contains('  make build'));
        expect(text, contains('(env/<env>.json)'));
        expect(text, contains('(release only, see docs/BUILD.md)'));
        expect(text, isNot(contains('flutter_build_tools')));
      },
    );

    test('wrappers follow the picker line, notes in column 54', () {
      final lines = usageText(
        wrappers: const [
          WrapperScript('scripts/build.sh', 'macOS/Linux wrapper'),
          WrapperScript('scripts/build.ps1', 'Windows wrapper'),
        ],
      ).split('\n');
      final usage = lines.indexOf('Usage:');
      expect(lines.sublist(usage + 1, usage + 5), [
        '  dart run flutter_build_tools <platform> <env> [mode] [options]',
        '  dart run flutter_build_tools                        (interactive picker, in a terminal)',
        '  scripts/build.sh <platform> <env> [mode] [options]  (macOS/Linux wrapper)',
        '  scripts/build.ps1 <platform> <env> [mode] [options] (Windows wrapper)',
      ]);
    });

    test('the init hint says AppEnv is written and how to skip it', () {
      final text = usageText(initHint: true);
      expect(text, contains('init [--force] [--dry-run] [--no-app-env]'));
      expect(text, contains('AppEnv (lib/config/app_env.dart'));
      expect(text, contains('--no-app-env skips AppEnv'));
      expect(text, isNot(contains('[--app-env]')));
      // Without the hint the text does not mention init at all.
      expect(usageText(), isNot(contains('AppEnv')));
    });

    test('a command wider than the column keeps one space before its note', () {
      final text = usageText(
        invocation: 'dart run some/very/long/folder/of/tools/build_it.dart',
      );
      expect(
        text,
        contains(
          '  dart run some/very/long/folder/of/tools/build_it.dart (interactive picker, in a terminal)',
        ),
      );
    });
  });

  group('parseArgs invocation', () {
    test('every message that shows an example uses it', () {
      for (final args in [
        ['staging'],
        ['apk'],
        ['apk', 'dev', '--nope'],
        ['apk', 'dev', 'prod'],
        ['apk', 'web', 'dev'],
        ['apk', 'dev', 'debug', '--release'],
        ['--list', 'apk'],
      ]) {
        try {
          parseArgs(args, invocation: 'make build');
          fail('expected a UsageError for $args');
        } on UsageError catch (e) {
          expect(e.message, contains('make build'), reason: '$args');
          expect(e.message, isNot(contains('flutter_build_tools')));
          expect(e.message, isNot(contains('tool/build/build.dart')));
        }
      }
    });
  });

  group('the init command', () {
    InitArgs init(List<String> args) => parseArgs(args) as InitArgs;

    test('plain init writes AppEnv and has --force and --dry-run off', () {
      final parsed = init(['init']);
      expect(parsed.force, isFalse);
      expect(parsed.dryRun, isFalse);
      expect(parsed.appEnv, isTrue);
    });

    test('the switches, in any order and case', () {
      final parsed = init(['INIT', '--no-app-env', '--dry-run', '--force']);
      expect(parsed.force, isTrue);
      expect(parsed.dryRun, isTrue);
      expect(parsed.appEnv, isFalse);
      expect(init(['--force', 'init']).force, isTrue);
      expect(init(['--no-app-env', 'init']).appEnv, isFalse);
    });

    test('--app-env is accepted and is the default', () {
      expect(init(['init', '--app-env']).appEnv, isTrue);
      final parsed = init(['INIT', '--app-env', '--dry-run', '--force']);
      expect(parsed.appEnv, isTrue);
      expect(parsed.dryRun, isTrue);
      expect(parsed.force, isTrue);
    });

    test('--app-env and --no-app-env together are refused', () {
      for (final args in [
        ['init', '--app-env', '--no-app-env'],
        ['--no-app-env', 'init', '--app-env'],
      ]) {
        expect(
          _errorOf(args),
          allOf(
            contains('--app-env and --no-app-env contradict each other'),
            contains('Example: dart run flutter_build_tools init --dry-run'),
          ),
          reason: args.join(' '),
        );
      }
    });

    test('a flag that takes no value says so for --no-app-env too', () {
      expect(
        _errorOf(['init', '--no-app-env=true']),
        contains('--no-app-env does not take a value'),
      );
    });

    test('--help wins, as everywhere', () {
      expect(parseArgs(['init', '--help']), isA<HelpArgs>());
    });

    test('words and options of a build are refused', () {
      expect(
        _errorOf(['init', 'apk']),
        contains('init takes no platform, environment or mode (got "apk")'),
      );
      expect(_errorOf(['init', 'apk', 'dev']), contains('got "apk", "dev"'));
      expect(
        _errorOf(['init', '--mode', 'debug']),
        contains('does not take --mode'),
      );
      expect(_errorOf(['init', '--debug']), contains('does not take --debug'));
      expect(
        _errorOf(['init', '--no-build']),
        contains('does not take --no-build'),
      );
      expect(_errorOf(['init', '--list']), contains('--list takes no other'));
    });

    test('--force, --app-env and --no-app-env mean nothing for a build', () {
      expect(
        _errorOf(['apk', 'dev', '--force']),
        contains(
          '--force only applies to the init command (e.g. dart run flutter_build_tools init --force)',
        ),
      );
      expect(
        _errorOf(['apk', 'dev', '--app-env']),
        contains('--app-env only applies to the init command'),
      );
      expect(
        _errorOf(['apk', 'dev', '--no-app-env']),
        contains(
          '--no-app-env only applies to the init command (e.g. dart run flutter_build_tools init --no-app-env)',
        ),
      );
    });

    test('init names the flags it takes', () {
      expect(
        _errorOf(['init', '--debug']),
        contains('it takes --force, --dry-run and --no-app-env'),
      );
    });

    test('init is a word of its own, not a platform, env or mode', () {
      expect(_errorOf(['apk', 'init']), contains('Unknown word "init"'));
    });

    test('the example of the error uses the invocation', () {
      try {
        parseArgs(['init', 'apk'], invocation: 'make build');
        fail('expected a UsageError');
      } on UsageError catch (e) {
        expect(e.message, contains('Example: make build init --dry-run'));
      }
    });
  });
}
