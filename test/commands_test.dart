import 'package:test/test.dart';

import 'package:flutter_build_tools/src/commands.dart';
import 'package:flutter_build_tools/src/job.dart';
import 'package:flutter_build_tools/src/keystore.dart';
import 'package:flutter_build_tools/src/model.dart';
import 'package:flutter_build_tools/src/profile.dart';
import 'package:flutter_build_tools/src/runner.dart';
import 'fakes.dart';

Future<BuildJob> jobFor(
  TestWorld world,
  BuildRequest request, {
  KeystoreStatus? keystore,
}) async => BuildJob(
  world.env,
  await resolveProfile(world.env, request),
  keystore: keystore,
);

const validKeystore = KeystoreStatus(
  propertiesFound: true,
  missingKeys: [],
  storeFileExists: true,
  optedInByFile: false,
);

void main() {
  group('flutter build', () {
    test('apk preprod release: exact command', () async {
      final world = TestWorld();
      final job = await jobFor(
        world,
        const BuildRequest(platform: BuildPlatform.apk, env: BuildEnv.preprod),
        keystore: validKeystore,
      );
      final spec = flutterBuildSpec(job);
      expect(spec.executable, 'flutter');
      expect(spec.args, [
        'build',
        'apk',
        '--release',
        '--dart-define-from-file=build/build_tool/defines-apk-preprod.json',
        '--build-name=1.0.47',
        '--build-number=47',
      ]);
      expect(spec.workingDirectory, '/repo');
      expect(spec.shell, isFalse);
    });

    test(
      '--build-name carries the version of the file name (binary == name)',
      () async {
        final world = TestWorld();
        final job = await jobFor(
          world,
          const BuildRequest(
            platform: BuildPlatform.web,
            env: BuildEnv.dev,
            versionOverride: '2.0.0',
            buildNumberOverride: 3,
          ),
        );
        expect(
          flutterBuildSpec(job).args,
          containsAll(['--build-name=2.0.0', '--build-number=3']),
        );
        expect(job.profile.fileName('zip'), 'ExampleApp-dev-v2.0.0.zip');
      },
    );

    test('no +N in the pubspec and no override: no --build-number', () async {
      final world = TestWorld()..seedRepo(version: '1.0.47');
      final job = await jobFor(
        world,
        const BuildRequest(platform: BuildPlatform.web, env: BuildEnv.dev),
      );
      expect(
        flutterBuildSpec(job).args.where((a) => a.startsWith('--build-number')),
        isEmpty,
      );
    });

    for (final platform in BuildPlatform.values) {
      for (final mode in BuildMode.values) {
        test('${platform.name} ${mode.name}: target and mode flag', () async {
          final world = TestWorld();
          final job = await jobFor(
            world,
            BuildRequest(platform: platform, env: BuildEnv.dev, mode: mode),
            keystore: validKeystore,
          );
          final args = flutterBuildSpec(job).args;
          expect(args.take(3), ['build', platform.name, mode.flutterFlag]);
          expect(args.where((a) => a.startsWith('--dart-define')), [
            '--dart-define-from-file=build/build_tool/defines-${platform.name}-dev.json',
          ], reason: 'exactly one define file');
          expect(
            args.any((a) => a.startsWith('--dart-define=')),
            isFalse,
            reason: 'no loose defines',
          );
        });
      }
    }

    test(
      '-P useReleaseSigning=true only with --release-signing on a release apk (and always on prod)',
      () async {
        final world = TestWorld();
        Future<List<String>> args(BuildRequest request) async =>
            flutterBuildSpec(
              await jobFor(world, request, keystore: validKeystore),
            ).args;
        expect(
          await args(
            const BuildRequest(platform: BuildPlatform.apk, env: BuildEnv.dev),
          ),
          isNot(contains('-P')),
        );
        expect(
          await args(
            const BuildRequest(
              platform: BuildPlatform.apk,
              env: BuildEnv.dev,
              releaseSigning: true,
            ),
          ),
          containsAllInOrder(['-P', 'useReleaseSigning=true']),
        );
        expect(
          await args(
            const BuildRequest(platform: BuildPlatform.apk, env: BuildEnv.prod),
          ),
          containsAllInOrder(['-P', 'useReleaseSigning=true']),
        );
        expect(
          await args(
            const BuildRequest(
              platform: BuildPlatform.apk,
              env: BuildEnv.dev,
              mode: BuildMode.debug,
              releaseSigning: true,
            ),
          ),
          isNot(contains('-P')),
        );
        expect(
          await args(
            const BuildRequest(platform: BuildPlatform.web, env: BuildEnv.dev),
          ),
          isNot(contains('-P')),
        );
      },
    );

    test(
      'flutter runs through the shell on Windows (flutter.bat) only',
      () async {
        final windows = TestWorld(host: HostOs.windows);
        final job = await jobFor(
          windows,
          const BuildRequest(
            platform: BuildPlatform.windows,
            env: BuildEnv.dev,
          ),
        );
        expect(flutterBuildSpec(job).shell, isTrue);
        expect(flutterVersionSpec(windows.env).shell, isTrue);
        expect(flutterVersionSpec(TestWorld().env).shell, isFalse);
      },
    );

    test('display quotes arguments with spaces', () {
      expect(
        const ProcessSpec('hdiutil', ['-volname', 'Example App']).display,
        'hdiutil -volname "Example App"',
      );
    });
  });

  group('Inno Setup (ISCC)', () {
    test(
      'release: version, output name and script, nothing about the mode',
      () async {
        final world = TestWorld(host: HostOs.windows);
        final job = await jobFor(
          world,
          const BuildRequest(
            platform: BuildPlatform.windows,
            env: BuildEnv.prod,
          ),
        );
        final spec = isccSpec(
          job,
          isccPath: r'C:\Program Files (x86)\Inno Setup 6\ISCC.exe',
        );
        expect(
          spec.executable,
          r'C:\Program Files (x86)\Inno Setup 6\ISCC.exe',
        );
        expect(spec.args, [
          '/DMyAppVersion=1.0.47',
          '/DMyOutputName=ExampleApp-prod-v1.0.47',
          r'C:\repo\installer\example_app.iss',
        ]);
        expect(
          spec.shell,
          isFalse,
          reason: 'a path with spaces must not go through cmd',
        );
      },
    );

    test('debug and profile pick their Flutter output folder', () async {
      final world = TestWorld(host: HostOs.windows);
      for (final (mode, dir, suffix) in [
        (BuildMode.debug, 'Debug', '-debug'),
        (BuildMode.profile, 'Profile', '-profile'),
      ]) {
        final job = await jobFor(
          world,
          BuildRequest(
            platform: BuildPlatform.windows,
            env: BuildEnv.dev,
            mode: mode,
          ),
        );
        final args = isccSpec(job, isccPath: 'ISCC.exe').args;
        expect(args, contains('/DMyBuildMode=$dir'));
        expect(args, contains('/DMyOutputName=ExampleApp-dev-v1.0.47$suffix'));
      }
    });

    test('candidate folders, in the order of the old scripts', () {
      final world = TestWorld(
        host: HostOs.windows,
        vars: {
          'LOCALAPPDATA': r'C:\Users\a\AppData\Local',
          'ProgramFiles(x86)': r'C:\Program Files (x86)',
          'ProgramFiles': r'C:\Program Files',
        },
      );
      expect(isccCandidates(world.env), [
        r'C:\Users\a\AppData\Local\Programs\Inno Setup 6\ISCC.exe',
        r'C:\Program Files (x86)\Inno Setup 6\ISCC.exe',
        r'C:\Program Files\Inno Setup 6\ISCC.exe',
      ]);
    });

    test('locateIscc: first existing candidate wins', () {
      final world = TestWorld(
        host: HostOs.windows,
        vars: {
          'LOCALAPPDATA': r'C:\L',
          'ProgramFiles(x86)': r'C:\P86',
          'ProgramFiles': r'C:\P',
        },
      );
      world.fs.put(r'C:\P\Inno Setup 6\ISCC.exe', 'x');
      world.fs.put(r'C:\P86\Inno Setup 6\ISCC.exe', 'x');
      expect(locateIscc(world.env), r'C:\P86\Inno Setup 6\ISCC.exe');
    });

    test(
      'locateIscc: falls back to a recursive search of the program folders',
      () {
        final world = TestWorld(
          host: HostOs.windows,
          vars: {
            'LOCALAPPDATA': r'C:\L',
            'ProgramFiles(x86)': r'C:\P86',
            'ProgramFiles': r'C:\P',
          },
        );
        world.fs.put(r'C:\P\Tools\Inno Setup 7\ISCC.exe', 'x');
        expect(locateIscc(world.env), r'C:\P\Tools\Inno Setup 7\ISCC.exe');
      },
    );

    test(
      'locateIscc: null when Inno Setup is not installed, and env var names are case-insensitive',
      () {
        final world = TestWorld(
          host: HostOs.windows,
          vars: {'localappdata': r'C:\L', 'PROGRAMFILES': r'C:\P'},
        );
        expect(locateIscc(world.env), isNull);
        expect(isccCandidates(world.env), [
          r'C:\L\Programs\Inno Setup 6\ISCC.exe',
          r'C:\P\Inno Setup 6\ISCC.exe',
        ]);
      },
    );
  });

  group('MSIX', () {
    test(
      'reuses the Flutter build that had the defines and writes into dist/windows',
      () async {
        final world = TestWorld(host: HostOs.windows);
        final job = await jobFor(
          world,
          const BuildRequest(
            platform: BuildPlatform.windows,
            env: BuildEnv.preprod,
            msix: true,
          ),
        );
        final spec = msixSpec(job);
        expect(spec.executable, 'dart');
        expect(spec.args, [
          'run',
          'msix:create',
          '--build-windows',
          'false',
          '--install-certificate',
          'false',
          '--version',
          '1.0.47.0',
          '--output-path',
          'dist/windows',
          '--output-name',
          'ExampleApp-preprod-v1.0.47',
        ]);
        expect(spec.shell, isTrue);
      },
    );
  });

  group('hdiutil / DMG', () {
    test(
      'stage the app next to an /Applications link, then UDZO with the display name as volume name',
      () async {
        final world = TestWorld();
        final job = await jobFor(
          world,
          const BuildRequest(platform: BuildPlatform.macos, env: BuildEnv.dev),
        );
        final specs = dmgSpecs(
          job,
          stagingDir: '/tmp/stage',
          dmgPath: '/repo/dist/macos/ExampleApp-dev-v1.0.47.dmg',
        );
        expect(specs.map((s) => [s.executable, ...s.args]), [
          [
            'cp',
            '-R',
            '/repo/build/macos/Build/Products/Release/Example App.app',
            '/tmp/stage/',
          ],
          ['ln', '-s', '/Applications', '/tmp/stage/Applications'],
          [
            'hdiutil',
            'create',
            '-volname',
            'Example App',
            '-srcfolder',
            '/tmp/stage',
            '-ov',
            '-format',
            'UDZO',
            '/repo/dist/macos/ExampleApp-dev-v1.0.47.dmg',
          ],
        ]);
      },
    );

    test('debug builds are taken from the Debug folder', () async {
      final world = TestWorld();
      final job = await jobFor(
        world,
        const BuildRequest(
          platform: BuildPlatform.macos,
          env: BuildEnv.dev,
          mode: BuildMode.debug,
        ),
      );
      expect(
        job.builtMacosApp,
        '/repo/build/macos/Build/Products/Debug/Example App.app',
      );
    });
  });

  group('output locations', () {
    test('dist folders and built outputs per platform', () async {
      final world = TestWorld();
      Future<BuildJob> job(
        BuildPlatform platform, {
        BuildMode mode = BuildMode.release,
      }) => jobFor(
        world,
        BuildRequest(platform: platform, env: BuildEnv.dev, mode: mode),
        keystore: validKeystore,
      );
      expect((await job(BuildPlatform.apk)).distDir, '/repo/dist/android');
      expect(
        (await job(BuildPlatform.apk)).builtApk,
        '/repo/build/app/outputs/flutter-apk/app-release.apk',
      );
      expect(
        (await job(BuildPlatform.apk, mode: BuildMode.profile)).builtApk,
        '/repo/build/app/outputs/flutter-apk/app-profile.apk',
      );
      expect((await job(BuildPlatform.web)).builtWebDir, '/repo/build/web');
      expect(
        (await job(
          BuildPlatform.windows,
          mode: BuildMode.debug,
        )).builtWindowsDir,
        '/repo/build/windows/x64/runner/Debug',
      );
      expect(
        (await job(BuildPlatform.web)).stampPath,
        '/repo/build/build_tool/stamp-web-release.json',
      );
    });
  });

  group('parseFlutterVersion', () {
    test('framework version and channel from --machine output', () {
      expect(
        parseFlutterVersion('{"frameworkVersion":"3.47.0","channel":"stable"}'),
        '3.47.0 (stable)',
      );
    });

    test('tolerates noise around the JSON', () {
      expect(
        parseFlutterVersion(
          'Building flutter tool...\n{"frameworkVersion":"3.47.0"}\n',
        ),
        '3.47.0',
      );
    });

    test('garbage gives null', () {
      expect(parseFlutterVersion('Flutter 3.47.0'), isNull);
      expect(parseFlutterVersion('{broken'), isNull);
      expect(parseFlutterVersion('{"channel":"stable"}'), isNull);
      expect(parseFlutterVersion('[1]'), isNull);
    });
  });
}
