import 'dart:convert';

import 'package:test/test.dart';

import 'package:flutter_build_tools/src/sha256.dart';

String sha(String text) => Sha256.hex(utf8.encode(text));

void main() {
  group('Sha256 standard test vectors (FIPS 180-4 / NIST)', () {
    test('empty message', () {
      expect(
        sha(''),
        'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
      );
    });

    test('abc', () {
      expect(
        sha('abc'),
        'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
      );
    });

    test('448-bit message', () {
      expect(
        sha('abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq'),
        '248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1',
      );
    });

    test('896-bit message', () {
      expect(
        sha(
          'abcdefghbcdefghicdefghijdefghijkefghijklfghijklmghijklmnhijklmnoijklmnopjklmnopqklmnopqrlmnopqrsmnopqrstnopqrstu',
        ),
        'cf5b16a778af8380036ce59e7b0492370b249b11e8f07a51afac45037afee9d1',
      );
    });

    test('one million times a', () {
      expect(
        sha('a' * 1000000),
        'cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0',
      );
    });

    test('pangram', () {
      expect(
        sha('The quick brown fox jumps over the lazy dog'),
        'd7a8fbb307d7809469ca9abcb0082e4f8d5651e46d3cdb762d02d0bf37c9e592',
      );
    });
  });

  group('padding boundaries (reference digests from python hashlib)', () {
    const expected = {
      1: 'ca978112ca1bbdcafac231b39a23dc4da786eff8147c4e72b9807785afee48bb',
      55: '9f4390f8d30c2dd92ec9f095b65e2b9ae9b0a925a5258e241c9f1e910f734318',
      56: 'b35439a4ac6f0948b6d6f9e3c6af0f5f590ce20f1bde7090ef7970686ec6738a',
      57: 'f13b2d724659eb3bf47f2dd6af1accc87b81f09f59f2b75e5c0bed6589dfe8c6',
      63: '7d3e74a05d7db15bce4ad9ec0658ea98e3f06eeecf16b4c6fff2da457ddc2f34',
      64: 'ffe054fe7ae0cb6dc65c3af9b61d5209f439851db43d0ba5997337df154668eb',
      65: '635361c48bb9eab14198e76ea8ab7f1a41685d6ad62aa9146d301d4f17eb0ae0',
      119: '31eba51c313a5c08226adf18d4a359cfdfd8d2e816b13f4af952f7ea6584dcfb',
      120: '2f3d335432c70b580af0e8e1b3674a7c020d683aa5f73aaaedfdc55af904c21c',
      127: 'c57e9278af78fa3cab38667bef4ce29d783787a2f731d4e12200270f0c32320a',
      128: '6836cf13bac400e9105071cd6af47084dfacad4e5e302c94bfed24e013afb73e',
      129: 'c12cb024a2e5551cca0e08fce8f1c5e314555cc3fef6329ee994a3db752166ae',
      1000: '41edece42d63e8d9bf515a9ba6932e1c20cbc9f5a5d134645adb5db1b9737ea3',
    };

    for (final entry in expected.entries) {
      test('${entry.key} bytes of a, in one piece and in awkward chunks', () {
        final bytes = List.filled(entry.key, 0x61);
        expect(Sha256.hex(bytes), entry.value);
        for (final chunk in [1, 3, 7, 63, 64, 65]) {
          final sha256 = Sha256();
          for (var i = 0; i < bytes.length; i += chunk) {
            sha256.add(
              bytes.sublist(
                i,
                i + chunk > bytes.length ? bytes.length : i + chunk,
              ),
            );
          }
          expect(sha256.close(), entry.value, reason: 'chunk size $chunk');
        }
      });
    }
  });

  test('hexOfStream hashes a chunked stream', () async {
    final chunks = Stream.fromIterable([
      utf8.encode('The quick brown '),
      utf8.encode('fox jumps over'),
      utf8.encode(' the lazy dog'),
    ]);
    expect(
      await Sha256.hexOfStream(chunks),
      'd7a8fbb307d7809469ca9abcb0082e4f8d5651e46d3cdb762d02d0bf37c9e592',
    );
  });

  test('a closed hash refuses more input', () {
    final sha256 = Sha256()..close();
    expect(() => sha256.add([1]), throwsStateError);
    expect(sha256.close, throwsStateError);
  });
}
