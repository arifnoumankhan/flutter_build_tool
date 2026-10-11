import 'package:test/test.dart';

import 'package:flutter_build_tools/src/guards.dart';
import 'package:flutter_build_tools/src/keystore.dart';
import 'package:flutter_build_tools/src/model.dart';

const _validKeystore = KeystoreStatus(
  propertiesFound: true,
  missingKeys: [],
  storeFileExists: true,
  optedInByFile: false,
);
const _optedInKeystore = KeystoreStatus(
  propertiesFound: true,
  missingKeys: [],
  storeFileExists: true,
  optedInByFile: true,
);
const _missingFile = KeystoreStatus(
  propertiesFound: false,
  missingKeys: keystoreKeys,
  storeFileExists: false,
  optedInByFile: false,
);
const _missingKeys = KeystoreStatus(
  propertiesFound: true,
  missingKeys: ['keyAlias'],
  storeFileExists: true,
  optedInByFile: false,
);
const _noStoreFile = KeystoreStatus(
  propertiesFound: true,
  missingKeys: [],
  storeFileExists: false,
  optedInByFile: false,
);

const _urls = {
  BuildEnv.dev: 'https://devexample.example.com/public',
  BuildEnv.preprod: 'https://preprod.example.com/public',
  BuildEnv.prod: 'https://v1.example.com/public',
  BuildEnv.local: 'http://127.0.0.1:8011',
};

/// A fully valid input for [request]; tests then break one thing.
List<Finding> guards(
  BuildRequest request, {
  String? fileAppEnv,
  String? baseUrl,
  String? posWebUrl,
  bool? dirty = false,
  HostOs host = HostOs.macos,
  KeystoreStatus? keystore = _validKeystore,
  int? freeDiskBytes,
  List<String> devHostMarkers = const ['devexample'],
  Map<String, String> extraUrls = const {},
  String envDir = 'config/env',
}) => evaluateGuards(
  GuardInput(
    request: request,
    envFileLabel: 'config/env/${request.env.name}.json',
    fileAppEnv: fileAppEnv ?? request.env.name,
    baseUrl: baseUrl ?? request.baseUrlOverride ?? _urls[request.env]!,
    posWebUrl: posWebUrl,
    gitDirty: dirty,
    host: host,
    keystore: request.platform == BuildPlatform.apk ? keystore : null,
    freeDiskBytes: freeDiskBytes,
    devHostMarkers: devHostMarkers,
    extraUrls: extraUrls,
    envDir: envDir,
  ),
);

BuildRequest req(
  BuildPlatform platform,
  BuildEnv env, {
  BuildMode mode = BuildMode.release,
  String? baseUrl,
  String? envFile,
  bool allowDirty = false,
  bool allowProdOverride = false,
  bool releaseSigning = false,
  bool msix = false,
}) => BuildRequest(
  platform: platform,
  env: env,
  mode: mode,
  baseUrlOverride: baseUrl,
  envFilePath: envFile,
  allowDirty: allowDirty,
  allowProdOverride: allowProdOverride,
  releaseSigning: releaseSigning,
  msix: msix,
);

Iterable<String> errors(List<Finding> findings) =>
    findings.where((f) => f.isError).map((f) => f.code);
Iterable<String> warnings(List<Finding> findings) =>
    findings.where((f) => !f.isError).map((f) => f.code);

