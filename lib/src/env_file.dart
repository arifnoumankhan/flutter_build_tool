/// `config/env/<env>.json`: the committed, non-secret description of one
/// environment, shaped for `flutter --dart-define-from-file`.
library;

import 'dart:convert';

import 'package:flutter_build_tools/src/model.dart';

/// Keys the tool generates itself; an env file must not set them.
const Set<String> generatedDefineKeys = {'BUILD_SHA'};

/// The keys an env file may hold. `APP_ENV` and `BASE_URL` are required;
/// `POS_WEB_URL` is a built-in optional URL. A project adds its own keys in
/// `build_config.json` (`envFile.extraKeys`, `envFile.extraUrlKeys`).
class EnvSchema {
  /// Creates a schema with [extraKeys] (plain strings) and [extraUrlKeys]
  /// (URLs, validated and guarded like `BASE_URL`) on top of the built-ins.
  const EnvSchema({this.extraKeys = const [], this.extraUrlKeys = const []});

  /// Only the built-in keys.
  static const EnvSchema standard = EnvSchema();

  /// Keys every env file must have.
  static const List<String> requiredKeys = ['APP_ENV', 'BASE_URL'];

  /// Built-in optional URL keys.
  static const List<String> builtInOptionalUrlKeys = ['POS_WEB_URL'];

  /// Validates the project's extras; [fail] receives the message and must throw.
  factory EnvSchema.validated({
    required List<String> extraKeys,
    required List<String> extraUrlKeys,
    required Never Function(String message) fail,
  }) {
    final reserved = {
      ...requiredKeys,
      ...builtInOptionalUrlKeys,
      ...generatedDefineKeys,
    };
    final seen = <String>{};
    for (final (list, where) in [
      (extraKeys, 'envFile.extraKeys'),
      (extraUrlKeys, 'envFile.extraUrlKeys'),
    ]) {
      for (final key in list) {
        if (!RegExp(r'^[A-Z][A-Z0-9_]*$').hasMatch(key)) {
          fail('"$where" entry "$key" must be UPPER_SNAKE_CASE.');
        }
        if (reserved.contains(key)) {
          fail(
            '"$where" entry "$key" is already a built-in or generated key; remove it.',
          );
        }
        if (!seen.add(key)) {
          fail('"$where" lists "$key" twice (or in both lists).');
        }
      }
    }
    return EnvSchema(
      extraKeys: List.unmodifiable(extraKeys),
      extraUrlKeys: List.unmodifiable(extraUrlKeys),
    );
  }

  /// Plain string keys added by the project.
  final List<String> extraKeys;

  /// URL keys added by the project.
  final List<String> extraUrlKeys;

  /// Every key an env file may contain, in the order of messages and listings.
  List<String> get allowedKeys => [
    ...requiredKeys,
    ...builtInOptionalUrlKeys,
    ...extraKeys,
    ...extraUrlKeys,
  ];

  /// Optional URL keys, in the order they are validated and printed after
  /// `BASE_URL`.
  List<String> get optionalUrlKeys => [
    ...builtInOptionalUrlKeys,
    ...extraUrlKeys,
  ];
}

/// An env file: the committed, non-secret description of one environment.
class EnvFile {
  /// Creates an env file; [EnvFile.parse] is the normal way to get one.
  const EnvFile(this.path, this.values);

  /// Display path (relative to the repo when possible).
  final String path;

  /// The validated key/value pairs.
  final Map<String, String> values;

  /// `APP_ENV`.
  String get appEnv => values['APP_ENV']!;

  /// `BASE_URL`.
  String get baseUrl => values['BASE_URL']!;

  /// `POS_WEB_URL`, null when the file has none.
  String? get posWebUrl => values['POS_WEB_URL'];

  /// Parses and validates the structure of an env file. Semantic rules that
  /// depend on the requested environment (APP_ENV equals it, https, prod
  /// restrictions) are guards, see guards.dart.
  factory EnvFile.parse(
    String path,
    String text, {
    EnvSchema schema = EnvSchema.standard,
  }) {
    final Object? decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException catch (e) {
      throw BuildException(
        '$path is not valid JSON: ${e.message}. Expected a flat object like {"APP_ENV": "dev", "BASE_URL": "https://..."}.',
      );
    }
    if (decoded is! Map<String, Object?>) {
      throw BuildException(
        '$path must contain a flat JSON object like {"APP_ENV": "dev", "BASE_URL": "https://..."}.',
      );
    }
    final allowed = schema.allowedKeys;
    final values = <String, String>{};
    for (final entry in decoded.entries) {
      final key = entry.key;
      final value = entry.value;
      if (generatedDefineKeys.contains(key)) {
        throw BuildException(
          '$path sets $key, which the build tool generates. Remove it.',
        );
      }
      if (!allowed.contains(key)) {
        throw BuildException(
          '$path has unknown key "$key". Allowed keys: ${allowed.join(', ')}. (Secrets never belong in env files.)',
        );
      }
      if (value is! String || value.isEmpty) {
        throw BuildException(
          '$path: "$key" must be a non-empty string (omit the key instead of leaving it empty).',
        );
      }
      values[key] = value;
    }
    for (final required in EnvSchema.requiredKeys) {
      if (!values.containsKey(required)) {
        throw BuildException('$path is missing required key "$required".');
      }
    }
    final baseProblem = urlProblem(values['BASE_URL']!);
    if (baseProblem != null) {
      throw BuildException(
        '$path: BASE_URL "${values['BASE_URL']}" $baseProblem',
      );
    }
    for (final key in schema.optionalUrlKeys) {
      final url = values[key];
      if (url == null) continue;
      final problem = urlProblem(url);
      if (problem != null) {
        throw BuildException('$path: $key "$url" $problem');
      }
    }
    return EnvFile(path, Map.unmodifiable(values));
  }
}

/// Why [value] is not an acceptable base URL, or null when it is. The text
/// continues a sentence that starts with the value.
String? urlProblem(String value) {
  if (RegExp(r'\s').hasMatch(value)) return 'must not contain whitespace.';
  final uri = Uri.tryParse(value);
  if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
    return 'is not an absolute URL. Use the full origin, e.g. https://example.com/public.';
  }
  if (uri.scheme != 'http' && uri.scheme != 'https') {
    return 'must start with http:// or https://.';
  }
  if (uri.userInfo.isNotEmpty) {
    return 'must not contain credentials (user:password@). Secrets never go into the build profile.';
  }
  if (uri.hasQuery || uri.hasFragment) {
    return 'must not contain a query string or fragment.';
  }
  if (value.endsWith('/')) {
    return 'must not end with "/". Remove the trailing slash.';
  }
  return null;
}

/// The domain suffix of the placeholder URLs `init` writes. `.invalid` is
/// reserved (RFC 2606): such a host can never resolve, so a build that still
/// points at one cannot be mistaken for a working server.
const String placeholderDomain = 'replace-me.invalid';

/// True when [url] is a placeholder written by `init` (its host is under the
/// reserved `.invalid` top-level domain) and has to be replaced before the
/// binary can reach a server. Prod refuses it (guard `placeholder-url`).
bool isPlaceholderUrl(String url) {
  final host = Uri.tryParse(url.trim())?.host.toLowerCase() ?? '';
  return host == 'invalid' || host.endsWith('.invalid');
}
