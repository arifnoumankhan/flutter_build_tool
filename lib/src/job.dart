/// A resolved profile plus everything derived from it that the build steps
/// share: output locations and APK signing.
library;

import 'package:flutter_build_tools/src/environment.dart';
import 'package:flutter_build_tools/src/keystore.dart';
import 'package:flutter_build_tools/src/model.dart';
import 'package:flutter_build_tools/src/profile.dart';

/// One build to run: the profile and where its inputs and outputs live.
class BuildJob {
  /// Creates the job; [keystore] is only needed for apk builds.
  BuildJob(this.env, this.profile, {this.keystore})
    : signing = keystore == null
          ? null
          : planApkSigning(profile.request, keystore);

  /// The machine and project the job runs on.
  final BuildEnvironment env;

  /// The resolved profile (URLs, version, defines, git state).
  final BuildProfile profile;

  /// Only for apk builds.
  final KeystoreStatus? keystore;

  /// Only for apk builds.
  final ApkSigning? signing;

  /// What was asked for.
  BuildRequest get request => profile.request;

  /// `dist/<platform folder>`, absolute.
  String get distDir => env.abs('dist/${request.platform.distDir}');

  /// Absolute path of the artifact with [extension] in [distDir].
  String distFile(String extension) =>
      env.path.join(distDir, profile.fileName(extension));

  /// Where `flutter build apk` leaves the APK.
  String get builtApk =>
      env.abs('build/app/outputs/flutter-apk/app-${request.mode.name}.apk');

  /// Where `flutter build web` leaves the site.
  String get builtWebDir => env.abs('build/web');

  /// Where `flutter build windows` leaves the runner and its DLLs.
  String get builtWindowsDir =>
      env.abs('build/windows/x64/runner/${request.mode.dirName}');

  /// Where the Inno Setup script writes the installer (OutputDir in the .iss).
  String get innoOutputDir => env.abs('build/windows/installers');

  /// Where `flutter build macos` leaves the app bundle.
  String get builtMacosApp => env.abs(
    'build/macos/Build/Products/${request.mode.dirName}/${profile.app.macosAppName}.app',
  );

  /// Marker proving what the existing output was built for (see stamp.dart).
  String get stampPath => env.abs(
    'build/build_tool/stamp-${request.platform.name}-${request.mode.name}.json',
  );
}