void main() {
  group('a clean build is accepted', () {
    for (final env in BuildEnv.values) {
      for (final platform in [BuildPlatform.apk, BuildPlatform.web]) {
        test(
          '${platform.name} ${env.name}: no findings (valid release keystore)',
          () {
            // Non-prod apk without opt-in warns about the debug key, so opt in.
            final findings = guards(
              req(platform, env, releaseSigning: platform == BuildPlatform.apk),
            );
            expect(findings, isEmpty);
          },
        );
      }
    }

    test('windows on Windows and macos on macOS', () {
      expect(
        guards(req(BuildPlatform.windows, BuildEnv.prod), host: HostOs.windows),
        isEmpty,
      );
      expect(
        guards(req(BuildPlatform.macos, BuildEnv.prod), host: HostOs.macos),
        isEmpty,
      );
    });
  });

  group('app-env-mismatch', () {
    test('the env file must say the requested env', () {
      final findings = guards(
        req(BuildPlatform.web, BuildEnv.preprod),
        fileAppEnv: 'dev',
      );
      expect(errors(findings), ['app-env-mismatch']);
      expect(
        findings.single.message,
        allOf(
          contains('config/env/preprod.json'),
          contains('"dev"'),
          contains('"preprod"'),
        ),
      );
    });

    for (final env in BuildEnv.values) {
      test('${env.name} refuses every other APP_ENV', () {
        for (final other in BuildEnv.values.where((e) => e != env)) {
          expect(
            errors(guards(req(BuildPlatform.web, env), fileAppEnv: other.name)),
            contains('app-env-mismatch'),
          );
        }
      });
    }
  });

  group('not-https', () {
    for (final env in [BuildEnv.dev, BuildEnv.preprod, BuildEnv.prod]) {
      test('${env.name} refuses an http BASE_URL', () {
        final findings = guards(
          req(BuildPlatform.web, env),
          baseUrl: 'http://example.com/public',
        );
        expect(errors(findings), contains('not-https'));
        expect(
          findings.firstWhere((f) => f.code == 'not-https').message,
          contains('only the "local" env may use http'),
        );
      });

      test('${env.name} refuses an http POS_WEB_URL', () {
        expect(
          errors(
            guards(
              req(BuildPlatform.web, env),
              posWebUrl: 'http://pos.example.com',
            ),
          ),
          contains('not-https'),
        );
      });
    }

    test('local may use http', () {
      expect(
        guards(
          req(BuildPlatform.web, BuildEnv.local),
          baseUrl: 'http://192.168.1.20:8011',
          posWebUrl: 'http://127.0.0.1:8011/web_pos',
        ),
        isEmpty,
      );
    });

    test(
      'an http --base-url on dev is refused and the message points at --base-url',
      () {
        final findings = guards(
          req(
            BuildPlatform.web,
            BuildEnv.dev,
            baseUrl: 'http://192.168.1.20:8011',
          ),
        );
        expect(errors(findings), contains('not-https'));
        expect(
          findings.firstWhere((f) => f.code == 'not-https').message,
          contains('--base-url'),
        );
      },
    );
  });

  group('prod-dev-url', () {
    const looksDev = {
      'https://devexample.example.com/public': 'devexample',
      'https://DEVEXAMPLE.example.com': 'devexample',
      'https://localhost/public': 'localhost',
      'https://localhost.example.com': 'localhost',
      'https://127.0.0.1/public': '127.0.0.1',
      'https://[::1]/public': '::1',
      'https://10.0.2.2/public': '10.0.2.2',
      'https://192.168.1.5/public': '192.168.',
      'https://10.1.2.3/public': '10.x',
    };
    looksDev.forEach((url, marker) {
      test('prod refuses $url (matches $marker)', () {
        expect(
          devLookingMarker(url, extraMarkers: const ['devexample']),
          marker,
        );
        final findings = guards(
          req(
            BuildPlatform.web,
            BuildEnv.prod,
            baseUrl: url,
            allowProdOverride: true,
          ),
        );
        expect(errors(findings), contains('prod-dev-url'));
        expect(
          findings.firstWhere((f) => f.code == 'prod-dev-url').message,
          contains(marker),
        );
      });
    });

    test('prod refuses a dev-looking POS_WEB_URL too', () {
      expect(
        errors(
          guards(
            req(BuildPlatform.web, BuildEnv.prod),
            posWebUrl: 'https://devexample.example.com/web_pos',
          ),
        ),
        contains('prod-dev-url'),
      );
    });

    for (final url in [
      'https://v1.example.com/public',
      'https://pos.example.com',
      'https://preprod.example.com/public',
      'https://100.example.com',
      'https://110.2.3.4',
    ]) {
      test(
        '$url does not look like dev',
        () => expect(devLookingMarker(url), isNull),
      );
    }

    test('only prod cares: dev and preprod may use dev-looking hosts', () {
      expect(
        guards(
          req(BuildPlatform.web, BuildEnv.dev),
          baseUrl: 'https://devexample.example.com/public',
        ),
        isEmpty,
      );
      expect(
        guards(
          req(BuildPlatform.web, BuildEnv.preprod),
          baseUrl: 'https://10.1.2.3/public',
        ),
        isEmpty,
      );
    });
  });

  group('the project configuration reaches the guards', () {
    group('devHostMarkers', () {
      test('devLookingMarker has no project marker by default', () {
        expect(devLookingMarker('https://devexample.example.com'), isNull);
        expect(devLookingMarker('https://staging.example.com'), isNull);
      });

      test('a marker matches case-insensitively and is reported as given', () {
        expect(
          devLookingMarker(
            'https://API.STAGING.example.com',
            extraMarkers: const ['staging'],
          ),
          'staging',
        );
        expect(
          devLookingMarker(
            'https://staging.example.com',
            extraMarkers: const ['STAGING'],
          ),
          'STAGING',
        );
      });

      test('a project marker is checked before the built-in ones', () {
        expect(
          devLookingMarker(
            'https://staging.localhost',
            extraMarkers: const ['staging'],
          ),
          'staging',
        );
        expect(devLookingMarker('https://staging.localhost'), 'localhost');
      });

      test('the first matching marker wins', () {
        expect(
          devLookingMarker(
            'https://qa.staging.example.com',
            extraMarkers: const ['staging', 'qa'],
          ),
          'staging',
        );
      });

      test('prod refuses a URL with a configured marker, naming it', () {
        final findings = guards(
          req(BuildPlatform.web, BuildEnv.prod),
          baseUrl: 'https://staging.example.com/public',
          devHostMarkers: const ['staging'],
        );
        expect(errors(findings), contains('prod-dev-url'));
        expect(
          findings.firstWhere((f) => f.code == 'prod-dev-url').message,
          allOf(contains('matches "staging"'), contains('BASE_URL')),
        );
      });

      test(
        'without the marker the same URL is accepted (the key is opt-in)',
        () {
          expect(
            errors(
              guards(
                req(BuildPlatform.web, BuildEnv.prod),
                baseUrl: 'https://staging.example.com/public',
                devHostMarkers: const [],
              ),
            ),
            isNot(contains('prod-dev-url')),
          );
        },
      );

      test('a marker only matters for prod', () {
        expect(
          guards(
            req(BuildPlatform.web, BuildEnv.preprod),
            baseUrl: 'https://staging.example.com/public',
            devHostMarkers: const ['staging'],
          ),
          isEmpty,
        );
      });
    });

    group('extra URL keys (envFile.extraUrlKeys)', () {
      test('are held to https outside local, naming the key', () {
        final findings = guards(
          req(BuildPlatform.web, BuildEnv.preprod),
          extraUrls: const {'ANALYTICS_URL': 'http://a.example.com'},
        );
        expect(errors(findings), ['not-https']);
        expect(
          findings.single.message,
          allOf(
            contains('ANALYTICS_URL "http://a.example.com"'),
            contains('config/env/preprod.json'),
            isNot(contains('--base-url')),
          ),
        );
      });

      test('may use http on local', () {
        expect(
          guards(
            req(BuildPlatform.web, BuildEnv.local),
            extraUrls: const {'ANALYTICS_URL': 'http://127.0.0.1:9000'},
          ),
          isEmpty,
        );
      });

      test('are checked for dev-looking hosts on prod', () {
        final findings = guards(
          req(BuildPlatform.web, BuildEnv.prod),
          extraUrls: const {'ANALYTICS_URL': 'https://devexample.example.com'},
        );
        expect(errors(findings), ['prod-dev-url']);
        expect(
          findings.single.message,
          allOf(
            contains('prod ANALYTICS_URL'),
            contains('matches "devexample"'),
          ),
        );
      });

      test('a clean extra URL changes nothing', () {
        expect(
          guards(
            req(BuildPlatform.web, BuildEnv.prod),
            extraUrls: const {'ANALYTICS_URL': 'https://a.example.com'},
          ),
          isEmpty,
        );
      });
    });

    group('envDir', () {
      test('prod-override points at the configured env folder', () {
        final findings = guards(
          req(
            BuildPlatform.web,
            BuildEnv.prod,
            baseUrl: 'https://other.example.com/public',
          ),
          envDir: 'environments',
        );
        expect(
          findings.firstWhere((f) => f.code == 'prod-override').message,
          contains('Prefer editing environments/prod.json and committing it.'),
        );
      });

      test('the default is config/env', () {
        final findings = guards(
          req(
            BuildPlatform.web,
            BuildEnv.prod,
            baseUrl: 'https://other.example.com/public',
          ),
        );
        expect(
          findings.firstWhere((f) => f.code == 'prod-override').message,
          contains('Prefer editing config/env/prod.json and committing it.'),
        );
      });
    });
  });

  group('prod-override', () {
    test('--base-url on prod needs --allow-prod-override', () {
      final refused = guards(
        req(
          BuildPlatform.web,
          BuildEnv.prod,
          baseUrl: 'https://other.example.com/public',
        ),
      );
      expect(errors(refused), ['prod-override']);
      expect(refused.single.message, contains('--base-url'));
      expect(
        guards(
          req(
            BuildPlatform.web,
            BuildEnv.prod,
            baseUrl: 'https://other.example.com/public',
            allowProdOverride: true,
          ),
        ),
        isEmpty,
      );
    });

    test(
      '--env-file on prod needs it too, so the guard cannot be bypassed that way',
      () {
        final refused = guards(
          req(BuildPlatform.web, BuildEnv.prod, envFile: 'ci/prod.json'),
        );
        expect(errors(refused), ['prod-override']);
        expect(refused.single.message, contains('--env-file'));
        expect(
          guards(
            req(
              BuildPlatform.web,
              BuildEnv.prod,
              envFile: 'ci/prod.json',
              allowProdOverride: true,
            ),
          ),
          isEmpty,
        );
      },
    );

    test('other envs may override freely', () {
      for (final env in [BuildEnv.dev, BuildEnv.preprod]) {
        expect(
          guards(
            req(
              BuildPlatform.web,
              env,
              baseUrl: 'https://other.example.com/public',
              envFile: 'x.json',
            ),
          ),
          isEmpty,
        );
      }
    });

    test('--allow-prod-override does not disable the other prod checks', () {
      final findings = guards(
        req(
          BuildPlatform.web,
          BuildEnv.prod,
          baseUrl: 'https://devexample.example.com',
          allowProdOverride: true,
        ),
      );
      expect(errors(findings), ['prod-dev-url']);
    });
  });

  group('prod-mode', () {
    for (final mode in [BuildMode.debug, BuildMode.profile]) {
      test('prod refuses ${mode.name}', () {
        final findings = guards(
          req(BuildPlatform.web, BuildEnv.prod, mode: mode),
        );
        expect(errors(findings), ['prod-mode']);
        expect(findings.single.message, contains(mode.flutterFlag));
      });

      test('other envs accept ${mode.name}', () {
        for (final env in [BuildEnv.dev, BuildEnv.preprod, BuildEnv.local]) {
          expect(
            errors(guards(req(BuildPlatform.web, env, mode: mode))),
            isEmpty,
          );
        }
      });
    }

    test(
      'prod release is accepted',
      () => expect(
        errors(guards(req(BuildPlatform.web, BuildEnv.prod))),
        isEmpty,
      ),
    );
  });

  group('dirty-tree truth table', () {
    // (env is prod, dirty, allowDirty) -> (error?, warning?)
    const table = [
      (true, false, false, false, false),
      (true, false, true, false, false),
      (true, true, false, true, false),
      (true, true, true, false, true),
      (true, null, false, true, false),
      (true, null, true, false, true),
      (false, false, false, false, false),
      (false, true, false, false, true),
      (false, true, true, false, true),
      (false, null, false, false, true),
    ];
    for (final (prod, dirty, allow, isError, isWarning) in table) {
      test(
        '${prod ? 'prod' : 'dev'} dirty=$dirty allowDirty=$allow -> ${isError
            ? 'error'
            : isWarning
            ? 'warning'
            : 'ok'}',
        () {
          final findings = guards(
            req(
              BuildPlatform.web,
              prod ? BuildEnv.prod : BuildEnv.dev,
              allowDirty: allow,
            ),
            dirty: dirty,
          );
          expect(errors(findings).contains('dirty-tree'), isError);
          expect(warnings(findings).contains('dirty-tree'), isWarning);
        },
      );
    }

    test('the prod message says how to proceed', () {
      final message = guards(
        req(BuildPlatform.web, BuildEnv.prod),
        dirty: true,
      ).single.message;
      expect(message, allOf(contains('clean tree'), contains('--allow-dirty')));
    });
  });

  group('host', () {
    for (final host in HostOs.values) {
      test('windows target on ${host.name}', () {
        final findings = guards(
          req(BuildPlatform.windows, BuildEnv.dev),
          host: host,
        );
        expect(
          errors(findings).contains('host-windows'),
          host != HostOs.windows,
        );
      });

      test('macos target on ${host.name}', () {
        final findings = guards(
          req(BuildPlatform.macos, BuildEnv.dev),
          host: host,
        );
        expect(errors(findings).contains('host-macos'), host != HostOs.macos);
      });

      test('apk and web build on ${host.name}', () {
        expect(
          errors(guards(req(BuildPlatform.apk, BuildEnv.dev), host: host)),
          isEmpty,
        );
        expect(
          errors(guards(req(BuildPlatform.web, BuildEnv.dev), host: host)),
          isEmpty,
        );
      });
    }

    test('the refusal says where to run it', () {
      final windows = guards(
        req(BuildPlatform.windows, BuildEnv.dev),
        host: HostOs.macos,
      ).single.message;
      expect(
        windows,
        allOf(
          contains('only be built on Windows'),
          contains('this host: macos'),
          contains('cross-build'),
        ),
      );
      final macos = guards(
        req(BuildPlatform.macos, BuildEnv.dev),
        host: HostOs.windows,
      ).single.message;
      expect(
        macos,
        allOf(
          contains('only be built on macOS'),
          contains('this host: windows'),
        ),
      );
    });
  });

  group('msix and release-signing flags', () {
    test('--msix is release only', () {
      expect(
        errors(
          guards(
            req(
              BuildPlatform.windows,
              BuildEnv.dev,
              mode: BuildMode.debug,
              msix: true,
            ),
            host: HostOs.windows,
          ),
        ),
        ['msix-mode'],
      );
      expect(
        errors(
          guards(
            req(BuildPlatform.windows, BuildEnv.dev, msix: true),
            host: HostOs.windows,
          ),
        ),
        isEmpty,
      );
    });

    test('--release-signing on a debug build is flagged as ignored', () {
      final findings = guards(
        req(
          BuildPlatform.apk,
          BuildEnv.dev,
          mode: BuildMode.debug,
          releaseSigning: true,
        ),
      );
      expect(warnings(findings), ['release-signing-ignored']);
    });
  });

  group('low-disk', () {
    const gigabyte = 1024 * 1024 * 1024;
    final web = req(BuildPlatform.web, BuildEnv.dev);

    test('the threshold is 3 GB', () {
      expect(lowDiskThresholdBytes, 3 * gigabyte);
    });

    test('less than 3 GB free is a loud warning, never an error', () {
      final findings = guards(web, freeDiskBytes: 3 * gigabyte - 1);
      expect(errors(findings), isEmpty);
      expect(warnings(findings), ['low-disk']);
      expect(
        findings.single.message,
        allOf(
          startsWith('LOW DISK SPACE'),
          contains('only 3.0 GB free'),
          contains('.dart_tool/flutter_build'),
          contains('flutter clean'),
        ),
      );
    });

    test('the message shows how much is free', () {
      final findings = guards(web, freeDiskBytes: (0.4 * gigabyte).round());
      expect(findings.single.message, contains('only 0.4 GB free'));
    });

    test('3 GB or more, an unknown amount and no check are silent', () {
      expect(guards(web, freeDiskBytes: 3 * gigabyte), isEmpty);
      expect(guards(web, freeDiskBytes: 500 * gigabyte), isEmpty);
      expect(guards(web), isEmpty, reason: 'null: not checked or unknown');
    });

    test('it also warns for prod, where the other guards pass', () {
      final findings = guards(
        req(BuildPlatform.web, BuildEnv.prod),
        freeDiskBytes: gigabyte,
      );
      expect(errors(findings), isEmpty);
      expect(warnings(findings), ['low-disk']);
    });
  });

  group('keystore', () {
    test(
      'prod apk needs a valid keystore: missing file, keys or storeFile are errors',
      () {
        for (final keystore in [_missingFile, _missingKeys, _noStoreFile]) {
          final findings = guards(
            req(BuildPlatform.apk, BuildEnv.prod),
            keystore: keystore,
          );
          expect(errors(findings), ['keystore']);
          expect(findings.single.message, contains(keystore.problem));
        }
      },
    );

    test(
      'prod apk with a valid keystore is accepted without any flag (prod always signs with it)',
      () {
        expect(guards(req(BuildPlatform.apk, BuildEnv.prod)), isEmpty);
      },
    );

    test(
      'non-prod apk without a usable keystore only warns about the debug key',
      () {
        for (final env in [BuildEnv.dev, BuildEnv.preprod, BuildEnv.local]) {
          for (final keystore in [_missingFile, _missingKeys, _noStoreFile]) {
            final findings = guards(
              req(BuildPlatform.apk, env, releaseSigning: true),
              keystore: keystore,
            );
            expect(errors(findings), isEmpty);
            expect(warnings(findings), ['keystore']);
            expect(findings.single.message, contains('DEBUG key'));
          }
        }
      },
    );

    test(
      'a valid keystore that was not opted in is still a debug-key build, with a hint',
      () {
        final findings = guards(req(BuildPlatform.apk, BuildEnv.dev));
        expect(warnings(findings), ['keystore']);
        expect(findings.single.message, contains('--release-signing'));
      },
    );

    test('opting in by flag or by key.properties silences the warning', () {
      expect(
        guards(req(BuildPlatform.apk, BuildEnv.dev, releaseSigning: true)),
        isEmpty,
      );
      expect(
        guards(
          req(BuildPlatform.apk, BuildEnv.dev),
          keystore: _optedInKeystore,
        ),
        isEmpty,
      );
    });

    test('debug and profile apks are always debug-signed and never warn', () {
      for (final mode in [BuildMode.debug, BuildMode.profile]) {
        expect(
          guards(
            req(BuildPlatform.apk, BuildEnv.dev, mode: mode),
            keystore: _missingFile,
          ),
          isEmpty,
        );
      }
    });

    test('web builds do not look at the keystore', () {
      expect(
        guards(req(BuildPlatform.web, BuildEnv.prod), keystore: _missingFile),
        isEmpty,
      );
    });
  });

  test('findings accumulate: a bad prod build reports everything at once', () {
    final findings = guards(
      req(
        BuildPlatform.windows,
        BuildEnv.prod,
        mode: BuildMode.debug,
        baseUrl: 'http://localhost:8011',
      ),
      dirty: true,
      host: HostOs.macos,
    );
    expect(errors(findings).toSet(), {
      'not-https',
      'prod-dev-url',
      'prod-override',
      'prod-mode',
      'dirty-tree',
      'host-windows',
    });
  });
}
