/// Composition of the external commands the tool runs. Pure functions of the
/// job, shared by the real run and by `--dry-run`, so what is printed is what
/// is executed.
library;

import 'dart:convert';

import 'package:flutter_build_tools/src/environment.dart';
import 'package:flutter_build_tools/src/job.dart';
import 'package:flutter_build_tools/src/model.dart';
import 'package:flutter_build_tools/src/runner.dart';

/// `flutter --version --machine`, for the Flutter version in the manifest.
ProcessSpec flutterVersionSpec(BuildEnvironment env) => ProcessSpec(
  'flutter',
  const ['--version', '--machine'],
  workingDirectory: env.root,
  shell: env.host == HostOs.windows,
);

/// `flutter build <platform> --<mode> --dart-define-from-file=... --build-name=...`.
ProcessSpec flutterBuildSpec(BuildJob job) {
  final profile = job.profile;
  final request = job.request;
  final number = profile.buildNumber;
  return ProcessSpec(
    'flutter',
    [
      'build',
      request.platform.flutterTarget,
      request.mode.flutterFlag,
      '--dart-define-from-file=${profile.defineFilePath}',
      '--build-name=${profile.version}',
      if (number != null) '--build-number=$number',
      if (job.signing?.passGradleFlag ?? false) ...[
        '-P',
        'useReleaseSigning=true',
      ],
    ],
    workingDirectory: job.env.root,
    shell: job.env.host == HostOs.windows,
  );
}

/// Inno Setup compile. `/DMyOutputName` names the installer, `/DMyBuildMode`
/// (non-release only) selects which Flutter output folder gets packaged.
ProcessSpec isccSpec(BuildJob job, {required String isccPath}) =>
    ProcessSpec(isccPath, [
      '/DMyAppVersion=${job.profile.version}',
      '/DMyOutputName=${job.profile.baseName}',
      if (job.request.mode != BuildMode.release)
        '/DMyBuildMode=${job.request.mode.dirName}',
      job.env.abs(job.profile.app.installerScript),
    ], workingDirectory: job.env.root);

/// `dart run msix:create` on top of the Flutter build that already ran with
/// the defines (`--build-windows false`), written straight into dist/windows.
ProcessSpec msixSpec(BuildJob job) => ProcessSpec(
  'dart',
  [
    'run',
    'msix:create',
    '--build-windows',
    'false',
    '--install-certificate',
    'false',
    '--version',
    '${job.profile.version}.0',
    '--output-path',
    'dist/${BuildPlatform.windows.distDir}',
    '--output-name',
    job.profile.baseName,
  ],
  workingDirectory: job.env.root,
  shell: job.env.host == HostOs.windows,
);

/// The three commands that turn the .app into a DMG: stage it next to an
/// /Applications link, then compress with hdiutil.
List<ProcessSpec> dmgSpecs(
  BuildJob job, {
  required String stagingDir,
  required String dmgPath,
}) => [
  ProcessSpec('cp', ['-R', job.builtMacosApp, '$stagingDir/']),
  ProcessSpec('ln', ['-s', '/Applications', '$stagingDir/Applications']),
  ProcessSpec('hdiutil', [
    'create',
    '-volname',
    job.profile.app.displayName,
    '-srcfolder',
    stagingDir,
    '-ov',
    '-format',
    'UDZO',
    dmgPath,
  ]),
];

/// `3.47.0 (stable)` out of `flutter --version --machine`, or null.
String? parseFlutterVersion(String machineOutput) {
  final start = machineOutput.indexOf('{');
  final end = machineOutput.lastIndexOf('}');
  if (start == -1 || end < start) return null;
  try {
    final decoded = jsonDecode(machineOutput.substring(start, end + 1));
    if (decoded is! Map<String, Object?>) return null;
    final version = decoded['frameworkVersion'];
    final channel = decoded['channel'];
    if (version is! String) return null;
    return channel is String ? '$version ($channel)' : version;
  } on FormatException {
    return null;
  }
}

/// Inno Setup 6 locations, in the order the old PowerShell scripts tried them.
List<String> isccCandidates(BuildEnvironment env) => [
  for (final (variable, folder) in [
    ('LOCALAPPDATA', 'Programs'),
    ('ProgramFiles(x86)', ''),
    ('ProgramFiles', ''),
  ])
    if (_envVar(env, variable) case final base?)
      env.path.joinAll([
        base,
        if (folder.isNotEmpty) folder,
        'Inno Setup 6',
        'ISCC.exe',
      ]),
];

/// Finds ISCC.exe: the usual folders first, then a search of the program
/// folders. Null when Inno Setup is not installed.
String? locateIscc(BuildEnvironment env) {
  for (final candidate in isccCandidates(env)) {
    if (env.fs.fileExists(candidate)) return candidate;
  }
  for (final variable in [
    'ProgramFiles(x86)',
    'ProgramFiles',
    'LOCALAPPDATA',
  ]) {
    final base = _envVar(env, variable);
    if (base == null) continue;
    final found = env.fs.findFile(base, 'ISCC.exe');
    if (found != null) return found;
  }
  return null;
}

String? _envVar(BuildEnvironment env, String name) {
  for (final entry in env.vars.entries) {
    if (entry.key.toLowerCase() == name.toLowerCase() &&
        entry.value.isNotEmpty) {
      return entry.value;
    }
  }
  return null;
}
