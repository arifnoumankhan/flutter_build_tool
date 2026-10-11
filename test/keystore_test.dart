import 'package:test/test.dart';

import 'package:flutter_build_tools/src/keystore.dart';
import 'package:flutter_build_tools/src/model.dart';
import 'fakes.dart';

KeystoreStatus inspect(TestWorld world) =>
    inspectKeystore(fs: world.fs, path: world.env.path, root: world.env.root);

void main() {
  group('parseProperties', () {
    test('key=value and key: value, last occurrence wins, comments ignored', () {
      final properties = parseProperties(
        '# comment\n! other\nkeyAlias = first\nkeyAlias: second\n  storeFile=../x.jks\n',
      );
      expect(properties['keyAlias'], 'second');
      expect(properties['storeFile'], '../x.jks');
      expect(properties.length, 2);
    });

    test('CRLF line endings are handled', () {
      expect(parseProperties('keyAlias=release\r\nstoreFile=a.jks\r\n'), {
        'keyAlias': 'release',
        'storeFile': 'a.jks',
      });
    });

    test('Java escapes: doubled backslashes (Windows paths), unicode, tab', () {
      expect(
        parseProperties(r'storeFile=C:\\keys\\release.jks')['storeFile'],
        r'C:\keys\release.jks',
      );
      expect(parseProperties(r'a=\u0041\tB')['a'], 'A\tB');
    });

    test('a key without a value is empty', () {
      expect(parseProperties('keyAlias=\n')['keyAlias'], '');
    });
  });

  group('inspectKeystore (mirrors android/app/build.gradle)', () {
    test('no key.properties', () {
      final status = inspect(TestWorld());
      expect(status.valid, isFalse);
      expect(status.propertiesFound, isFalse);
      expect(status.problem, 'android/key.properties does not exist');
    });

    test(
      'valid: all four keys and an existing storeFile relative to android/app',
      () {
        final world = TestWorld()..seedKeystore();
        final status = inspect(world);
        expect(status.valid, isTrue);
        expect(status.optedInByFile, isFalse);
        expect(status.problem, 'ok');
      },
    );

    test(
      'useReleaseSigning=true in the file is an opt-in (case and spaces ignored)',
      () {
        final world = TestWorld()..seedKeystore();
        world.fs.put(
          world.abs('android/key.properties'),
          'storePassword=a\nkeyPassword=b\nkeyAlias=c\nstoreFile=../release.jks\nuseReleaseSigning= TRUE \n',
        );
        expect(inspect(world).optedInByFile, isTrue);
      },
    );

    test('each missing or empty key invalidates it', () {
      for (final key in keystoreKeys) {
        final world = TestWorld()..seedKeystore();
        final lines = {
          'storePassword': 'a',
          'keyPassword': 'b',
          'keyAlias': 'c',
          'storeFile': '../release.jks',
        }..[key] = '';
        world.fs.put(
          world.abs('android/key.properties'),
          lines.entries.map((e) => '${e.key}=${e.value}').join('\n'),
        );
        final status = inspect(world);
        expect(status.valid, isFalse, reason: key);
        expect(status.missingKeys, [key]);
        expect(status.problem, contains(key));
      }
    });

    test('a storeFile that does not exist invalidates it', () {
      final world = TestWorld()..seedKeystore();
      world.fs.deleteFile(world.abs('android/release.jks'));
      final status = inspect(world);
      expect(status.valid, isFalse);
      expect(status.storeFileExists, isFalse);
      expect(status.problem, contains('storeFile'));
    });

    test('an absolute storeFile is used as is', () {
      final world = TestWorld();
      world.fs.put(
        world.abs('android/key.properties'),
        'storePassword=a\nkeyPassword=b\nkeyAlias=c\nstoreFile=/keys/release.jks\n',
      );
      expect(inspect(world).valid, isFalse);
      world.fs.put('/keys/release.jks', 'jks');
      expect(inspect(world).valid, isTrue);
    });

    test('on a Windows host, drive paths are absolute', () {
      final world = TestWorld(host: HostOs.windows);
      world.fs.put(
        world.abs('android/key.properties'),
        r'storePassword=a'
        '\nkeyPassword=b\nkeyAlias=c\n'
        r'storeFile=D:\\keys\\release.jks'
        '\n',
      );
      world.fs.put(r'D:\keys\release.jks', 'jks');
      expect(inspect(world).valid, isTrue);
    });

    test('the explanation never contains the secret values', () {
      final world = TestWorld()..seedKeystore();
      world.fs.deleteFile(world.abs('android/release.jks'));
      final text = inspect(world).problem;
      expect(text, isNot(contains('secret-store')));
      expect(text, isNot(contains('secret-key')));
      expect(text, isNot(contains('release.jks')));
    });
  });

  group('planApkSigning', () {
    const valid = KeystoreStatus(
      propertiesFound: true,
      missingKeys: [],
      storeFileExists: true,
      optedInByFile: false,
    );
    const validOptedIn = KeystoreStatus(
      propertiesFound: true,
      missingKeys: [],
      storeFileExists: true,
      optedInByFile: true,
    );
    const invalid = KeystoreStatus(
      propertiesFound: false,
      missingKeys: keystoreKeys,
      storeFileExists: false,
      optedInByFile: false,
    );

    ApkSigning plan(
      BuildEnv env,
      KeystoreStatus keystore, {
      BuildMode mode = BuildMode.release,
      bool flag = false,
    }) => planApkSigning(
      BuildRequest(
        platform: BuildPlatform.apk,
        env: env,
        mode: mode,
        releaseSigning: flag,
      ),
      keystore,
    );

    test('release, not opted in: debug key, no gradle flag', () {
      final signing = plan(BuildEnv.dev, valid);
      expect(signing.releaseKeystore, isFalse);
      expect(signing.passGradleFlag, isFalse);
      expect(signing.kind, 'debug-key');
    });

    test(
      '--release-signing with a valid keystore: release key and -P useReleaseSigning',
      () {
        final signing = plan(BuildEnv.dev, valid, flag: true);
        expect(signing.releaseKeystore, isTrue);
        expect(signing.passGradleFlag, isTrue);
        expect(signing.kind, 'release-keystore');
      },
    );

    test(
      'opt-in through key.properties: release key (gradle reads the file itself, no flag passed)',
      () {
        final signing = plan(BuildEnv.dev, validOptedIn);
        expect(signing.releaseKeystore, isTrue);
        expect(signing.passGradleFlag, isFalse);
      },
    );

    test(
      '--release-signing with an invalid keystore falls back to the debug key',
      () {
        final signing = plan(BuildEnv.dev, invalid, flag: true);
        expect(signing.releaseKeystore, isFalse);
        expect(signing.passGradleFlag, isTrue);
      },
    );

    test('prod always requests release signing, with or without the flag', () {
      for (final flag in [false, true]) {
        final signing = plan(BuildEnv.prod, valid, flag: flag);
        expect(signing.passGradleFlag, isTrue);
        expect(signing.releaseKeystore, isTrue);
      }
      expect(plan(BuildEnv.prod, invalid).releaseKeystore, isFalse);
    });

    test('debug and profile builds are always debug-signed', () {
      for (final mode in [BuildMode.debug, BuildMode.profile]) {
        final signing = plan(
          BuildEnv.prod,
          validOptedIn,
          mode: mode,
          flag: true,
        );
        expect(signing.releaseKeystore, isFalse);
        expect(signing.passGradleFlag, isFalse);
      }
    });
  });
}
