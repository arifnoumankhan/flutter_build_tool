/// Stages a Flutter Linux bundle as an AppDir and builds an AppImage.
library;

import 'package:path/path.dart' as p;

import 'package:flutter_build_tools/src/environment.dart';
import 'package:flutter_build_tools/src/fs.dart';
import 'package:flutter_build_tools/src/inference.dart';
import 'package:flutter_build_tools/src/job.dart';
import 'package:flutter_build_tools/src/model.dart';
import 'package:flutter_build_tools/src/runner.dart';

/// Relative path of the Flutter runner inside the Linux bundle, or null.
String? linuxBundleBinaryName({
  required BuildFs fs,
  required String root,
}) {
  final cmakePath = '$root/linux/CMakeLists.txt';
  if (!fs.fileExists(cmakePath)) return null;
  return windowsBinaryName(fs.readString(cmakePath));
}

/// Desktop entry for the AppImage.
String appImageDesktopEntry({
  required String name,
  required String binary,
  required String iconStem,
}) =>
    '[Desktop Entry]\n'
    'Type=Application\n'
    'Name=$name\n'
    'Exec=$binary\n'
    'Icon=$iconStem\n'
    'Categories=Development;\n'
    'Terminal=false\n';

/// Copies every file under [fromDir] into [toDir], preserving relative paths.
void copyTree({
  required BuildFs fs,
  required p.Context path,
  required String fromDir,
  required String toDir,
}) {
  for (final file in fs.listFiles(fromDir, recursive: true)) {
    final relative = path.split(path.relative(file, from: fromDir)).join('/');
    fs.copyFile(file, path.join(toDir, relative));
  }
}

/// Finds a PNG icon under the project, preferring web icons.
String? findAppImageIcon({
  required BuildFs fs,
  required p.Context path,
  required String root,
}) {
  for (final candidate in [
    'web/icons/Icon-192.png',
    'web/favicon.png',
  ]) {
    final abs = path.join(root, candidate);
    if (fs.fileExists(abs)) return abs;
  }
  return fs.findFile(path.join(root, 'web'), 'Icon-192.png') ??
      fs.findFile(path.join(root, 'web'), 'favicon.png');
}

/// Builds AppDir under [appDir] from [bundle] (binary + lib + data, desktop,
/// icon). Call [appRunSymlinkSpec] next, then run the returned appimagetool
/// [ProcessSpec].
ProcessSpec stageLinuxAppDir({
  required BuildEnvironment env,
  required BuildJob job,
  required String bundle,
  required String appDir,
  required String appImagePath,
  required String binaryName,
}) {
  final fs = env.fs;
  final path = env.path;
  final binDir = path.join(appDir, 'usr', 'bin');
  fs.createDir(binDir);
  final runner = path.join(bundle, binaryName);
  if (!fs.fileExists(runner)) {
    throw BuildException(
      'Linux bundle binary not found at ${env.rel(runner)}.',
    );
  }
  fs.copyFile(runner, path.join(binDir, binaryName));
  for (final folder in ['lib', 'data']) {
    final from = path.join(bundle, folder);
    if (fs.dirExists(from)) {
      copyTree(
        fs: fs,
        path: path,
        fromDir: from,
        toDir: path.join(binDir, folder),
      );
    }
  }

  fs.writeString(
    path.join(appDir, '$binaryName.desktop'),
    appImageDesktopEntry(
      name: job.profile.app.displayName,
      binary: binaryName,
      iconStem: binaryName,
    ),
  );

  final icon = findAppImageIcon(fs: fs, path: path, root: env.root);
  if (icon != null) {
    fs.copyFile(icon, path.join(appDir, '$binaryName.png'));
  } else {
    fs.writeBytes(path.join(appDir, '$binaryName.png'), _onePixelPng);
  }

  return ProcessSpec('appimagetool', [
    '--no-appstream',
    appDir,
    appImagePath,
  ]);
}

/// Symlink `AppRun` → `usr/bin/<binary>` inside [appDir].
ProcessSpec appRunSymlinkSpec({
  required String appDir,
  required String binaryName,
}) => ProcessSpec('ln', [
  '-sfn',
  'usr/bin/$binaryName',
  '$appDir/AppRun',
]);

/// Tiny valid PNG (1×1 transparent) when the project has no icon file.
final List<int> _onePixelPng = [
  0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d,
  0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1f, 0x15, 0xc4, 0x89, 0x00, 0x00, 0x00,
  0x0a, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9c, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0d, 0x0a, 0x2d, 0xb4, 0x00, 0x00, 0x00, 0x00, 0x49,
  0x45, 0x4e, 0x44, 0xae, 0x42, 0x60, 0x82,
];
