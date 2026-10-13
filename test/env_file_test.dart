import 'dart:convert';

import 'package:test/test.dart';

import 'package:flutter_build_tools/src/env_file.dart';
import 'package:flutter_build_tools/src/model.dart';

Matcher failsWith(String text) => throwsA(
  isA<BuildException>().having((e) => e.message, 'message', contains(text)),
);

EnvFile parse(Map<String, Object?> json) =>
    EnvFile.parse('config/env/x.json', jsonEncode(json));

const valid = {'APP_ENV': 'dev', 'BASE_URL': 'https://example.com/public'};

void main() {
  group('EnvFile.parse', () {
    test('a minimal file', () {
      final file = parse(valid);
      expect(file.appEnv, 'dev');
      expect(file.baseUrl, 'https://example.com/public');
      expect(file.posWebUrl, isNull);
    });

    test('with POS_WEB_URL', () {
      expect(
        parse({...valid, 'POS_WEB_URL': 'https://pos.example.com'}).posWebUrl,
        'https://pos.example.com',
      );
    });

    test('invalid JSON names the file', () {
      expect(
        () => EnvFile.parse('config/env/x.json', '{oops'),
        failsWith('config/env/x.json is not valid JSON'),
      );
    });

    test('must be a flat object', () {
      expect(
        () => EnvFile.parse('x.json', '["a"]'),
        failsWith('must contain a flat JSON object'),
      );
      expect(
        () => EnvFile.parse('x.json', '"text"'),
        failsWith('must contain a flat JSON object'),
      );
    });

    test('unknown keys are refused, including secrets', () {
      expect(
        () => parse({...valid, 'API_TOKEN': 'abc'}),
        failsWith('unknown key "API_TOKEN"'),
      );
      expect(
        () => parse({...valid, 'BASE_URl': 'x'}),
        failsWith('unknown key "BASE_URl"'),
      );
    });

    test('BUILD_SHA is generated, not configured', () {
      expect(
        () => parse({...valid, 'BUILD_SHA': 'abc'}),
        failsWith('BUILD_SHA, which the build tool generates'),
      );
    });

    test('BUILD_TIME is not a define at all any more', () {
      // It changed on every run, which made Flutter keep a new never-pruned
      // cache folder per build; the build time lives in the manifest only.
      expect(
        () => parse({...valid, 'BUILD_TIME': 'now'}),
        failsWith('unknown key "BUILD_TIME"'),
      );
    });

    test('values must be non-empty strings', () {
      expect(
        () => parse({...valid, 'BASE_URL': 5}),
        failsWith('"BASE_URL" must be a non-empty string'),
      );
      expect(
        () => parse({...valid, 'POS_WEB_URL': ''}),
        failsWith('"POS_WEB_URL" must be a non-empty string'),
      );
      expect(
        () => parse({...valid, 'APP_ENV': null}),
        failsWith('"APP_ENV" must be a non-empty string'),
      );
    });

    test('APP_ENV and BASE_URL are required', () {
      expect(
        () => parse({'BASE_URL': 'https://example.com'}),
        failsWith('missing required key "APP_ENV"'),
      );
      expect(
        () => parse({'APP_ENV': 'dev'}),
        failsWith('missing required key "BASE_URL"'),
      );
    });

    test('BASE_URL and POS_WEB_URL are validated as URLs', () {
      expect(
        () => parse({...valid, 'BASE_URL': 'example.com/public'}),
        failsWith('BASE_URL "example.com/public" is not an absolute URL'),
      );
      expect(
        () => parse({...valid, 'POS_WEB_URL': 'ftp://example.com'}),
        failsWith('POS_WEB_URL "ftp://example.com" must start with http'),
      );
    });
  });

  group('EnvSchema (the project may add keys in build_config.json)', () {
    const schema = EnvSchema(
      extraKeys: ['FEATURE_SET'],
      extraUrlKeys: ['ANALYTICS_URL', 'CDN_URL'],
    );

    EnvFile parseWith(Map<String, Object?> json) =>
        EnvFile.parse('config/env/x.json', jsonEncode(json), schema: schema);

    test('the standard schema allows exactly the three built-in keys', () {
      expect(EnvSchema.standard.allowedKeys, [
        'APP_ENV',
        'BASE_URL',
        'POS_WEB_URL',
      ]);
      expect(
        () => parse({...valid, 'ANALYTICS_URL': 'https://a.example.com'}),
        failsWith(
          'unknown key "ANALYTICS_URL". Allowed keys: APP_ENV, BASE_URL, POS_WEB_URL. (Secrets never belong in env files.)',
        ),
      );
    });

    test('extra keys are accepted and kept', () {
      final file = parseWith({
        ...valid,
        'FEATURE_SET': 'pro',
        'ANALYTICS_URL': 'https://a.example.com',
      });
      expect(file.values['FEATURE_SET'], 'pro');
      expect(file.values['ANALYTICS_URL'], 'https://a.example.com');
    });

    test('they are optional', () {
      expect(parseWith(valid).values.keys, ['APP_ENV', 'BASE_URL']);
    });

    test('the unknown-key message lists the extended set', () {
      expect(
        () => parseWith({...valid, 'API_TOKEN': 'abc'}),
        failsWith(
          'Allowed keys: APP_ENV, BASE_URL, POS_WEB_URL, FEATURE_SET, ANALYTICS_URL, CDN_URL.',
        ),
      );
    });

    test('an extra URL key is validated like BASE_URL', () {
      expect(
        () => parseWith({...valid, 'CDN_URL': 'cdn.example.com'}),
        failsWith('CDN_URL "cdn.example.com" is not an absolute URL'),
      );
      expect(
        () => parseWith({...valid, 'ANALYTICS_URL': 'https://a.example.com/'}),
        failsWith(
          'ANALYTICS_URL "https://a.example.com/" must not end with "/"',
        ),
      );
    });

    test('an extra plain key is not validated as a URL', () {
      expect(
        parseWith({...valid, 'FEATURE_SET': 'not a url'}).values,
        containsPair('FEATURE_SET', 'not a url'),
      );
    });

    test('extra keys must still be non-empty strings', () {
      expect(
        () => parseWith({...valid, 'FEATURE_SET': ''}),
        failsWith('"FEATURE_SET" must be a non-empty string'),
      );
      expect(
        () => parseWith({...valid, 'CDN_URL': 3}),
        failsWith('"CDN_URL" must be a non-empty string'),
      );
    });

    test('BUILD_SHA stays generated even with a schema', () {
      expect(
        () => parseWith({...valid, 'BUILD_SHA': 'abc'}),
        failsWith('BUILD_SHA, which the build tool generates'),
      );
    });

    test('a schema key is only known to that schema', () {
      expect(
        () => EnvFile.parse(
          'config/env/x.json',
          jsonEncode({...valid, 'FEATURE_SET': 'pro'}),
          schema: const EnvSchema(extraUrlKeys: ['CDN_URL']),
        ),
        failsWith('unknown key "FEATURE_SET"'),
      );
    });
  });

  group('urlProblem', () {
    const accepted = [
      'https://devexample.example.com/public',
      'https://v1.example.com',
      'http://127.0.0.1:8011',
      'http://10.0.2.2:8011',
      'https://pos.example.com',
      'https://preprod.example.com/public/web_pos',
    ];
    for (final url in accepted) {
      test('accepts $url', () => expect(urlProblem(url), isNull));
    }

    const rejected = {
      'example.com': 'not an absolute URL',
      '/public': 'not an absolute URL',
      'localhost:8011': 'not an absolute URL',
      'ftp://example.com': 'must start with http',
      'https://example.com/': 'trailing slash',
      'https://example.com/public/': 'trailing slash',
      'https://example.com/public?x=1': 'query string',
      'https://example.com/public#top': 'query string',
      'https://user:pass@example.com': 'credentials',
      'https://exa mple.com': 'whitespace',
      'https://example.com/a b': 'whitespace',
      '': 'not an absolute URL',
    };
    rejected.forEach((url, why) {
      test(
        'rejects "$url" (${why.split(' ').first}...)',
        () => expect(urlProblem(url), contains(why)),
      );
    });
  });

  group('isPlaceholderUrl', () {
    for (final url in [
      'https://dev.replace-me.invalid',
      'https://prod.replace-me.invalid/api',
      'https://x.INVALID',
      'http://invalid',
      'https://a.b.c.invalid:8443/x',
    ]) {
      test(
        '$url is a placeholder',
        () => expect(isPlaceholderUrl(url), isTrue),
      );
    }

    for (final url in [
      'https://api.example.com',
      'https://invalid.example.com',
      'https://notinvalid.com',
      'http://127.0.0.1',
      'https://replace-me.example.org/invalid',
      'not a url',
      '',
    ]) {
      test('"$url" is not', () => expect(isPlaceholderUrl(url), isFalse));
    }

    test('the domain init writes is one', () {
      expect(isPlaceholderUrl('https://dev.$placeholderDomain'), isTrue);
    });
  });
}
