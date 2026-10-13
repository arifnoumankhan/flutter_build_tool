/// Runs a build: flutter, packaging per platform, checksum and manifest. Every
/// external effect goes through the environment's file system and process
/// runner.
library;

import 'dart:convert';

import 'package:flutter_build_tools/src/commands.dart';
import 'package:flutter_build_tools/src/config.dart';
import 'package:flutter_build_tools/src/environment.dart';
import 'package:flutter_build_tools/src/git.dart';
import 'package:flutter_build_tools/src/inference.dart';
import 'package:flutter_build_tools/src/job.dart';
import 'package:flutter_build_tools/src/manifest.dart';
import 'package:flutter_build_tools/src/model.dart';
import 'package:flutter_build_tools/src/runner.dart';
import 'package:flutter_build_tools/src/sha256.dart';
import 'package:flutter_build_tools/src/stamp.dart';
import 'package:flutter_build_tools/src/web_zip.dart';

/// A finished file in `dist/`.
class Artifact {
  /// Creates the reference.
  const Artifact(this.path);

  /// Absolute path of the file.
  final String path;
}

/// The numbered steps of a build, as text, for `--dry-run`. The commands in it
/// come from the same functions the real run uses. [isccPath] is the located
/// ISCC.exe, when known.
List<String> describePlan(BuildJob job, {String? isccPath}) {
  final env = job.env;
  final request = job.request;
  final profile = job.profile;
  final steps = <String>[];
  if (request.noBuild) {
    steps.add(
      'verify ${env.rel(job.stampPath)} matches this profile (--no-build: flutter is not run)',
    );
  } else {
    steps.add('write ${profile.defineFilePath} (the defines above)');
    steps.add('\$ ${flutterBuildSpec(job).display}');
    steps.add(
      'delete ${profile.defineFilePath}, write ${env.rel(job.stampPath)}',
    );
  }
  switch (request.platform) {
    case BuildPlatform.apk:
      steps.add(
        'copy ${env.rel(job.builtApk)} -> ${env.rel(job.distFile('apk'))}',
      );
    case BuildPlatform.web:
      steps.add(
        'zip ${env.rel(job.builtWebDir)} (files at the zip root; no .DS_Store, __MACOSX, .last_build_id, *.zip) -> ${env.rel(job.distFile('zip'))}',
      );
    case BuildPlatform.windows:
      steps.add(
        '${isccPath == null ? 'locate ISCC.exe (Inno Setup 6)' : 'ISCC.exe found'}, remove old ${profile.app.installerCleanupPrefix}*.exe in ${env.rel(job.innoOutputDir)}',
      );
      steps.add(
        '\$ ${isccSpec(job, isccPath: isccPath ?? 'ISCC.exe').display}   (retried once after 3 s if it fails)',
      );
      steps.add(
        'copy ${env.rel(job.innoOutputDir)}/${profile.baseName}.exe -> ${env.rel(job.distFile('exe'))}',
      );
      if (request.msix) steps.add('\$ ${msixSpec(job).display}');
    case BuildPlatform.macos:
      for (final spec in dmgSpecs(
        job,
        stagingDir: '<temp staging folder>',
        dmgPath: env.rel(job.distFile('dmg')),
      )) {
        steps.add('\$ ${spec.display}');
      }
  }
  steps.add(
    'write <artifact>.sha256 and <artifact>.json next to each artifact',
  );
  return steps;
}

/// Runs [job] for real and returns the artifacts it produced in `dist/`, each
/// with its `.sha256` and `.json` sidecar.
Future<List<Artifact>> executeJob(BuildJob job) async {
  final env = job.env;
  final request = job.request;
  final console = env.console;

  final iscc = request.platform == BuildPlatform.windows
      ? prepareWindows(job)
      : null;
  final flutterVersion = await _flutterVersion(job);

  final BuildStamp stamp;
  if (request.noBuild) {
    stamp = verifiedStamp(job);
    console.out(
      '==> --no-build: re-packaging the existing output (built ${stamp.builtAt}, ${stamp.gitSha})',
    );
  } else {
    // A failed or interrupted build must not leave a stamp that vouches for
    // half-written output.
    env.fs.deleteFile(job.stampPath);
    await _flutterBuild(job);
    stamp = BuildStamp.of(job.profile);
    env.fs.writeString(
      job.stampPath,
      '${const JsonEncoder.withIndent('  ').convert(stamp.toJson())}\n',
    );
  }

  env.fs.createDir(job.distDir);
  final artifacts = switch (request.platform) {
    BuildPlatform.apk => [_packageApk(job)],
    BuildPlatform.web => [_packageWeb(job)],
    BuildPlatform.windows => await _packageWindows(job, iscc!),
    BuildPlatform.macos => [await _packageMacos(job)],
  };
  for (final artifact in artifacts) {
    await _finalize(
      job,
      artifact,
      flutterVersion: flutterVersion,
      git: stamp.git,
      builtAt: stamp.builtAt,
    );
  }
  if (request.platform == BuildPlatform.web) _printDeployHint(job);
  return artifacts;
}

