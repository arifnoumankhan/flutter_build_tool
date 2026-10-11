// The library is generic: no app, company or host name may be baked into
// lib/ or bin/. Project facts belong in build_config.json.
//
// Hosts are checked against a placeholder allow-list. Names cannot be listed
// here without naming them, so pass your own as a comma-separated
// FORBIDDEN_LITERALS environment variable:
//
//   FORBIDDEN_LITERALS=acme,acmecorp dart test test/no_app_literals_test.dart
import 'dart:io';

import 'package:test/test.dart';

/// Hosts a doc comment or message may use as an example.
final _placeholderHost = RegExp(
  r'^(example\.(com|org|net)|[a-z0-9-]+\.example\.(com|org|net)|host|localhost'
  r'|127\.0\.0\.1|10\.\d+\.\d+\.\d+|192\.168\.\d+\.\d+|\.*)$',
);

final _url = RegExp(r'https?://([A-Za-z0-9.\-]*)');

/// Every line of every Dart file under lib/ and bin/, as `path:line: text`.
List<(String, String)> _sourceLines() => [
  for (final dir in ['lib', 'bin'])
    for (final entity in Directory(dir).listSync(recursive: true))
      if (entity is File && entity.path.endsWith('.dart'))
        for (final (i, line) in entity.readAsLinesSync().indexed)
          ('${entity.path}:${i + 1}', line),
];

void main() {
  test('lib/ and bin/ only use placeholder hosts', () {
    final offenders = [
      for (final (where, line) in _sourceLines())
        for (final match in _url.allMatches(line))
          if (!_placeholderHost.hasMatch(match.group(1)!))
            '$where: ${line.trim()}',
    ];
    expect(offenders, isEmpty);
  });

  final forbidden = (Platform.environment['FORBIDDEN_LITERALS'] ?? '')
      .split(',')
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .toList();
  test(
    'lib/ and bin/ mention none of FORBIDDEN_LITERALS',
    skip: forbidden.isEmpty ? 'FORBIDDEN_LITERALS is not set' : null,
    () {
      final patterns = [
        for (final name in forbidden)
          RegExp(RegExp.escape(name), caseSensitive: false),
      ];
      final offenders = [
        for (final (where, line) in _sourceLines())
          if (patterns.any((p) => p.hasMatch(line))) '$where: ${line.trim()}',
      ];
      expect(offenders, isEmpty);
    },
  );

  test('the scan sees the library (it would not pass on an empty folder)', () {
    final files = Directory(
      'lib/src',
    ).listSync().whereType<File>().where((f) => f.path.endsWith('.dart'));
    expect(files.length, greaterThan(20));
  });
}
