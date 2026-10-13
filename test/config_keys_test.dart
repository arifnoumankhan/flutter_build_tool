// Every key of tool/build/build_config.json beyond the required ones: its
// default, what it accepts and what it rejects.
import 'dart:convert';

import 'package:test/test.dart';

import 'package:flutter_build_tools/src/config.dart';
import 'package:flutter_build_tools/src/model.dart';

/// Only the required keys.
Map<String, Object?> minimal() => {
  'app': 'example',
  'slug': 'ExampleApp',
  'displayName': 'Example App',
  'envDir': 'config/env',
  'windows': {
    'exe': 'example_app.exe',
    'installerScript': 'installer/example_app.iss',
  },
  'macos': {'appName': 'Example App'},
};

AppConfig parse(Map<String, Object?> config) =>
    AppConfig.parse(jsonEncode(config));

/// [minimal] with [extra] merged into the top level.
AppConfig parseWith(Map<String, Object?> extra) =>
    parse({...minimal(), ...extra});

/// [minimal] with [extra] merged into its `windows` section.
AppConfig parseWindows(Map<String, Object?> extra) => parse({
  ...minimal(),
  'windows': {...(minimal()['windows']! as Map<String, Object?>), ...extra},
});

Matcher failsWith(String text) => throwsA(
  isA<BuildException>().having((e) => e.message, 'message', contains(text)),
);