Future<String> _flutterVersion(BuildJob job) async {
  final env = job.env;
  try {
    final result = await env.runner.capture(flutterVersionSpec(env));
    final parsed = result.exitCode == 0
        ? parseFlutterVersion(result.stdout)
        : null;
    if (parsed != null) return parsed;
    if (!job.request.noBuild) {
      throw BuildException(
        '"flutter --version --machine" failed (exit ${result.exitCode}). Fix the Flutter installation first.',
      );
    }
  } on ProcessStartException catch (e) {
    if (!job.request.noBuild) {
      throw BuildException(
        '$e. Install Flutter and make sure "flutter" is on PATH.',
      );
    }
  }
  env.console.out(
    'warning: could not read the Flutter version; the manifest will say "unknown".',
  );
  return 'unknown';
}

/// `--no-build` is only safe when the existing output was built for exactly
/// this profile. Throws [BuildException] otherwise.
BuildStamp verifiedStamp(BuildJob job) {
  final env = job.env;
  final shown = env.rel(job.stampPath);
  final remedy = 'Run the same command without --no-build.';
  if (!env.fs.fileExists(job.stampPath)) {
    throw BuildException(
      '--no-build: no build stamp at $shown, so there is no proof the existing output was built for ${job.request.env.name}. $remedy',
    );
  }
  final stamp = BuildStamp.tryParse(env.fs.readString(job.stampPath));
  if (stamp == null) {
    throw BuildException(
      '--no-build: the build stamp $shown is unreadable. $remedy',
    );
  }
  final differences = stamp.differencesFrom(job.profile);
  if (differences.isNotEmpty) {
    throw BuildException(
      '--no-build: the existing output does not match this profile (${differences.join('; ')}). $remedy',
    );
  }
  return stamp;
}

Future<void> _flutterBuild(BuildJob job) async {
  final env = job.env;
  final profile = job.profile;
  final spec = flutterBuildSpec(job);
  final defineFile = env.abs(profile.defineFilePath);
  // Flutter hashes every define (and build name/number) into a folder under
  // .dart_tool/flutter_build/ and never prunes it. profile.defines must stay
  // identical between two runs of the same commit and env (no timestamp), or
  // every build adds 100-230 MB and none is incremental.
  env.fs.writeString(
    defineFile,
    '${const JsonEncoder.withIndent('  ').convert(profile.defines)}\n',
  );
  try {
    env.console.out('==> ${spec.display}');
    final code = await env.runner.stream(spec);
    if (code != 0) {
      throw BuildException(
        'flutter build ${job.request.platform.flutterTarget} failed (exit $code). Fix the errors above and re-run.',
      );
    }
  } on ProcessStartException catch (e) {
    throw BuildException(
      '$e. Install Flutter and make sure "flutter" is on PATH.',
    );
  } finally {
    env.fs.deleteFile(defineFile);
  }
}

/// Streams [spec] and throws [BuildException] unless it exits 0.
Future<void> _mustRun(
  BuildEnvironment env,
  ProcessSpec spec,
  String failure,
) async {
  env.console.out('==> ${spec.display}');
  final int code;
  try {
    code = await env.runner.stream(spec);
  } on ProcessStartException catch (e) {
    throw BuildException('$e. $failure');
  }
  if (code != 0) {
    throw BuildException('${spec.executable} failed (exit $code). $failure');
  }
}

/// How a "not found" error ends. After `--no-build` the output may simply
/// never have been built, so the remedy is to build; after a build that just
/// ran, "run without --no-build" would be wrong advice, and [afterBuild] says
/// what to look at instead.
String _outputMissingTail(BuildJob job, String afterBuild) =>
    job.request.noBuild ? 'Run without --no-build.' : afterBuild;

/// Why a platform's output is missing after the build ran, when the name
/// that was expected comes from [key] in `build_config.json`: when the project
/// now says something else ([inferred], from [source]) the pinned value is
/// stale, which is what `init` writes out and a rename of the project makes
/// wrong.
String _staleFactTail({
  required String key,
  required String configured,
  required String? inferred,
  required String source,
}) {
  if (inferred != null && inferred != configured) {
    return 'The Flutter build finished, but "$key" ("$configured") does not match the project: $source now gives "$inferred". Set "$key" to "$inferred" in ${AppConfig.configPath}, or delete the key there to follow the project.';
  }
  return 'The Flutter build finished without writing it. Check "$key" ("$configured") in ${AppConfig.configPath} against $source.';
}

