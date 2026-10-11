import 'package:test/test.dart';

import 'package:flutter_build_tools/src/model.dart';
import 'package:flutter_build_tools/src/picker.dart';
import 'fakes.dart';

void main() {
  group('parseChoice', () {
    const options = ['apk', 'web', 'windows'];

    test('number, name, case, whitespace', () {
      expect(parseChoice('2', options), 'web');
      expect(parseChoice(' WEB ', options), 'web');
      expect(parseChoice('windows', options), 'windows');
      expect(parseChoice('1', options), 'apk');
    });

    test('empty input gives the default (or null without one)', () {
      expect(parseChoice('', options, defaultValue: 'apk'), 'apk');
      expect(parseChoice('  ', options, defaultValue: 'web'), 'web');
      expect(parseChoice('', options), isNull);
    });

    test('aliases', () {
      expect(
        parseChoice('exe', options, aliases: const {'exe': 'windows'}),
        'windows',
      );
      expect(parseChoice('exe', options), isNull);
    });

    test('out of range and unknown', () {
      expect(parseChoice('0', options), isNull);
      expect(parseChoice('4', options), isNull);
      expect(parseChoice('-1', options), isNull);
      expect(parseChoice('ios', options), isNull);
    });
  });

  group('parseYesNo', () {
    test('answers and defaults', () {
      expect(parseYesNo('y', defaultValue: false), isTrue);
      expect(parseYesNo('Yes', defaultValue: false), isTrue);
      expect(parseYesNo('n', defaultValue: true), isFalse);
      expect(parseYesNo('NO', defaultValue: true), isFalse);
      expect(parseYesNo('', defaultValue: true), isTrue);
      expect(parseYesNo('', defaultValue: false), isFalse);
      expect(parseYesNo('maybe', defaultValue: true), isNull);
    });
  });

  group('pickRequest', () {
    test('all defaults: apk dev release, confirmed', () {
      final world = TestWorld(interactive: true, inputs: ['', '', '', '']);
      final request = pickRequest(world.env)!;
      expect(request.platform, BuildPlatform.apk);
      expect(request.env, BuildEnv.dev);
      expect(request.mode, BuildMode.release);
    });

    test(
      'numbers and names, and the equivalent command is shown before confirming',
      () {
        final world = TestWorld(
          interactive: true,
          inputs: ['web', '2', 'debug', 'y'],
        );
        final request = pickRequest(world.env)!;
        expect(request.platform, BuildPlatform.web);
        expect(request.env, BuildEnv.preprod);
        expect(request.mode, BuildMode.debug);
        expect(
          world.console.stdoutText,
          contains('Build: dart run flutter_build_tools web preprod --debug'),
        );
      },
    );

    test('an invalid answer re-asks', () {
      final world = TestWorld(
        interactive: true,
        inputs: ['ios', '7', '1', '', '', ''],
      );
      expect(pickRequest(world.env)!.platform, BuildPlatform.apk);
      expect(world.console.stdoutText, contains('Not a valid choice: "ios"'));
      expect(world.console.stdoutText, contains('Not a valid choice: "7"'));
    });

    test('three invalid answers abort with a pointer to the arguments', () {
      final world = TestWorld(interactive: true, inputs: ['x', 'y', 'z']);
      expect(
        () => pickRequest(world.env),
        throwsA(
          isA<BuildException>().having(
            (e) => e.message,
            'message',
            contains('Pass the arguments instead'),
          ),
        ),
      );
    });

    test('end of input aborts', () {
      final world = TestWorld(interactive: true, inputs: ['apk']);
      expect(
        () => pickRequest(world.env),
        throwsA(
          isA<BuildException>().having(
            (e) => e.message,
            'message',
            contains('no input'),
          ),
        ),
      );
    });

    test('declining the confirmation returns null; prod defaults to no', () {
      final no = TestWorld(interactive: true, inputs: ['', '', '', 'n']);
      expect(pickRequest(no.env), isNull);
      final prod = TestWorld(interactive: true, inputs: ['', 'prod', '', '']);
      expect(
        pickRequest(prod.env),
        isNull,
        reason: 'empty confirm on prod means no',
      );
      final prodYes = TestWorld(
        interactive: true,
        inputs: ['', 'prod', '', 'y'],
      );
      expect(pickRequest(prodYes.env)!.env, BuildEnv.prod);
    });

    test('only the platforms buildable on the host are offered', () {
      final mac = TestWorld(interactive: true, inputs: ['', '', '', '']);
      pickRequest(mac.env);
      expect(mac.console.stdoutText, contains('3) macos'));
      expect(mac.console.stdoutText, isNot(contains('windows')));
      final windows = TestWorld(
        host: HostOs.windows,
        interactive: true,
        inputs: ['exe', '', '', ''],
      );
      expect(pickRequest(windows.env)!.platform, BuildPlatform.windows);
      expect(windows.console.stdoutText, isNot(contains('macos')));
    });
  });

  test('equivalentCommand omits the release default', () {
    expect(
      equivalentCommand(
        const BuildRequest(platform: BuildPlatform.apk, env: BuildEnv.prod),
      ),
      'dart run flutter_build_tools apk prod',
    );
    expect(
      equivalentCommand(
        const BuildRequest(
          platform: BuildPlatform.apk,
          env: BuildEnv.prod,
          mode: BuildMode.profile,
        ),
      ),
      'dart run flutter_build_tools apk prod --profile',
    );
  });

  test('the equivalent command uses the invocation it is given', () {
    expect(
      equivalentCommand(
        const BuildRequest(
          platform: BuildPlatform.web,
          env: BuildEnv.dev,
          mode: BuildMode.debug,
        ),
        invocation: 'dart run tool/build/build.dart',
      ),
      'dart run tool/build/build.dart web dev --debug',
    );
  });
}