void main() {
  group('defaults: a config with only the required keys', () {
    final config = parse(minimal());

    test('keeps the behaviour of a tool without the optional keys', () {
      expect(config.devHostMarkers, isEmpty);
      expect(config.cleanupPrefix, isNull);
      expect(config.docs, isNull);
      expect(config.wrappers, isEmpty);
      expect(config.envSchema.extraKeys, isEmpty);
      expect(config.envSchema.extraUrlKeys, isEmpty);
    });

    test('the installer cleanup prefix is the slug', () {
      expect(config.installerCleanupPrefix, 'ExampleApp');
    });

    test('an env file may hold exactly APP_ENV, BASE_URL and POS_WEB_URL', () {
      expect(config.envSchema.allowedKeys, [
        'APP_ENV',
        'BASE_URL',
        'POS_WEB_URL',
      ]);
      expect(config.envSchema.optionalUrlKeys, ['POS_WEB_URL']);
    });

    test('the env folder default is config/env', () {
      expect(AppConfig.defaultEnvDir, 'config/env');
    });
  });

  group('devHostMarkers', () {
    test('are read and trimmed', () {
      final config = parseWith({
        'devHostMarkers': [' devexample ', 'staging.corp'],
      });
      expect(config.devHostMarkers, ['devexample', 'staging.corp']);
    });

    test('an empty list is the default', () {
      expect(parseWith({'devHostMarkers': <String>[]}).devHostMarkers, isEmpty);
    });

    for (final (label, value) in <(String, Object?)>[
      ('a string', 'devexample'),
      ('an object', {'a': 1}),
      ('an empty entry', ['devexample', '']),
      ('a blank entry', ['  ']),
      ('a non-string entry', [1]),
    ]) {
      test('rejects $label', () {
        expect(
          () => parseWith({'devHostMarkers': value}),
          failsWith('"devHostMarkers" must be a list of non-empty strings'),
        );
      });
    }
  });

  group('windows.cleanupPrefix', () {
    test('is used as given', () {
      final config = parseWindows({'cleanupPrefix': 'Example'});
      expect(config.cleanupPrefix, 'Example');
      expect(config.installerCleanupPrefix, 'Example');
    });

    test('may contain spaces, dots, dashes and underscores inside', () {
      expect(
        parseWindows({'cleanupPrefix': 'Example App-Setup_1.'}).cleanupPrefix,
        'Example App-Setup_1.',
      );
    });

    for (final value in ['', '   ', 5, null, true]) {
      test('rejects ${jsonEncode(value)}', () {
        expect(
          () => parseWindows({'cleanupPrefix': value}),
          failsWith('"windows.cleanupPrefix" must be a non-empty string'),
        );
      });
    }

    // The value decides which files are DELETED, so it must stay a plain name.
    for (final value in [
      '../',
      '*',
      'a/b',
      r'a\b',
      ' Example',
      '.hidden',
      'Ex*',
      '..',
    ]) {
      test('rejects ${jsonEncode(value)} (paths and wildcards)', () {
        expect(
          () => parseWindows({'cleanupPrefix': value}),
          failsWith(
            '"windows.cleanupPrefix" must start with a letter or digit',
          ),
        );
      });
    }
  });

  group('envFile', () {
    test('extraKeys and extraUrlKeys extend the allowed keys, in order', () {
      final config = parseWith({
        'envFile': {
          'extraKeys': ['FEATURE_SET', 'TENANT'],
          'extraUrlKeys': ['ANALYTICS_URL'],
        },
      });
      expect(config.envSchema.extraKeys, ['FEATURE_SET', 'TENANT']);
      expect(config.envSchema.extraUrlKeys, ['ANALYTICS_URL']);
      expect(config.envSchema.allowedKeys, [
        'APP_ENV',
        'BASE_URL',
        'POS_WEB_URL',
        'FEATURE_SET',
        'TENANT',
        'ANALYTICS_URL',
      ]);
      expect(config.envSchema.optionalUrlKeys, [
        'POS_WEB_URL',
        'ANALYTICS_URL',
      ]);
    });

    test('an empty section changes nothing', () {
      final config = parseWith({'envFile': <String, Object?>{}});
      expect(config.envSchema.allowedKeys, hasLength(3));
    });

    for (final (label, value, message) in <(String, Object?, String)>[
      ('lower case', ['feature_set'], 'must be UPPER_SNAKE_CASE'),
      ('with a dash', ['FEATURE-SET'], 'must be UPPER_SNAKE_CASE'),
      ('starting with a digit', ['1FEATURE'], 'must be UPPER_SNAKE_CASE'),
      ('APP_ENV', ['APP_ENV'], 'already a built-in or generated key'),
      ('BASE_URL', ['BASE_URL'], 'already a built-in or generated key'),
      ('POS_WEB_URL', ['POS_WEB_URL'], 'already a built-in or generated key'),
      ('BUILD_SHA', ['BUILD_SHA'], 'already a built-in or generated key'),
      ('a duplicate', ['TENANT', 'TENANT'], 'lists "TENANT" twice'),
    ]) {
      test('extraKeys rejects $label', () {
        expect(
          () => parseWith({
            'envFile': {'extraKeys': value},
          }),
          failsWith(message),
        );
      });
      test('extraUrlKeys rejects $label', () {
        expect(
          () => parseWith({
            'envFile': {'extraUrlKeys': value},
          }),
          failsWith(message),
        );
      });
    }

    test('a key in both lists is a duplicate', () {
      expect(
        () => parseWith({
          'envFile': {
            'extraKeys': ['TENANT'],
            'extraUrlKeys': ['TENANT'],
          },
        }),
        failsWith('lists "TENANT" twice (or in both lists)'),
      );
    });

    test('rejects a non-list and non-string entries', () {
      expect(
        () => parseWith({
          'envFile': {'extraKeys': 'TENANT'},
        }),
        failsWith('"envFile.extraKeys" must be a list of non-empty strings'),
      );
      expect(
        () => parseWith({
          'envFile': {
            'extraUrlKeys': [1],
          },
        }),
        failsWith('"envFile.extraUrlKeys" must be a list of non-empty strings'),
      );
    });

    test('must be an object', () {
      expect(
        () => parseWith({'envFile': 'x'}),
        failsWith('"envFile" must be an object'),
      );
    });
  });

  group('cli', () {
    test('docs and wrappers are read', () {
      final config = parseWith({
        'cli': {
          'docs': 'tool/build/README.md',
          'wrappers': [
            {'script': 'scripts/build.sh', 'label': 'macOS/Linux wrapper'},
            {'script': 'scripts/build.ps1', 'label': 'Windows wrapper'},
          ],
        },
      });
      expect(config.docs, 'tool/build/README.md');
      expect(config.wrappers.map((w) => w.script), [
        'scripts/build.sh',
        'scripts/build.ps1',
      ]);
      expect(config.wrappers.map((w) => w.label), [
        'macOS/Linux wrapper',
        'Windows wrapper',
      ]);
    });

    test('each one alone is fine', () {
      expect(
        parseWith({
          'cli': {'docs': 'docs/build.md'},
        }).wrappers,
        isEmpty,
      );
      expect(
        parseWith({
          'cli': {
            'wrappers': [
              {'script': 'make.sh', 'label': 'make'},
            ],
          },
        }).docs,
        isNull,
      );
    });

    test('rejects a blank docs value', () {
      expect(
        () => parseWith({
          'cli': {'docs': ' '},
        }),
        failsWith('"cli.docs" must be a non-empty string'),
      );
    });

    test('rejects a malformed wrappers list', () {
      expect(
        () => parseWith({
          'cli': {'wrappers': 'scripts/build.sh'},
        }),
        failsWith('"cli.wrappers" must be a list of {"script", "label"}'),
      );
      expect(
        () => parseWith({
          'cli': {
            'wrappers': ['scripts/build.sh'],
          },
        }),
        failsWith('"cli.wrappers" must be a list of {"script", "label"}'),
      );
      expect(
        () => parseWith({
          'cli': {
            'wrappers': [
              {'script': 'scripts/build.sh'},
            ],
          },
        }),
        failsWith('"cli.wrappers[].label" must be a non-empty string'),
      );
      expect(
        () => parseWith({
          'cli': {
            'wrappers': [
              {'label': 'x'},
            ],
          },
        }),
        failsWith('"cli.wrappers[].script" must be a non-empty string'),
      );
    });
  });

  group('unknown keys are typos, not silently ignored', () {
    test('at the top level, naming the key and the known ones', () {
      expect(
        () => parseWith({
          'devHostMarker': ['devexample'],
        }),
        failsWith('has unknown key "devHostMarker". Known keys: app, cli,'),
      );
    });

    test('inside windows, macos, envFile, cli and a wrapper', () {
      expect(
        () => parseWindows({'exeName': 'x.exe'}),
        failsWith('"windows" has unknown key "exeName"'),
      );
      expect(
        () => parseWith({
          'macos': {'appName': 'Example App', 'bundleId': 'x'},
        }),
        failsWith('"macos" has unknown key "bundleId"'),
      );
      expect(
        () => parseWith({
          'envFile': {'extraKey': <String>[]},
        }),
        failsWith('"envFile" has unknown key "extraKey"'),
      );
      expect(
        () => parseWith({
          'cli': {'doc': 'x'},
        }),
        failsWith('"cli" has unknown key "doc"'),
      );
      expect(
        () => parseWith({
          'cli': {
            'wrappers': [
              {'script': 'a.sh', 'label': 'a', 'platform': 'mac'},
            ],
          },
        }),
        failsWith('"cli.wrappers" has unknown key "platform"'),
      );
    });

    test(r'keys starting with $ or _ are comments and ignored', () {
      final config = parse({
        r'$schema': 'https://example.com/schema.json',
        '_comment': 'hello',
        ...minimal(),
        'windows': {
          '_note': 'installer facts',
          ...(minimal()['windows']! as Map<String, Object?>),
        },
        'cli': {r'$comment': 'x', 'docs': 'tool/build/README.md'},
        'envFile': {
          '_why': 'x',
          'extraKeys': ['TENANT'],
        },
      });
      expect(config.slug, 'ExampleApp');
      expect(config.docs, 'tool/build/README.md');
      expect(config.envSchema.extraKeys, ['TENANT']);
    });
  });

  test(
    'parsed on its own (nothing inferred), the four basic keys are required',
    () {
      for (final key in ['app', 'slug', 'displayName', 'envDir']) {
        final config = minimal()..remove(key);
        expect(
          () => parse(config),
          failsWith('"$key" must be a non-empty string'),
          reason: 'without "$key"',
        );
      }
    },
  );

  test('the windows and macos sections are optional', () {
    for (final key in ['windows', 'macos']) {
      final config = parse(minimal()..remove(key));
      expect(config.slug, 'ExampleApp', reason: 'without "$key"');
    }
    final bare = parse(
      minimal()
        ..remove('windows')
        ..remove('macos'),
    );
    expect(bare.unresolved.keys, [
      'windows.exe',
      'windows.installerScript',
      'macos.appName',
    ]);
  });
}
