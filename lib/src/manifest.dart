/// Build manifest (`<artifact>.json`) and checksum (`<artifact>.sha256`) written
/// next to every artifact.
library;

import 'dart:convert';

import 'package:flutter_build_tools/src/git.dart';
import 'package:flutter_build_tools/src/job.dart';

/// `<hash>  <file name>` followed by a newline: the `sha256sum` format, so
/// `shasum -a 256 -c <artifact>.sha256` works inside the folder.
String sha256Line(String sha256, String fileName) => '$sha256  $fileName\n';

/// The manifest as JSON text (2-space indent, trailing newline).
String manifestJson({
  required BuildJob job,
  required String fileName,
  required int sizeBytes,
  required String sha256,
  required String flutterVersion,
  required GitInfo git,
  required String builtAt,
}) {
  final profile = job.profile;
  final request = job.request;
  final manifest = <String, Object?>{
    'schema': 1,
    'app': profile.app.app,
    'env': request.env.name,
    'platform': request.platform.name,
    'mode': request.mode.name,
    'version': profile.version,
    'buildNumber': profile.buildNumber,
    'baseUrl': profile.baseUrl,
    'posWebUrl': ?profile.posWebUrl,
    if (profile.extraUrls.isNotEmpty) 'extraUrls': profile.extraUrls,
    if (profile.extraDefines.isNotEmpty) 'extraDefines': profile.extraDefines,
    'git': {'sha': git.sha, 'dirty': git.dirty},
    'flutter': flutterVersion,
    'builtAt': builtAt,
    'hostOs': job.env.host.name,
    'file': fileName,
    'sizeBytes': sizeBytes,
    'sha256': sha256,
    'signing': ?job.signing?.kind,
  };
  return '${const JsonEncoder.withIndent('  ').convert(manifest)}\n';
}
