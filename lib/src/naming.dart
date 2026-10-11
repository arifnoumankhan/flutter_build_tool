/// Artifact naming: `<Slug>-<env>-v<version><suffix>.<ext>`, e.g.
/// `ExampleApp-preprod-v1.0.47.exe` or `ExampleApp-dev-v1.0.47-debug.apk`.
library;

import 'package:flutter_build_tools/src/model.dart';

/// File name without extension.
String artifactBaseName({
  required String slug,
  required BuildEnv env,
  required String version,
  required BuildMode mode,
}) => '$slug-${env.name}-v$version${mode.nameSuffix}';

/// File name with the extension: [artifactBaseName] plus `.<extension>`.
String artifactFileName({
  required String slug,
  required BuildEnv env,
  required String version,
  required BuildMode mode,
  required String extension,
}) =>
    '${artifactBaseName(slug: slug, env: env, version: version, mode: mode)}.$extension';
