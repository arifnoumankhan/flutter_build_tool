import 'package:test/test.dart';

import 'package:flutter_build_tools/src/config.dart';
import 'package:flutter_build_tools/src/model.dart';

void main() {
  group('PubspecVersion.parse', () {
    test('x.y.z+N gives the name and the build number', () {
      final version = PubspecVersion.parse(
        'name: example_app\nversion: 1.0.47+47\n',
      );
      expect(version.name, '1.0.47');
      expect(version.buildNumber, 47);
    });

    test('x.y.z without +N has no build number', () {
      final version = PubspecVersion.parse('version: 2.10.3\n');
      expect(version.name, '2.10.3');
      expect(version.buildNumber, isNull);
    });

    test('tolerates quotes, extra spaces, a trailing comment and CRLF', () {
      expect(
        PubspecVersion.parse(
          'version:   "1.2.3+4"   # bump\r\nname: x\r\n',
        ).name,
        '1.2.3',
      );
      expect(PubspecVersion.parse("version: '1.2.3'\n").name, '1.2.3');
    });

    test('ignores indented version keys of dependencies and comments', () {
      const pubspec =
          '# version: 9.9.9\ndependencies:\n  version: ^1.0.0\nversion: 1.0.47+47\n';
      expect(PubspecVersion.parse(pubspec).name, '1.0.47');
    });

    test('a missing version line explains the fix', () {
      expect(
        () => PubspecVersion.parse('name: example_app\n'),
        throwsA(
          isA<BuildException>().having(
            (e) => e.message,
            'message',
            allOf(contains('no top-level "version:"'), contains('--version')),
          ),
        ),
      );
    });

    for (final bad in [
      '1.0',
      '1',
      '1.0.47-beta.1+3',
      'v1.0.47',
      '1.0.47+abc',
      'latest',
    ]) {
      test('rejects "$bad"', () {
        expect(
          () => PubspecVersion.parse('version: $bad\n'),
          throwsA(
            isA<BuildException>().having(
              (e) => e.message,
              'message',
              contains('is not x.y.z'),
            ),
          ),
        );
      });
    }
  });

  test('versionPattern accepts only x.y.z', () {
    expect(versionPattern.hasMatch('1.0.47'), isTrue);
    expect(versionPattern.hasMatch('v1.0.47'), isFalse);
    expect(versionPattern.hasMatch('1.0'), isFalse);
    expect(versionPattern.hasMatch('1.0.47+47'), isFalse);
  });
}
