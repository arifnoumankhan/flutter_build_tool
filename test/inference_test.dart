// What the tool reads from the project itself when build_config.json does not
// say: pure functions and one reader over an in-memory file system.
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'package:flutter_build_tools/src/inference.dart';
import 'fakes.dart';

void main() {
  group('slugFromPubspecName', () {
    for (final (name, slug) in <(String, String)>[
      ('my_cool_app', 'MyCoolApp'),
      ('acme_shop_app', 'AcmeShopApp'),
      ('acme', 'Acme'),
      ('app2go', 'App2go'),
      ('my_app_2', 'MyApp2'),
      ('a', 'A'),
      ('__private_app__', 'PrivateApp'),
      ('my-odd.name', 'MyOddName'),
      ('2fa_app', '2faApp'),
    ]) {
      test('$name gives $slug', () => expect(slugFromPubspecName(name), slug));
    }

    test('only letters and digits are left, so it is a valid slug', () {
      for (final name in ['x_y', 'a-b', 'a.b.c', '__', 'é_ü', '_']) {
        expect(
          RegExp(r'^[A-Za-z0-9]+$').hasMatch(slugFromPubspecName(name)),
          isTrue,
          reason: name,
        );
      }
    });

    test('a name with no letter or digit falls back to App', () {
      expect(slugFromPubspecName('___'), 'App');
      expect(slugFromPubspecName(''), 'App');
    });
  });

  group('displayNameFromPubspecName', () {
    test('words are capitalised and separated by spaces', () {
      expect(displayNameFromPubspecName('my_cool_app'), 'My Cool App');
      expect(displayNameFromPubspecName('acme_shop_app'), 'Acme Shop App');
      expect(displayNameFromPubspecName('acme'), 'Acme');
      expect(displayNameFromPubspecName('__a__b__'), 'A B');
    });

    test('an empty name falls back to App', () {
      expect(displayNameFromPubspecName('_'), 'App');
    });
  });

  group('pubspecNameOf', () {
    test('reads the top-level name', () {
      expect(
        pubspecNameOf('name: example_app\nversion: 1.0.0\n'),
        'example_app',
      );
    });

    test('tolerates quotes, spaces, a comment and CRLF', () {
      expect(pubspecNameOf('name:   "demo_app"   # the app\r\n'), 'demo_app');
      expect(pubspecNameOf("name: 'demo_app'\n"), 'demo_app');
    });

    test('ignores indented name keys and comments', () {
      const text =
          '# name: wrong\ndependencies:\n  name: ^1.0.0\nname: right_app\n';
      expect(pubspecNameOf(text), 'right_app');
    });

    test('is null without a name or with an empty one', () {
      expect(pubspecNameOf('version: 1.0.0\n'), isNull);
      expect(pubspecNameOf('name:\nversion: 1.0.0\n'), isNull);
    });
  });

  group('windowsBinaryName', () {
    test('reads the line of the flutter create template', () {
      const cmake = '''
cmake_minimum_required(VERSION 3.14)
project(my_app LANGUAGES CXX)

# The name of the executable created for the application.
set(BINARY_NAME "my_app")

cmake_policy(SET CMP0063 NEW)
''';
      expect(windowsBinaryName(cmake), 'my_app');
    });

    test('accepts an unquoted name, any case and spacing', () {
      expect(
        windowsBinaryName('set(BINARY_NAME acme_shop_app)'),
        'acme_shop_app',
      );
      expect(windowsBinaryName('  SET ( BINARY_NAME   "x y" )'), 'x y');
    });

    test('a commented line and a variable reference are not a name', () {
      expect(windowsBinaryName('# set(BINARY_NAME "old")\n'), isNull);
      expect(windowsBinaryName(r'set(BINARY_NAME "${APP_NAME}")'), isNull);
    });

    test('is null when there is no BINARY_NAME', () {
      expect(windowsBinaryName('project(x)\n'), isNull);
    });
  });

  group('macosProductName', () {
    test('reads the line of the flutter create template', () {
      const xcconfig = '''
// Application-level settings for the Runner target.

// The application's name. By default this is also the title of the Flutter window.
PRODUCT_NAME = my_app

// The application's bundle identifier
PRODUCT_BUNDLE_IDENTIFIER = com.example.myApp
''';
      expect(macosProductName(xcconfig), 'my_app');
    });

    test('keeps spaces inside the name and drops a trailing comment', () {
      expect(
        macosProductName('PRODUCT_NAME = Example App // shown\n'),
        'Example App',
      );
      expect(macosProductName('PRODUCT_NAME=Tight\n'), 'Tight');
    });

    test('a commented line and a build variable are not a name', () {
      expect(macosProductName('// PRODUCT_NAME = old\n'), isNull);
      expect(macosProductName(r'PRODUCT_NAME = $(TARGET_NAME)'), isNull);
      expect(macosProductName(r'PRODUCT_NAME = ${TARGET_NAME}'), isNull);
    });

    test('a file with Windows line endings gives the name without \\r', () {
      expect(
        macosProductName('// c\r\nPRODUCT_NAME = my_app\r\nOTHER = 1\r\n'),
        'my_app',
      );
      expect(
        windowsBinaryName('project(x)\r\nset(BINARY_NAME "my_app")\r\n'),
        'my_app',
      );
    });

    test('a conditional setting is not the plain one', () {
      expect(macosProductName('PRODUCT_NAME[sdk=macosx*] = x\n'), isNull);
    });

    test('is null when there is no PRODUCT_NAME or it is empty', () {
      expect(macosProductName('OTHER = 1\n'), isNull);
      expect(macosProductName('PRODUCT_NAME =\n'), isNull);
    });
  });

  group('inferProjectFacts', () {
    final posix = p.Context(style: p.Style.posix);
    ProjectFacts infer(MemoryFs fs) =>
        inferProjectFacts(fs: fs, path: posix, root: '/app');

    MemoryFs full() => MemoryFs()
      ..put('/app/pubspec.yaml', 'name: shop_front\nversion: 2.0.1+5\n')
      ..put('/app/windows/CMakeLists.txt', 'set(BINARY_NAME "shop_front")\n')
      ..put(
        '/app/macos/Runner/Configs/AppInfo.xcconfig',
        'PRODUCT_NAME = Shop Front\n',
      )
      ..put('/app/installer/shop.iss', '[Setup]\n');

    test('reads every fact from the project', () {
      final facts = infer(full());
      expect(facts.pubspecName, 'shop_front');
      expect(facts.slug, 'ShopFront');
      expect(facts.displayName, 'Shop Front');
      expect(facts.windowsExe, 'shop_front.exe');
      expect(facts.macosAppName, 'Shop Front');
      expect(facts.installerScript, 'installer/shop.iss');
      expect(facts.problems, isEmpty);
    });

    test('writes nothing and reads only the four places', () {
      final fs = full();
      final before = fs.snapshot();
      infer(fs);
      expect(fs.snapshot(), before);
    });

    test(
      'a mobile-only project has no windows or macos facts, with reasons',
      () {
        final fs = MemoryFs()..put('/app/pubspec.yaml', 'name: shop_front\n');
        final facts = infer(fs);
        expect(facts.slug, 'ShopFront');
        expect(facts.windowsExe, isNull);
        expect(facts.macosAppName, isNull);
        expect(facts.installerScript, isNull);
        expect(
          facts.problems['windows.exe'],
          contains('windows/CMakeLists.txt does not exist'),
        );
        expect(
          facts.problems['macos.appName'],
          contains('macos/Runner/Configs/AppInfo.xcconfig does not exist'),
        );
        expect(
          facts.problems['windows.installerScript'],
          'installer/ has no .iss file',
        );
      },
    );

    test('two installer scripts: none is picked, both are named', () {
      final fs = full()..put('/app/installer/other.iss', '');
      final facts = infer(fs);
      expect(facts.installerScript, isNull);
      expect(
        facts.problems['windows.installerScript'],
        'installer/ has 2 .iss files (installer/other.iss, installer/shop.iss), so none is picked',
      );
    });

    test('only .iss files count, in any letter case, not in sub folders', () {
      final fs = MemoryFs()
        ..put('/app/pubspec.yaml', 'name: x\n')
        ..put('/app/installer/build.ps1', '')
        ..put('/app/installer/README.md', '')
        ..put('/app/installer/old/legacy.iss', '')
        ..put('/app/installer/App.ISS', '');
      expect(infer(fs).installerScript, 'installer/App.ISS');
    });

    test('a CMakeLists without BINARY_NAME says so', () {
      final fs = full()..put('/app/windows/CMakeLists.txt', 'project(x)\n');
      final facts = infer(fs);
      expect(facts.windowsExe, isNull);
      expect(
        facts.problems['windows.exe'],
        contains('has no set(BINARY_NAME "...") line'),
      );
    });

    test('a pubspec without a name leaves the name facts null', () {
      final fs = full()..put('/app/pubspec.yaml', 'version: 1.0.0\n');
      final facts = infer(fs);
      expect(facts.pubspecName, isNull);
      expect(facts.slug, isNull);
      expect(facts.displayName, isNull);
      expect(facts.windowsExe, 'shop_front.exe', reason: 'independent facts');
    });

    test('works with Windows paths too', () {
      final fs = MemoryFs(separator: r'\')
        ..put(r'C:\app\pubspec.yaml', 'name: shop_front\n')
        ..put(r'C:\app\windows\CMakeLists.txt', 'set(BINARY_NAME "sf")\n')
        ..put(r'C:\app\installer\shop.iss', '');
      final facts = inferProjectFacts(
        fs: fs,
        path: p.Context(style: p.Style.windows),
        root: r'C:\app',
      );
      expect(facts.windowsExe, 'sf.exe');
      expect(facts.installerScript, 'installer/shop.iss');
    });
  });
}
