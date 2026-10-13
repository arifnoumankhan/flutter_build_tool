/// Facts a project already states in its own files, so that a Flutter project
/// needs no `tool/build/build_config.json` to be built.
///
/// Everything here is pure: it reads through [BuildFs] and returns values, so
/// it is unit-testable with an in-memory file system and writes nothing. The
/// explicit `build_config.json` always wins over what is inferred here, key by
/// key (see `AppConfig.parse`).
library;

import 'package:path/path.dart' as p;

import 'package:flutter_build_tools/src/fs.dart';

/// The default folder of the env files, relative to the project root.
const String defaultEnvDirectory = 'config/env';

/// The app id used when `build_config.json` does not set `app`.
const String defaultAppId = 'app';

/// The project facts that [inferProjectFacts] could read, and for every fact
/// it could not read, why.
class ProjectFacts {
  /// Creates the facts; [inferProjectFacts] is the normal way to get them.
  const ProjectFacts({
    this.pubspecName,
    this.windowsExe,
    this.installerScript,
    this.macosAppName,
    this.problems = const {},
  });

  /// `name:` of `pubspec.yaml`, or null when it has none.
  final String? pubspecName;

  /// `BINARY_NAME` of `windows/CMakeLists.txt` plus `.exe`, or null.
  final String? windowsExe;

  /// The one `installer/*.iss`, '/'-separated, or null when there is none or
  /// more than one.
  final String? installerScript;

  /// `PRODUCT_NAME` of `macos/Runner/Configs/AppInfo.xcconfig`, or null.
  final String? macosAppName;

  /// Why a fact is null, keyed by its `build_config.json` name
  /// (`windows.exe`, `windows.installerScript`, `macos.appName`).
  final Map<String, String> problems;

  /// The artifact prefix inferred from the pubspec name, or null.
  String? get slug =>
      pubspecName == null ? null : slugFromPubspecName(pubspecName!);

  /// The readable name inferred from the pubspec name, or null.
  String? get displayName =>
      pubspecName == null ? null : displayNameFromPubspecName(pubspecName!);
}

/// Reads the facts of the project at [root] from `pubspec.yaml`,
/// `windows/CMakeLists.txt`, `macos/Runner/Configs/AppInfo.xcconfig` and
/// `installer/`. Never throws for a missing or unreadable file: the fact is
/// null and [ProjectFacts.problems] says why.
ProjectFacts inferProjectFacts({
  required BuildFs fs,
  required p.Context path,
  required String root,
}) {
  String abs(String relative) => path.joinAll([root, ...relative.split('/')]);

  String? read(String relative) {
    final file = abs(relative);
    if (!fs.fileExists(file)) return null;
    try {
      return fs.readString(file);
    } on Exception {
      return null; // Unreadable or not UTF-8: treated as "no such fact".
    }
  }

  final problems = <String, String>{};

  final pubspec = read('pubspec.yaml');
  final name = pubspec == null ? null : pubspecNameOf(pubspec);

  const cmake = 'windows/CMakeLists.txt';
  String? windowsExe;
  final cmakeText = read(cmake);
  if (cmakeText == null) {
    problems['windows.exe'] =
        '$cmake does not exist (a project without a windows/ folder cannot build windows; "flutter create --platforms=windows ." adds it)';
  } else {
    final binary = windowsBinaryName(cmakeText);
    if (binary == null) {
      problems['windows.exe'] =
          '$cmake has no set(BINARY_NAME "...") line with a literal name';
    } else {
      windowsExe = '$binary.exe';
    }
  }

  const xcconfig = 'macos/Runner/Configs/AppInfo.xcconfig';
  String? macosAppName;
  final xcconfigText = read(xcconfig);
  if (xcconfigText == null) {
    problems['macos.appName'] =
        '$xcconfig does not exist (a project without a macos/ folder cannot build macos; "flutter create --platforms=macos ." adds it)';
  } else {
    macosAppName = macosProductName(xcconfigText);
    if (macosAppName == null) {
      problems['macos.appName'] =
          '$xcconfig has no PRODUCT_NAME line with a literal name';
    }
  }

  String? installerScript;
  List<String> installerFiles;
  try {
    installerFiles = fs.listFiles(abs('installer'));
  } on Exception {
    installerFiles = const []; // Unreadable folder: no fact, not a failure.
  }
  final scripts = <String>[
    for (final file in installerFiles)
      if (path.basename(file).toLowerCase().endsWith('.iss'))
        'installer/${path.basename(file)}',
  ]..sort();
  if (scripts.length == 1) {
    installerScript = scripts.single;
  } else if (scripts.isEmpty) {
    problems['windows.installerScript'] = 'installer/ has no .iss file';
  } else {
    problems['windows.installerScript'] =
        'installer/ has ${scripts.length} .iss files (${scripts.join(', ')}), so none is picked';
  }

  return ProjectFacts(
    pubspecName: name,
    windowsExe: windowsExe,
    installerScript: installerScript,
    macosAppName: macosAppName,
    problems: Map.unmodifiable(problems),
  );
}

/// The top-level `name:` of a pubspec, or null when there is none.
String? pubspecNameOf(String pubspecText) {
  final line = RegExp(
    r'^name:[ \t]*(.*?)[ \t]*(?:#.*)?$',
    multiLine: true,
  ).firstMatch(pubspecText);
  if (line == null) return null;
  final raw = line.group(1)!.replaceAll('"', '').replaceAll("'", '').trim();
  return raw.isEmpty ? null : raw;
}

/// PascalCase of a pubspec name, letters and digits only: `my_cool_app`
/// gives `MyCoolApp`, `acme_shop_app` gives `AcmeShopApp`. It prefixes every
/// artifact name, so it must be a plain word; a name with no letter or digit
/// gives `App`.
String slugFromPubspecName(String name) {
  final words = _words(name, RegExp(r'[^A-Za-z0-9]+'));
  return words.isEmpty ? 'App' : words.join();
}

/// A readable title of a pubspec name: `my_cool_app` gives `My Cool App`.
String displayNameFromPubspecName(String name) {
  final words = _words(name, RegExp(r'[^A-Za-z0-9]+'));
  return words.isEmpty ? 'App' : words.join(' ');
}

List<String> _words(String name, Pattern separator) => [
  for (final part in name.split(separator))
    if (part.isNotEmpty) '${part[0].toUpperCase()}${part.substring(1)}',
];

/// The `BINARY_NAME` of a Flutter `windows/CMakeLists.txt`
/// (`set(BINARY_NAME "my_app")`), or null when it is missing or not a literal.
String? windowsBinaryName(String cmakeText) {
  final match = RegExp(
    r'''^[ \t]*set[ \t]*\([ \t]*BINARY_NAME[ \t]+(?:"([^"]+)"|([^\s")]+))[ \t]*\)''',
    multiLine: true,
    caseSensitive: false,
  ).firstMatch(cmakeText);
  final value = match?.group(1) ?? match?.group(2);
  if (value == null || value.contains(r'${')) return null;
  return value;
}

/// The `PRODUCT_NAME` of a Flutter `macos/Runner/Configs/AppInfo.xcconfig`, or
/// null when it is missing or built from another variable.
String? macosProductName(String xcconfigText) {
  final match = RegExp(
    r'^[ \t]*PRODUCT_NAME[ \t]*=[ \t]*(.*?)[ \t]*(?://.*)?$',
    multiLine: true,
  ).firstMatch(xcconfigText);
  final value = match?.group(1)?.trim(); // CRLF files leave a trailing \r
  if (value == null || value.isEmpty) return null;
  if (value.contains(r'$(') || value.contains(r'${')) return null;
  return value;
}
