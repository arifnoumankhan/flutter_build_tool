import 'package:test/test.dart';

import 'package:flutter_build_tools/src/model.dart';
import 'package:flutter_build_tools/src/naming.dart';

void main() {
  String name(
    String slug,
    BuildEnv env,
    BuildMode mode,
    BuildPlatform platform, {
    String version = '1.0.47',
  }) => artifactFileName(
    slug: slug,
    env: env,
    version: version,
    mode: mode,
    extension: platform.extension,
  );

  group('the examples from the request', () {
    test('ExampleApp-preprod-v1.0.47.exe', () {
      expect(
        name(
          'ExampleApp',
          BuildEnv.preprod,
          BuildMode.release,
          BuildPlatform.windows,
        ),
        'ExampleApp-preprod-v1.0.47.exe',
      );
    });

    test(
      'ExamplePos-dev-v1.0.47.apk (the typed v1.047 is a typo for the pubspec version)',
      () {
        expect(
          name(
            'ExamplePos',
            BuildEnv.dev,
            BuildMode.release,
            BuildPlatform.apk,
          ),
          'ExamplePos-dev-v1.0.47.apk',
        );
      },
    );

    test('the other platforms follow the same pattern', () {
      expect(
        name(
          'ExampleApp',
          BuildEnv.prod,
          BuildMode.release,
          BuildPlatform.windows,
        ),
        'ExampleApp-prod-v1.0.47.exe',
      );
      expect(
        name(
          'ExamplePos',
          BuildEnv.dev,
          BuildMode.release,
          BuildPlatform.macos,
        ),
        'ExamplePos-dev-v1.0.47.dmg',
      );
      expect(
        name('ExampleApp', BuildEnv.dev, BuildMode.release, BuildPlatform.web),
        'ExampleApp-dev-v1.0.47.zip',
      );
    });
  });

  group('matrix: 4 platforms x 4 envs x 3 modes x 2 apps', () {
    const extensions = {
      BuildPlatform.apk: 'apk',
      BuildPlatform.web: 'zip',
      BuildPlatform.windows: 'exe',
      BuildPlatform.macos: 'dmg',
    };
    const suffixes = {
      BuildMode.release: '',
      BuildMode.debug: '-debug',
      BuildMode.profile: '-profile',
    };
    var checked = 0;

    for (final slug in ['ExampleApp', 'ExamplePos']) {
      for (final platform in BuildPlatform.values) {
        for (final env in BuildEnv.values) {
          for (final mode in BuildMode.values) {
            final expected =
                '$slug-${env.name}-v1.0.47${suffixes[mode]}.${extensions[platform]}';
            test(expected, () {
              expect(name(slug, env, mode, platform), expected);
              checked++;
            });
          }
        }
      }
    }

    tearDownAll(() => expect(checked, 96));
  });

  test('the version is inserted as given', () {
    expect(
      name(
        'ExamplePos',
        BuildEnv.local,
        BuildMode.debug,
        BuildPlatform.apk,
        version: '12.0.3',
      ),
      'ExamplePos-local-v12.0.3-debug.apk',
    );
  });

  test('artifactBaseName has no extension', () {
    expect(
      artifactBaseName(
        slug: 'ExampleApp',
        env: BuildEnv.prod,
        version: '1.0.47',
        mode: BuildMode.profile,
      ),
      'ExampleApp-prod-v1.0.47-profile',
    );
  });

  test('platform aliases and the dist folders', () {
    expect(BuildPlatform.parse('exe'), BuildPlatform.windows);
    expect(BuildPlatform.parse('DMG'), BuildPlatform.macos);
    expect(BuildPlatform.parse('ios'), isNull);
    expect(
      [for (final p in BuildPlatform.values) p.distDir],
      ['android', 'web', 'windows', 'macos'],
    );
  });
}