Artifact _packageApk(BuildJob job) {
  final env = job.env;
  if (!env.fs.fileExists(job.builtApk)) {
    throw BuildException(
      'APK not found at ${env.rel(job.builtApk)} (expected build mode ${job.request.mode.name}). ${_outputMissingTail(job, 'The Flutter build finished without writing it; Android flavors and a moved output folder are not supported (see "Known limits" in the flutter_build_tools README).')}',
    );
  }
  final target = job.distFile('apk');
  env.fs.copyFile(job.builtApk, target);
  return Artifact(target);
}

Artifact _packageWeb(BuildJob job) {
  final env = job.env;
  if (!env.fs.fileExists(env.path.join(job.builtWebDir, 'index.html'))) {
    throw BuildException(
      'Web build not found at ${env.rel(job.builtWebDir)} (expected build mode ${job.request.mode.name}). ${_outputMissingTail(job, 'The Flutter build finished without writing index.html there.')}',
    );
  }
  final target = job.distFile('zip');
  env.console.out('==> zip ${env.rel(job.builtWebDir)} -> ${env.rel(target)}');
  env.fs.writeBytes(
    target,
    buildWebZip(
      fs: env.fs,
      path: env.path,
      webDir: job.builtWebDir,
      modified: env.now(),
    ),
  );
  return Artifact(target);
}

void _printDeployHint(BuildJob job) {
  final env = job.env;
  final indexHtml = env.abs('web/index.html');
  final href = env.fs.fileExists(indexHtml)
      ? servedBaseHref(parseBaseHref(env.fs.readString(indexHtml)))
      : null;
  env.console.out('');
  env.console.out(
    "Deploy: extract into the folder served at '${href ?? '/'}' (replace old files),",
  );
  env.console.out(
    'then purge the CDN/Cloudflare cache if used. index.html and',
  );
  env.console.out('flutter_service_worker.js must not be long-cached.');
}

/// Checks everything the Windows packaging needs before the long Flutter
/// build starts, and returns the ISCC.exe path. Throws [BuildException].
String prepareWindows(BuildJob job) {
  final env = job.env;
  final script = env.abs(job.profile.app.installerScript);
  if (!env.fs.fileExists(script)) {
    throw BuildException(
      'Missing Inno Setup script ${env.rel(script)}. Create it (the "windows" section of the flutter_build_tools README has the contract, and example/installer/example_app.iss is a template), or point "windows.installerScript" at your script in ${AppConfig.configPath} ("dart run flutter_build_tools init" writes that file; see the "Quick start" section of the README).',
    );
  }
  if (job.request.mode != BuildMode.release &&
      !env.fs.readString(script).contains('MyBuildMode')) {
    throw BuildException(
      '${env.rel(script)} always packages the Release folder (no MyBuildMode define). '
      'Add the MyBuildMode handling (see the Inno Setup section of the flutter_build_tools README) or build release.',
    );
  }
  if (job.request.msix &&
      !RegExp(
        r'^\s*msix\s*:',
        multiLine: true,
      ).hasMatch(env.fs.readString(env.abs('pubspec.yaml')))) {
    throw BuildException(
      '--msix needs the msix package in pubspec.yaml dev_dependencies (see the flutter_build_tools README).',
    );
  }
  final iscc = locateIscc(env);
  if (iscc == null) {
    throw BuildException(
      'ISCC.exe not found. Install Inno Setup 6 (winget install JRSoftware.InnoSetup).',
    );
  }
  return iscc;
}

