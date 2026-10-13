import 'package:test/test.dart';

import 'package:flutter_build_tools/src/commands.dart';
import 'package:flutter_build_tools/src/config.dart';
import 'package:flutter_build_tools/src/environment.dart';
import 'package:flutter_build_tools/src/job.dart';
import 'package:flutter_build_tools/src/model.dart';
import 'package:flutter_build_tools/src/profile.dart';
import 'fakes.dart';

Matcher failsWith(String text) => throwsA(
  isA<BuildException>().having((e) => e.message, 'message', contains(text)),
);

Future<BuildProfile> resolve(TestWorld world, BuildRequest request) =>
    resolveProfile(world.env, request);

void main() {
  group('mergeDefines precedence: env file < --base-url < generated values', () {
    const file = {
      'APP_ENV': 'preprod',
      'BASE_URL': 'https://file.example.com',
      'POS_WEB_URL': 'https://pos.example.com',
    };

    test('without an override the file value wins over nothing', () {
      final merged = mergeDefines(
        fileValues: file,
        env: BuildEnv.preprod,
        baseUrlOverride: null,
        buildSha: 'abc1234',
      );
      expect(merged['BASE_URL'], 'https://file.example.com');
      expect(merged['POS_WEB_URL'], 'https://pos.example.com');
    });

    test('--base-url beats the file', () {
      final merged = mergeDefines(
        fileValues: file,
        env: BuildEnv.preprod,
        baseUrlOverride: 'https://override.example.com',
        buildSha: 'abc1234',
      );
      expect(merged['BASE_URL'], 'https://override.example.com');
      expect(
        merged['POS_WEB_URL'],
        'https://pos.example.com',
        reason: 'only BASE_URL is overridden',
      );
    });

    test(
      'generated values beat everything and APP_ENV is the requested env',
      () {
        final merged = mergeDefines(
          fileValues: {...file, 'APP_ENV': 'dev', 'BUILD_SHA': 'stale'},
          env: BuildEnv.preprod,
          baseUrlOverride: null,
          buildSha: 'abc1234-dirty',
        );
        expect(merged['APP_ENV'], 'preprod');
        expect(merged['BUILD_SHA'], 'abc1234-dirty');
      },
    );

    test(
      'keys are sorted, so the define file is deterministic, and only the known keys appear',
      () {
        final merged = mergeDefines(
          fileValues: file,
          env: BuildEnv.preprod,
          baseUrlOverride: null,
          buildSha: 'abc1234',
        );
        expect(merged.keys.toList(), [
          'APP_ENV',
          'BASE_URL',
          'BUILD_SHA',
          'POS_WEB_URL',
        ]);
      },
    );

    test('an app without POS_WEB_URL (POS) gets no such define', () {
      final merged = mergeDefines(
        fileValues: {'APP_ENV': 'dev', 'BASE_URL': 'https://x.example.com'},
        env: BuildEnv.dev,
        baseUrlOverride: null,
        buildSha: 'a',
      );
      expect(merged.keys, ['APP_ENV', 'BASE_URL', 'BUILD_SHA']);
    });
  });

  group('the defines never change between two runs of the same commit', () {
    // Flutter hashes every define into .dart_tool/flutter_build/<md5>, a cache
    // folder it never prunes (100-230 MB each). A per-run value such as the
    // build time made every build a new folder and filled a disk.
    test('no define carries the build time, which is kept apart', () async {
      final world = TestWorld();
      final profile = await resolve(
        world,
        const BuildRequest(platform: BuildPlatform.apk, env: BuildEnv.preprod),
      );
      expect(profile.defines.containsKey('BUILD_TIME'), isFalse);
      expect(profile.defines.values, isNot(contains(fixedNow)));
      expect(
        profile.buildTime,
        fixedNow,
        reason: 'still known to the manifest',
      );
    });

    test('two runs at different times produce identical defines', () async {
      const request = BuildRequest(
        platform: BuildPlatform.apk,
        env: BuildEnv.preprod,
      );
      final first = TestWorld();
      final second = TestWorld();
      final later = BuildEnvironment(
        root: '/repo',
        host: HostOs.macos,
        vars: const {},
        fs: second.fs,
        runner: second.runner,
        console: second.console,
        now: () => DateTime.utc(2027, 1, 2, 3, 4, 5),
      );
      final a = await resolve(first, request);
      final b = await resolveProfile(later, request);
      expect(a.buildTime, isNot(b.buildTime));
      expect(a.defines, b.defines);
      expect(
        flutterBuildSpec(BuildJob(first.env, a)).args,
        flutterBuildSpec(BuildJob(later, b)).args,
        reason: 'the flutter command line is identical too',
      );
    });
  });

  group('resolveProfile', () {
    test('reads version, env file, git and time', () async {
      final world = TestWorld();
      final profile = await resolve(
        world,
        const BuildRequest(platform: BuildPlatform.apk, env: BuildEnv.preprod),
      );
      expect(profile.version, '1.0.47');
      expect(profile.buildNumber, 47);
      expect(profile.baseUrl, 'https://preprod.example.com/public');
      expect(profile.posWebUrl, 'https://preprod.example.com/public/web_pos');
      expect(profile.defines['BUILD_SHA'], 'abc1234');
      expect(profile.buildTime, fixedNow);
      expect(profile.baseName, 'ExampleApp-preprod-v1.0.47');
      expect(profile.fileName('apk'), 'ExampleApp-preprod-v1.0.47.apk');
      expect(
        profile.defineFilePath,
        'build/build_tool/defines-apk-preprod.json',
      );
    });

    test('a dirty tree marks BUILD_SHA', () async {
      final world = TestWorld(dirty: true);
      final profile = await resolve(
        world,
        const BuildRequest(platform: BuildPlatform.web, env: BuildEnv.dev),
      );
      expect(profile.defines['BUILD_SHA'], 'abc1234-dirty');
      expect(profile.git.dirty, isTrue);
    });

    test('--version and --build-number override the pubspec', () async {
      final world = TestWorld();
      final profile = await resolve(
        world,
        const BuildRequest(
          platform: BuildPlatform.apk,
          env: BuildEnv.dev,
          versionOverride: '2.3.4',
          buildNumberOverride: 9,
        ),
      );
      expect(profile.version, '2.3.4');
      expect(profile.buildNumber, 9);
      expect(profile.fileName('apk'), 'ExampleApp-dev-v2.3.4.apk');
    });

    test('a pubspec without +N has no build number', () async {
      final world = TestWorld()..seedRepo(version: '3.1.0');
      final profile = await resolve(
        world,
        const BuildRequest(platform: BuildPlatform.apk, env: BuildEnv.dev),
      );
      expect(profile.buildNumber, isNull);
    });

    test('--base-url overrides BASE_URL but not POS_WEB_URL', () async {
      final world = TestWorld();
      final profile = await resolve(
        world,
        const BuildRequest(
          platform: BuildPlatform.apk,
          env: BuildEnv.local,
          baseUrlOverride: 'http://192.168.1.20:8011',
        ),
      );
      expect(profile.baseUrl, 'http://192.168.1.20:8011');
      expect(profile.defines['BASE_URL'], 'http://192.168.1.20:8011');
      expect(profile.posWebUrl, 'http://127.0.0.1:8011/web_pos');
    });

    test('a malformed --base-url is refused', () async {
      final world = TestWorld();
      await expectLater(
        resolve(
          world,
          const BuildRequest(
            platform: BuildPlatform.apk,
            env: BuildEnv.dev,
            baseUrlOverride: 'devserver',
          ),
        ),
        failsWith('--base-url "devserver" is not an absolute URL'),
      );
      await expectLater(
        resolve(
          world,
          const BuildRequest(
            platform: BuildPlatform.apk,
            env: BuildEnv.dev,
            baseUrlOverride: 'https://x.example.com/',
          ),
        ),
        failsWith('trailing slash'),
      );
    });

    test('--env-file: relative to the repo root, or absolute', () async {
      final world = TestWorld();
      world.fs.put(
        world.abs('ci/custom.json'),
        '{"APP_ENV": "dev", "BASE_URL": "https://ci.example.com"}',
      );
      final relative = await resolve(
        world,
        const BuildRequest(
          platform: BuildPlatform.apk,
          env: BuildEnv.dev,
          envFilePath: 'ci/custom.json',
        ),
      );
      expect(relative.baseUrl, 'https://ci.example.com');
      expect(relative.envFile.path, 'ci/custom.json');
      final absolute = await resolve(
        world,
        BuildRequest(
          platform: BuildPlatform.apk,
          env: BuildEnv.dev,
          envFilePath: world.abs('ci/custom.json'),
        ),
      );
      expect(absolute.baseUrl, 'https://ci.example.com');
    });

    test('a missing env file says how to create it', () async {
      final world = TestWorld();
      world.fs.deleteFile(world.abs('config/env/dev.json'));
      await expectLater(
        resolve(
          world,
          const BuildRequest(platform: BuildPlatform.apk, env: BuildEnv.dev),
        ),
        failsWith('Env file config/env/dev.json not found. Create it'),
      );
    });

    test('a missing custom env file points at --env-file', () async {
      final world = TestWorld();
      await expectLater(
        resolve(
          world,
          const BuildRequest(
            platform: BuildPlatform.apk,
            env: BuildEnv.dev,
            envFilePath: 'nope.json',
          ),
        ),
        failsWith('Env file nope.json not found. Check the --env-file path'),
      );
    });

    test('a broken env file is reported with its name', () async {
      final world = TestWorld();
      world.fs.put(world.abs('config/env/dev.json'), '{"APP_ENV": "dev"}');
      await expectLater(
        resolve(
          world,
          const BuildRequest(platform: BuildPlatform.apk, env: BuildEnv.dev),
        ),
        failsWith('config/env/dev.json is missing required key "BASE_URL"'),
      );
    });

    test('a missing pubspec or build config is reported', () async {
      final noPubspec = TestWorld()..fs.deleteFile('/repo/pubspec.yaml');
      await expectLater(
        resolve(
          noPubspec,
          const BuildRequest(platform: BuildPlatform.apk, env: BuildEnv.dev),
        ),
        failsWith('pubspec.yaml not found'),
      );
      // Without build_config.json the facts are inferred (see inference_test);
      // that needs the pubspec name, and the error says how to get out.
      final noConfigNoName = TestWorld()
        ..fs.deleteFile('/repo/tool/build/build_config.json')
        ..fs.put('/repo/pubspec.yaml', 'version: 1.0.0+1\n');
      await expectLater(
        resolve(
          noConfigNoName,
          const BuildRequest(platform: BuildPlatform.apk, env: BuildEnv.dev),
        ),
        failsWith('has no top-level "name:" to infer the project facts from'),
      );
    });
  });

  group('AppConfig.parse', () {
    const good =
        '{"app":"pos","slug":"ExamplePos","displayName":"Example POS","envDir":"config/env","windows":{"exe":"example_app.exe","installerScript":"installer/example_app.iss"},"macos":{"appName":"Example POS"}}';

    test('reads every fact', () {
      final config = AppConfig.parse(good);
      expect(config.app, 'pos');
      expect(config.slug, 'ExamplePos');
      expect(config.displayName, 'Example POS');
      expect(config.envDir, 'config/env');
      expect(config.windowsExe, 'example_app.exe');
      expect(config.installerScript, 'installer/example_app.iss');
      expect(config.macosAppName, 'Example POS');
    });

    test('rejects broken files with a pointed message', () {
      expect(() => AppConfig.parse('{nope'), failsWith('is not valid JSON'));
      expect(
        () => AppConfig.parse('[]'),
        failsWith('must contain a JSON object'),
      );
      expect(
        () => AppConfig.parse(good.replaceAll('"slug":"ExamplePos",', '')),
        failsWith('"slug" must be a non-empty string'),
      );
      expect(
        () => AppConfig.parse(good.replaceAll('ExamplePos', 'Example Pos')),
        failsWith('letters and digits only'),
      );
      expect(
        () => AppConfig.parse(
          good.replaceAll('"macos":{"appName":"Example POS"}', '"macos":1'),
        ),
        failsWith('"macos" must be an object'),
      );
      expect(
        () => AppConfig.parse(
          good.replaceAll('"exe":"example_app.exe"', '"exe":""'),
        ),
        failsWith('"windows.exe" must be a non-empty string'),
      );
    });
  });

  test('formatBuildTime is UTC ISO-8601 without fractions', () {
    expect(
      formatBuildTime(DateTime.utc(2026, 10, 6, 12, 34, 56, 789)),
      fixedNow,
    );
    expect(
      formatBuildTime(DateTime.parse('2026-10-06T14:34:56+02:00')),
      fixedNow,
    );
  });
}
