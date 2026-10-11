import 'package:test/test.dart';

import 'package:flutter_build_tools/src/disk.dart';
import 'package:flutter_build_tools/src/model.dart';
import 'package:flutter_build_tools/src/runner.dart';
import 'fakes.dart';

/// What `df -Pk <dir>` prints on macOS and on Linux.
const _macDf = '''
Filesystem   1024-blocks     Used Available Capacity  Mounted on
/dev/disk3s1    97656252 86275520  11259772    89%    /Volumes/Workspaces
''';

const _linuxDf = '''
Filesystem     1024-blocks      Used Available Capacity Mounted on
/dev/sda1         41152736  30011320   9005228      77% /
''';

void main() {
  group('parseDfFreeBytes reads the Available column', () {
    test('macOS output', () {
      expect(parseDfFreeBytes(_macDf), 11259772 * 1024);
    });

    test('Linux output', () {
      expect(parseDfFreeBytes(_linuxDf), 9005228 * 1024);
    });

    test('the block size comes from the header', () {
      expect(
        parseDfFreeBytes(
          'Filesystem 512-blocks Used Available Capacity Mounted on\n'
          '/dev/disk3s1 195312504 172551040 22519544 89% /Volumes/Workspaces\n',
        ),
        22519544 * 512,
      );
    });

    test('a filesystem name and a mount point with spaces', () {
      expect(
        parseDfFreeBytes(
          'Filesystem 1024-blocks Used Available Capacity Mounted on\n'
          'Macintosh HD 100 40 60 40% /Volumes/My Disk 2\n',
        ),
        60 * 1024,
      );
    });

    test('a value above 2^32 stays exact', () {
      expect(
        parseDfFreeBytes(
          'Filesystem 1024-blocks Used Available Capacity Mounted on\n'
          '/dev/x 9000000000 1 8000000000 1% /\n',
        ),
        8000000000 * 1024,
      );
    });

    test('anything else is unknown, not an error', () {
      expect(parseDfFreeBytes(''), isNull);
      expect(
        parseDfFreeBytes('df: /nope: No such file or directory\n'),
        isNull,
      );
      expect(
        parseDfFreeBytes(
          'Filesystem 1024-blocks Used Available Capacity Mounted on\n',
        ),
        isNull,
        reason: 'header only',
      );
      expect(
        parseDfFreeBytes(
          'Filesystem 1024-blocks Used Available Capacity Mounted on\n'
          'weird - - - - /mnt\n',
        ),
        isNull,
      );
    });
  });

  group('freeDiskBytes', () {
    test('asks df about the repository root, in 1 KB blocks', () async {
      final world = TestWorld();
      world.runner.onCapture((s) => s.executable == 'df', (_) {
        return const CapturedProcess(0, _macDf, '');
      });
      expect(await freeDiskBytes(world.env), 11259772 * 1024);
      final call = world.runner.calls.singleWhere((c) => c.executable == 'df');
      expect(call.args, ['-Pk', '/repo']);
    });

    test('works on Linux hosts too', () async {
      final world = TestWorld(host: HostOs.linux);
      world.runner.onCapture(
        (s) => s.executable == 'df',
        (_) => const CapturedProcess(0, _linuxDf, ''),
      );
      expect(await freeDiskBytes(world.env), 9005228 * 1024);
    });

    test('Windows has no df: nothing is run', () async {
      final world = TestWorld(host: HostOs.windows);
      expect(await freeDiskBytes(world.env), isNull);
      expect(world.runner.calls.where((c) => c.executable == 'df'), isEmpty);
    });

    test('df missing, failing or garbled is unknown, never a throw', () async {
      final missing = TestWorld(); // df is not scripted: cannot be started
      expect(await freeDiskBytes(missing.env), isNull);

      final failing = TestWorld();
      failing.runner.onCapture(
        (s) => s.executable == 'df',
        (_) => const CapturedProcess(1, '', 'df: broken'),
      );
      expect(await freeDiskBytes(failing.env), isNull);

      final garbled = TestWorld();
      garbled.runner.onCapture(
        (s) => s.executable == 'df',
        (_) => const CapturedProcess(0, 'no table here', ''),
      );
      expect(await freeDiskBytes(garbled.env), isNull);
    });
  });
}
