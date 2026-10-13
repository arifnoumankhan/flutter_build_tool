// The files of the web zip golden test, shared by the test and by the probe
// process that runs it in another time zone.
import '../fakes.dart';

/// The build time the golden zip was written with.
final DateTime webZipMoment = DateTime.utc(2026, 10, 6, 12, 34, 56);

/// sha256 of the zip that 0.1.0 produced (archive 3.6.1, UTC machine) for
/// [webZipFixture] and [webZipMoment]; 0.2.0 must give the same bytes with
/// archive 3.6.x, with archive 4.x and in any time zone.
const String webZipGolden =
    '9421d5462adba88c860d699315e0351b53c45f84638517beb2db7b80ec59c181';

/// The web build folder `/repo/build/web`, with litter that must be excluded.
/// [reversed] creates the files in the opposite order.
MemoryFs webZipFixture({bool reversed = false}) {
  final files = <String, Object>{
    'index.html': '<html>',
    'main.dart.js': 'console.log(1)',
    'assets/AssetManifest.json': '{}',
    'assets/fonts/Inter.ttf': [0, 1, 2, 255],
    'assets/日本.txt': 'unicode name\n',
    'empty.txt': '',
    'big.txt': 'The quick brown fox jumps over the lazy dog\n' * 500,
    '.DS_Store': 'x',
    '.last_build_id': 'abc',
    '__MACOSX/._index.html': 'x',
    'hand_made_backup.zip': 'x',
  };
  final fs = MemoryFs();
  for (final key in reversed ? files.keys.toList().reversed : files.keys) {
    fs.put('/repo/build/web/$key', files[key]!);
  }
  return fs;
}
