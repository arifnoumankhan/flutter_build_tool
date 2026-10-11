/// Android release-signing detection. Mirrors `android/app/build.gradle`: a
/// release keystore is used only when `android/key.properties` has all four
/// keys and `storeFile` exists (relative paths resolve from `android/app`),
/// and signing was opted in. Values are only read, never printed.
library;

import 'package:path/path.dart' as p;

import 'package:flutter_build_tools/src/fs.dart';
import 'package:flutter_build_tools/src/model.dart';

/// The keys `android/key.properties` must hold for release signing.
const List<String> keystoreKeys = [
  'storePassword',
  'keyPassword',
  'keyAlias',
  'storeFile',
];

/// What `android/key.properties` says, without any secret value.
class KeystoreStatus {
  /// Creates the status.
  const KeystoreStatus({
    required this.propertiesFound,
    required this.missingKeys,
    required this.storeFileExists,
    required this.optedInByFile,
  });

  /// `android/key.properties` exists.
  final bool propertiesFound;

  /// Keys from [keystoreKeys] that are missing or empty.
  final List<String> missingKeys;

  /// The file named by `storeFile` exists.
  final bool storeFileExists;

  /// `useReleaseSigning=true` is set in `android/key.properties`.
  final bool optedInByFile;

  /// Gradle's `hasReleaseKeystore`.
  bool get valid => propertiesFound && missingKeys.isEmpty && storeFileExists;

  /// Why the keystore is not usable, without echoing any value.
  String get problem {
    if (!propertiesFound) return 'android/key.properties does not exist';
    if (missingKeys.isNotEmpty) {
      return 'android/key.properties is missing ${missingKeys.join(', ')}';
    }
    if (!storeFileExists) {
      return 'the file named by storeFile in android/key.properties does not exist';
    }
    return 'ok';
  }
}

/// What the APK signing will do for [request].
class ApkSigning {
  /// Creates the plan.
  const ApkSigning({
    required this.passGradleFlag,
    required this.releaseKeystore,
  });

  /// Pass `-P useReleaseSigning=true` to flutter (opt in to the keystore).
  final bool passGradleFlag;

  /// The APK will be signed with the release keystore; false means the debug
  /// key.
  final bool releaseKeystore;

  /// `release-keystore` or `debug-key`, as written to the manifest.
  String get kind => releaseKeystore ? 'release-keystore' : 'debug-key';
}

/// Release signing is opt-in (`--release-signing`, or `useReleaseSigning=true`
/// in key.properties), except for prod where it is always requested, because
/// a prod APK must never be signed with the debug key.
ApkSigning planApkSigning(BuildRequest request, KeystoreStatus keystore) {
  final release = request.mode == BuildMode.release;
  final requested = release && (request.releaseSigning || request.env.isProd);
  final optedIn = requested || (release && keystore.optedInByFile);
  return ApkSigning(
    passGradleFlag: requested,
    releaseKeystore: optedIn && keystore.valid,
  );
}

/// Reads `android/key.properties` (never printing a value) the way
/// `android/app/build.gradle` does.
KeystoreStatus inspectKeystore({
  required BuildFs fs,
  required p.Context path,
  required String root,
}) {
  final propertiesPath = path.join(root, 'android', 'key.properties');
  if (!fs.fileExists(propertiesPath)) {
    return const KeystoreStatus(
      propertiesFound: false,
      missingKeys: keystoreKeys,
      storeFileExists: false,
      optedInByFile: false,
    );
  }
  final properties = parseProperties(fs.readString(propertiesPath));
  final missing = [
    for (final key in keystoreKeys)
      if ((properties[key] ?? '').isEmpty) key,
  ];
  var storeFileExists = false;
  final storeFile = properties['storeFile'] ?? '';
  if (storeFile.isNotEmpty) {
    final resolved = path.isAbsolute(storeFile)
        ? storeFile
        : path.normalize(path.join(root, 'android', 'app', storeFile));
    storeFileExists = fs.fileExists(resolved);
  }
  return KeystoreStatus(
    propertiesFound: true,
    missingKeys: missing,
    storeFileExists: storeFileExists,
    optedInByFile:
        (properties['useReleaseSigning'] ?? '').trim().toLowerCase() == 'true',
  );
}

/// Minimal `java.util.Properties` reader: `key=value` or `key: value`, the
/// last occurrence wins, `#`/`!` comment lines are ignored, and the common
/// escapes (`\\`, `\t`, `\n`, `\r`, `\f`, `\uXXXX`) are decoded.
Map<String, String> parseProperties(String text) {
  final result = <String, String>{};
  final line = RegExp(r'^[ \t]*([^\s=:#!][^\s=:]*)[ \t]*[=:][ \t]*(.*)$');
  for (final raw in text.split('\n')) {
    final match = line.firstMatch(raw.replaceAll('\r', ''));
    if (match == null) continue;
    result[match.group(1)!] = _unescape(match.group(2)!);
  }
  return result;
}

String _unescape(String value) {
  if (!value.contains(r'\')) return value;
  final out = StringBuffer();
  for (var i = 0; i < value.length; i++) {
    final c = value[i];
    if (c != r'\' || i == value.length - 1) {
      out.write(c);
      continue;
    }
    final next = value[++i];
    switch (next) {
      case 't':
        out.write('\t');
      case 'n':
        out.write('\n');
      case 'r':
        out.write('\r');
      case 'f':
        out.write('\f');
      case 'u':
        final end = i + 5;
        final code = end <= value.length
            ? int.tryParse(value.substring(i + 1, end), radix: 16)
            : null;
        if (code == null) {
          out.write('u');
        } else {
          out.writeCharCode(code);
          i += 4;
        }
      default:
        out.write(next);
    }
  }
  return out.toString();
}
