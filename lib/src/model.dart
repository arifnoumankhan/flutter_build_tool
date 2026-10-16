/// Value types shared by every part of the build tool.
library;

/// Operating system the tool itself runs on. Flutter cannot cross-build the
/// desktop targets, so this decides which targets are buildable.
enum HostOs {
  /// macOS (builds `macos`).
  macos,

  /// Windows (builds `windows`).
  windows,

  /// Linux and everything else (builds only `apk` and `web`).
  linux;

  /// Maps `Platform.operatingSystem` to a [HostOs]; unknown names are [linux].
  static HostOs fromDartName(String operatingSystem) =>
      switch (operatingSystem) {
        'macos' => HostOs.macos,
        'windows' => HostOs.windows,
        _ => HostOs.linux,
      };
}

/// What to build. [distDir] is the folder under `dist/`, [extension] the
/// extension of the primary artifact.
enum BuildPlatform {
  /// Android package; lands in `dist/android/`.
  apk('android', 'apk'),

  /// Web site zipped for deployment; lands in `dist/web/`.
  web('web', 'zip'),

  /// Windows installer (Inno Setup); lands in `dist/windows/`.
  windows('windows', 'exe'),

  /// macOS disk image; lands in `dist/macos/`.
  macos('macos', 'dmg');

  const BuildPlatform(this.distDir, this.extension);

  /// Folder under `dist/` that holds this platform's artifacts.
  final String distDir;

  /// Extension of the primary artifact (without the dot).
  final String extension;

  /// The `flutter build <target>` argument.
  String get flutterTarget => name;

  /// Accepts the platform name and the aliases `exe` (windows) and `dmg`
  /// (macos). Returns null for anything else.
  static BuildPlatform? parse(String input) =>
      switch (input.trim().toLowerCase()) {
        'apk' => BuildPlatform.apk,
        'web' => BuildPlatform.web,
        'windows' || 'exe' => BuildPlatform.windows,
        'macos' || 'dmg' => BuildPlatform.macos,
        _ => null,
      };

  /// Platforms Flutter can build on [host].
  static List<BuildPlatform> availableOn(HostOs host) => [
    BuildPlatform.apk,
    BuildPlatform.web,
    if (host == HostOs.windows) BuildPlatform.windows,
    if (host == HostOs.macos) BuildPlatform.macos,
  ];
}

/// Which server the binary talks to.
enum BuildEnv {
  /// The shared development server.
  dev,

  /// The pre-production server.
  preprod,

  /// Production: the strictest guards apply.
  prod,

  /// A server on the developer's machine; the only env that may use http.
  local;

  /// True for [local].
  bool get isLocal => this == BuildEnv.local;

  /// True for [prod].
  bool get isProd => this == BuildEnv.prod;

  /// Case-insensitive lookup by name; null when it is not an environment.
  static BuildEnv? parse(String input) {
    final wanted = input.trim().toLowerCase();
    for (final env in BuildEnv.values) {
      if (env.name == wanted) return env;
    }
    return null;
  }
}

/// Flutter build mode. [nameSuffix] goes into the artifact name, [dirName] is
/// the folder Flutter uses for desktop outputs (Release, Debug, Profile).
enum BuildMode {
  /// The default; adds nothing to the artifact name.
  release('', 'Release'),

  /// Adds `-debug` to the artifact name.
  debug('-debug', 'Debug'),

  /// Adds `-profile` to the artifact name.
  profile('-profile', 'Profile');

  const BuildMode(this.nameSuffix, this.dirName);

  /// Appended to the artifact base name (empty for release).
  final String nameSuffix;

  /// Folder name Flutter uses for desktop outputs.
  final String dirName;

  /// The flag passed to `flutter build`, for example `--release`.
  String get flutterFlag => '--$name';

  /// Case-insensitive lookup by name; null when it is not a mode.
  static BuildMode? parse(String input) {
    final wanted = input.trim().toLowerCase();
    for (final mode in BuildMode.values) {
      if (mode.name == wanted) return mode;
    }
    return null;
  }
}

/// Everything the user asked for on the command line (or in the picker).
class BuildRequest {
  /// Creates a request; everything but [platform] and [env] is optional.
  const BuildRequest({
    required this.platform,
    required this.env,
    this.mode = BuildMode.release,
    this.baseUrlOverride,
    this.envFilePath,
    this.versionOverride,
    this.buildNumberOverride,
    this.noBuild = false,
    this.releaseSigning = false,
    this.allowDirty = false,
    this.allowProdOverride = false,
    this.allowProdDebug = false,
    this.dryRun = false,
    this.msix = false,
  });

  /// What to build.
  final BuildPlatform platform;

  /// Which server the binary talks to.
  final BuildEnv env;

  /// Flutter build mode (default release).
  final BuildMode mode;

  /// `--base-url`: replaces `BASE_URL` for this build only.
  final String? baseUrlOverride;

  /// `--env-file`: another env JSON, absolute or relative to the project.
  final String? envFilePath;

  /// `--version`: replaces the pubspec version in the name and the binary.
  final String? versionOverride;

  /// `--build-number`: replaces the `+N` of the pubspec.
  final int? buildNumberOverride;

  /// `--no-build`: re-package the existing output.
  final bool noBuild;

  /// `--release-signing`: sign an apk with the release keystore.
  final bool releaseSigning;

  /// `--allow-dirty`: let prod build from a dirty git tree.
  final bool allowDirty;

  /// `--allow-prod-override`: let prod take `--base-url` / `--env-file`.
  final bool allowProdOverride;

  /// `--allow-prod-debug`: let prod build in debug mode (still refuses profile).
  final bool allowProdDebug;

  /// `--dry-run`: print the plan, build nothing.
  final bool dryRun;

  /// `--msix`: also build an MSIX package (windows, release only).
  final bool msix;

  /// True when the profile does not come purely from the committed env file.
  bool get overridesProfile => baseUrlOverride != null || envFilePath != null;
}

/// A failure the user can fix. The message says what to do. Exit code 1.
class BuildException implements Exception {
  /// Creates the exception; [message] is shown to the person as it is.
  BuildException(this.message);

  /// What went wrong and what to do about it.
  final String message;

  @override
  String toString() => message;
}

/// A bad command line. Exit code 2.
class UsageError implements Exception {
  /// Creates the exception; [message] is shown to the person as it is.
  UsageError(this.message);

  /// What was wrong with the command line and one example of a good one.
  final String message;

  @override
  String toString() => message;
}
