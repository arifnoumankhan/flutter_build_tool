## 0.2.1

`init` now sets up the `AppEnv` class as well, so one command writes everything a new project needs.

### Added

* **`--no-app-env`** for `init`: skips the `AppEnv` class and the `main.dart` lines.
* **`AppEnv.ensureValid()`** in the generated class. In a release build it throws a `StateError` when `APP_ENV` or `BASE_URL` is empty, with a message that says to build with `dart run flutter_build_tools <platform> <env>` or to pass `--dart-define-from-file=<envDir>/<env>.json` (the `envDir` of the project's config, escaped where the file needs it). It does nothing in debug and profile builds, so a plain `flutter run` keeps working. `name`, `baseUrl`, `buildSha` and `summary` are unchanged.
* **`init` finds an `AppEnv` the project already defines.** A class, enum, mixin, extension type or typedef named `AppEnv` in any Dart file under `lib/` (`lib/config/app_env.dart` and `lib/app_env.dart` included) is left alone, also with `--force`: `init` writes no second one, lists the file as skipped and prints its import. The `main.dart` lines show only the members that file has.
* **`--force` replaces `AppEnv` only when it is the text `init` wrote** (this version's, or the one of 0.2.0; line endings do not matter). A file of the project's at its place, one that defines no `AppEnv` included, is left alone and reported, with the way to get the class (move the file, or `--no-app-env`).
* **Two notes.** A write of the class that fails says that `--no-app-env` skips it. A `lib/` folder that cannot be read completely gets a note that an existing `AppEnv` may have been missed.

### Changed

* **`init` writes `AppEnv` by default** (`lib/config/app_env.dart`, or `lib/app_env.dart` when there is no `lib/config/`), and prints the lines for `main.dart`: the import, `AppEnv.ensureValid();` and `debugPrint(AppEnv.summary);`. `--app-env` is still accepted and changes nothing; `--app-env` together with `--no-app-env` is a usage error (exit code 2), and `--no-app-env` on a build command is refused like `--app-env` and `--force`.
* **An `AppEnv` written by 0.2.0** is kept (it has no `ensureValid()`); `init` says so and how to get the new one. `--force` replaces it without calling it custom content.
* `InitOptions.appEnv` defaults to `true`.
* README: the Quick start shows `AppEnv.baseUrl`, a section describes the class, and the env files section points at `AppEnv` before `String.fromEnvironment`.

## 0.2.0

A new project needs only the dependency and `dart run flutter_build_tools init`. A project that already has a `tool/build/build_config.json` keeps its configuration and its `--help`, `--list` and `--dry-run` output.

### Added

* **`init` command** (`dart run flutter_build_tools init [--force] [--dry-run] [--app-env]`). Creates what is missing and reports what it created and skipped:
  * `tool/build/build_config.json` with the inferred facts as explicit values,
  * `config/env/{dev,preprod,prod,local}.json` with placeholder `BASE_URL`s on `.invalid` hosts that prod refuses (`local` is `http://127.0.0.1`),
  * `scripts/build.sh` (executable) and `scripts/build.ps1`, thin wrappers over `dart run flutter_build_tools`,
  * with `--app-env`, a small `AppEnv` class in `lib/config/app_env.dart` (`lib/app_env.dart` when there is no `lib/config/`) and the one-liner for `main.dart`.

  `--force` overwrites. An env file keeps every key except `APP_ENV` and `BASE_URL`, a replaced real `BASE_URL` is reported, and a script or `AppEnv` that is not init's own text is reported as `custom content replaced`. `--dry-run` writes nothing. A file the operating system refuses to write is reported with its path and exit code 1.
* **Zero-config inference.** Without `tool/build/build_config.json`, and for every key the file leaves out, the tool infers `slug` (PascalCase of the pubspec name), `displayName`, `app`, `envDir` (`config/env`), `windows.exe` (`BINARY_NAME` in `windows/CMakeLists.txt`), `windows.installerScript` (the only `installer/*.iss`) and `macos.appName` (`PRODUCT_NAME` in `AppInfo.xcconfig`). The file wins key by key. Inference is the pure function `inferProjectFacts`.
* **Placeholder guard** `placeholder-url`: a URL whose host ends in `.invalid` is a placeholder written by `init`; prod refuses it, other environments warn, and `--list` marks it.
* **`init` hints** for env file keys the config does not declare (with the `envFile.extraKeys` / `extraUrlKeys` snippet that declares them) and for config or env files that a `.gitignore` rule hides.
* **`findProjectRoot` and `runBuildToolFromDirectory`**, so project lookup can be tested without depending on the machine's folders. `AppConfig.fromFacts`, `loadAppConfig` and `loadEnvFile` are exported.

### Changed

* **`windows` and `macos` are optional** in `build_config.json` and needed only when that platform is built. A mobile-only project builds `apk` and `web`; building `windows` or `macos` stops before anything runs with an error that names the missing fact and how to set it.
* **`archive` accepts 3.6.x and 4.x** (`>=3.6.0 <5.0.0`). The web zip container is written by the tool using only `Deflate` and `getCrc32`, so the artifact is byte-for-byte the same on both majors. Entry times are the build time in UTC (previously the machine's local time, so the same build differed between time zones). A zip with more than 65535 files or 4 GiB is refused with a message.
* **A project without `build_config.json`** gets the profile line `config       inferred from the project (no tool/build/build_config.json)`, so a file that was never committed or is git-ignored is noticed.
* **First errors point at `init`** and at the Quick start in the README.
* **Web base href:** the stock `flutter create` `index.html` has `<base href="$FLUTTER_BASE_HREF">`; the profile and the deploy hint now print `/` (what Flutter fills in when no `--base-href` is passed) and say why.
* **A missing output after a build that ran** no longer suggests running without `--no-build`. For `windows` and `macos` the error names `windows.exe` or `macos.appName` and what `BINARY_NAME` / `PRODUCT_NAME` give now; `apk` and `web` say the build finished without writing the file.
* **Any other file the tool cannot read or write** is reported with its path and exit code 1 instead of an unhandled exception.
* README: a short Quick start at the top, the optional-key defaults explained, exit codes of `dart run flutter_build_tools` outside a project (Dart's own 255 before the tool starts; 2 through a shim, `dart bin/flutter_build_tools.dart` or an embedder), and a test snippet that needs only `flutter_test`.
* The `example/` files are tracked (the ignore rules for `build/` and `dist/` are anchored).

## 0.1.0

* Initial release.
* **`dart run flutter_build_tools <platform> <env> [mode] [options]`** builds `apk`, `web`, `windows` (Inno Setup, optional MSIX) and `macos` (DMG) for the environments `dev`, `preprod`, `prod` and `local`, with `--dry-run`, `--list`, `--no-build`, an interactive picker and a documented exit code contract.
* **Programmatic API:** `runBuildToolCli` (process entry) and `runBuildTool` (injectable core), with `BuildEnvironment`, `BuildFs`, `ProcessRunner` and `Console` as test seams; `AppConfig`, `EnvFile`, `EnvSchema`, the guards and the naming rule are exported for project-side tests.
* **Project facts stay in the project:** `tool/build/build_config.json` and `config/env/<env>.json`.
* **Optional `build_config.json` keys:** `devHostMarkers` (project-specific dev host names for the prod guard), `windows.cleanupPrefix` (which old installers to delete, default the slug), `envFile.extraKeys` and `envFile.extraUrlKeys` (extra env file keys; URL keys get the https and prod dev-URL guards), `cli.docs` and `cli.wrappers` (what `--help` points at).
* **Unknown keys in `build_config.json` are an error**, so a typo cannot silently disable a guard; keys starting with `$` or `_` are ignored.
* `--help` is titled with the app's `displayName` (`Flutter build tool` when there is no readable config) and works with a missing or broken config.
