import 'dart:convert';

import 'package:test/test.dart';

import 'package:flutter_build_tools/src/git.dart';
import 'package:flutter_build_tools/src/job.dart';
import 'package:flutter_build_tools/src/keystore.dart';
import 'package:flutter_build_tools/src/manifest.dart';
import 'package:flutter_build_tools/src/model.dart';
import 'package:flutter_build_tools/src/profile.dart';
import 'fakes.dart';

const keystore = KeystoreStatus(
  propertiesFound: true,
  missingKeys: [],
  storeFileExists: true,
  optedInByFile: false,
);

Future<Map<String, Object?>> manifestFor(
  TestWorld world,
  BuildRequest request,
) async {
  final job = BuildJob(
    world.env,
    await resolveProfile(world.env, request),
    keystore: request.platform == BuildPlatform.apk ? keystore : null,
  );
  final text = manifestJson(
    job: job,
    fileName: job.profile.fileName(request.platform.extension),
    sizeBytes: 1234,
    sha256: 'f' * 64,
    flutterVersion: '3.47.0 (stable)',
    git: const GitInfo(sha: 'abc1234', dirty: false),
    builtAt: fixedNow,
  );
  expect(text.endsWith('}\n'), isTrue, reason: 'trailing newline');
  return jsonDecode(text) as Map<String, Object?>;
}

void main() {
  test('sha256Line is the sha256sum format: hash, two spaces, file name', () {
    expect(
      sha256Line('ab' * 32, 'ExampleApp-dev-v1.0.47.apk'),
      '${'ab' * 32}  ExampleApp-dev-v1.0.47.apk\n',
    );
  });

  test('manifest of an apk build', () async {
    final manifest = await manifestFor(
      TestWorld(),
      const BuildRequest(
        platform: BuildPlatform.apk,
        env: BuildEnv.preprod,
        releaseSigning: true,
      ),
    );
    expect(manifest, {
      'schema': 1,
      'app': 'admin',
      'env': 'preprod',
      'platform': 'apk',
      'mode': 'release',
      'version': '1.0.47',
      'buildNumber': 47,
      'baseUrl': 'https://preprod.example.com/public',
      'posWebUrl': 'https://preprod.example.com/public/web_pos',
      'git': {'sha': 'abc1234', 'dirty': false},
      'flutter': '3.47.0 (stable)',
      'builtAt': fixedNow,
      'hostOs': 'macos',
      'file': 'ExampleApp-preprod-v1.0.47.apk',
      'sizeBytes': 1234,
      'sha256': 'f' * 64,
      'signing': 'release-keystore',
    });
  });

  test(
    'an apk without opt-in says debug-key; other platforms have no signing entry',
    () async {
      final apk = await manifestFor(
        TestWorld(),
        const BuildRequest(platform: BuildPlatform.apk, env: BuildEnv.dev),
      );
      expect(apk['signing'], 'debug-key');
      final web = await manifestFor(
        TestWorld(),
        const BuildRequest(platform: BuildPlatform.web, env: BuildEnv.dev),
      );
      expect(web.containsKey('signing'), isFalse);
      expect(web['file'], 'ExampleApp-dev-v1.0.47.zip');
      expect(web['platform'], 'web');
    },
  );

  test('the mode, the override and the host are recorded', () async {
    final manifest = await manifestFor(
      TestWorld(host: HostOs.windows),
      const BuildRequest(
        platform: BuildPlatform.windows,
        env: BuildEnv.local,
        mode: BuildMode.debug,
        baseUrlOverride: 'http://192.168.1.2:8011',
        versionOverride: '9.9.9',
      ),
    );
    expect(manifest['mode'], 'debug');
    expect(manifest['baseUrl'], 'http://192.168.1.2:8011');
    expect(manifest['version'], '9.9.9');
    expect(manifest['hostOs'], 'windows');
    expect(manifest['file'], 'ExampleApp-local-v9.9.9-debug.exe');
  });

  test('an app without POS_WEB_URL (POS) has no posWebUrl entry', () async {
    final world = TestWorld();
    world.writeEnvFile('dev', {
      'APP_ENV': 'dev',
      'BASE_URL': 'https://devexample.example.com/public',
    });
    final manifest = await manifestFor(
      world,
      const BuildRequest(platform: BuildPlatform.web, env: BuildEnv.dev),
    );
    expect(manifest.containsKey('posWebUrl'), isFalse);
  });

  test('git unknown is recorded as null, not as false', () async {
    final world = TestWorld();
    final job = BuildJob(
      world.env,
      await resolveProfile(
        world.env,
        const BuildRequest(platform: BuildPlatform.web, env: BuildEnv.dev),
      ),
    );
    final text = manifestJson(
      job: job,
      fileName: 'x.zip',
      sizeBytes: 1,
      sha256: 'a' * 64,
      flutterVersion: 'unknown',
      git: const GitInfo.unavailable(),
      builtAt: fixedNow,
    );
    expect((jsonDecode(text) as Map)['git'], {'sha': 'unknown', 'dirty': null});
  });
}