Future<List<Artifact>> _packageWindows(BuildJob job, String iscc) async {
  final env = job.env;
  final console = env.console;
  final exe = env.path.join(job.builtWindowsDir, job.profile.app.windowsExe);
  if (!env.fs.fileExists(exe)) {
    final afterBuild = _staleFactTail(
      key: 'windows.exe',
      configured: job.profile.app.windowsExe,
      inferred: inferProjectFacts(
        fs: env.fs,
        path: env.path,
        root: env.root,
      ).windowsExe,
      source: 'BINARY_NAME in windows/CMakeLists.txt',
    );
    throw BuildException(
      'Missing ${env.rel(exe)}. ${_outputMissingTail(job, afterBuild)}',
    );
  }

  env.fs.createDir(job.innoOutputDir);
  final spec = isccSpec(job, isccPath: iscc);
  _clearOldInstallers(job);
  console.out('==> ${spec.display}');
  var code = await _isccExit(env, spec);
  if (code != 0) {
    console.out(
      '==> Inno Setup failed (exit $code). Retrying once after a short wait...',
    );
    await env.sleep(const Duration(seconds: 3));
    _clearOldInstallers(job);
    code = await _isccExit(env, spec);
  }
  if (code != 0) {
    throw BuildException(
      'Inno Setup compile failed (exit $code). If an antivirus holds a lock, exclude ${env.rel(job.innoOutputDir)} and retry.',
    );
  }

  final built = env.path.join(job.innoOutputDir, '${job.profile.baseName}.exe');
  if (!env.fs.fileExists(built)) {
    throw BuildException(
      'Inno Setup finished but ${env.rel(built)} is missing. '
      '${job.profile.app.installerScript} must use OutputBaseFilename={#MyOutputName}.',
    );
  }
  final target = job.distFile('exe');
  env.fs.copyFile(built, target);
  final artifacts = [Artifact(target)];

  if (job.request.msix) {
    await _mustRun(
      env,
      msixSpec(job),
      'Fix the msix error above, or build without --msix.',
    );
    final msix = job.distFile('msix');
    if (!env.fs.fileExists(msix)) {
      throw BuildException(
        'msix:create finished but ${env.rel(msix)} is missing.',
      );
    }
    artifacts.add(Artifact(msix));
  }
  return artifacts;
}

Future<int> _isccExit(BuildEnvironment env, ProcessSpec spec) async {
  try {
    return await env.runner.stream(spec);
  } on ProcessStartException catch (e) {
    throw BuildException('$e.');
  }
}

/// Removes installers left in the Inno output folder (legacy and new names)
/// so a stale one is never mistaken for the fresh build.
void _clearOldInstallers(BuildJob job) {
  final env = job.env;
  final prefix = job.profile.app.installerCleanupPrefix;
  for (final file in env.fs.listFiles(job.innoOutputDir)) {
    final name = env.path.basename(file);
    if (name.startsWith(prefix) && name.toLowerCase().endsWith('.exe')) {
      env.console.out('==> Remove old installer: $name');
      env.fs.deleteFile(file);
    }
  }
}

Future<Artifact> _packageMacos(BuildJob job) async {
  final env = job.env;
  if (!env.fs.dirExists(job.builtMacosApp)) {
    final afterBuild = _staleFactTail(
      key: 'macos.appName',
      configured: job.profile.app.macosAppName,
      inferred: inferProjectFacts(
        fs: env.fs,
        path: env.path,
        root: env.root,
      ).macosAppName,
      source: 'PRODUCT_NAME in macos/Runner/Configs/AppInfo.xcconfig',
    );
    throw BuildException(
      'App bundle not found at ${env.rel(job.builtMacosApp)} (expected build mode ${job.request.mode.name}). ${_outputMissingTail(job, afterBuild)}',
    );
  }
  final target = job.distFile('dmg');
  final staging = env.fs.createTempDir(
    '${job.profile.app.slug.toLowerCase()}_dmg_',
  );
  try {
    for (final spec in dmgSpecs(job, stagingDir: staging, dmgPath: target)) {
      await _mustRun(env, spec, 'Could not create the DMG.');
    }
  } finally {
    env.fs.deleteDir(staging);
  }
  if (!env.fs.fileExists(target)) {
    throw BuildException('hdiutil finished but ${env.rel(target)} is missing.');
  }
  return Artifact(target);
}

Future<void> _finalize(
  BuildJob job,
  Artifact artifact, {
  required String flutterVersion,
  required GitInfo git,
  required String builtAt,
}) async {
  final env = job.env;
  final fileName = env.path.basename(artifact.path);
  final size = env.fs.length(artifact.path);
  final sha = await Sha256.hexOfStream(env.fs.openRead(artifact.path));
  final shaPath = '${artifact.path}.sha256';
  final manifestPath = '${artifact.path}.json';
  env.fs.writeString(shaPath, sha256Line(sha, fileName));
  env.fs.writeString(
    manifestPath,
    manifestJson(
      job: job,
      fileName: fileName,
      sizeBytes: size,
      sha256: sha,
      flutterVersion: flutterVersion,
      git: git,
      builtAt: builtAt,
    ),
  );
  env.console
    ..out('')
    ..out('OK  $fileName')
    ..out('    Path:     ${artifact.path}')
    ..out('    Size:     ${formatSize(size)}')
    ..out('    SHA256:   $sha')
    ..out('    Manifest: $manifestPath');
}

/// `12.3 MB (12886016 bytes)`, or `512 bytes`.
String formatSize(int bytes) {
  const units = ['B', 'KB', 'MB', 'GB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  if (unit == 0) return '$bytes bytes';
  return '${value.toStringAsFixed(1)} ${units[unit]} ($bytes bytes)';
}
