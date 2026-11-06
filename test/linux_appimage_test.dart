import 'package:test/test.dart';

import 'package:flutter_build_tools/src/linux_appimage.dart';
import 'fakes.dart';

void main() {
  test('appImageDesktopEntry names the binary and icon', () {
    expect(
      appImageDesktopEntry(name: 'Posty', binary: 'posty', iconStem: 'posty'),
      allOf(
        contains('Name=Posty\n'),
        contains('Exec=posty\n'),
        contains('Icon=posty\n'),
        contains('Type=Application\n'),
      ),
    );
  });

  test('linuxBundleBinaryName reads linux/CMakeLists.txt', () {
    final fs = MemoryFs()
      ..put(
        '/repo/linux/CMakeLists.txt',
        'set(BINARY_NAME "posty")\nset(APPLICATION_ID "com.example.posty")\n',
      );
    expect(linuxBundleBinaryName(fs: fs, root: '/repo'), 'posty');
  });
}
