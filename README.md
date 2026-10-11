# flutter_build_tools

One command builds a Flutter app for any platform and any environment, and
the file name says exactly what is inside:

```bash
dart run flutter_build_tools apk release preprod
#   -> dist/android/ExampleApp-preprod-v1.0.47.apk   (+ .sha256, + .json manifest)
dart run flutter_build_tools web release dev
#   -> dist/web/ExampleApp-dev-v1.0.47.zip
dart run flutter_build_tools windows release prod        # on a Windows machine
#   -> dist/windows/ExampleApp-prod-v1.0.47.exe
```

It is a pure Dart package (no Flutter SDK dependency), so it runs from any
Flutter project that lists it as a dev dependency. Everything that differs
between projects (name, installer, extra guard hints) lives in the project, in
`tool/build/build_config.json` and `config/env/<env>.json`; the tool itself is
the same for every app.

What you get over a hand-written `flutter build` script:

- **Environments are committed files**, not constants edited before a build.
  The tool compiles one file per environment into the binary with
  `--dart-define-from-file`.
- **Guards that fail before the build starts**: a prod build refuses a dev or
  localhost URL, a dirty git tree, a debug mode and an overridden profile; a
  prod apk refuses a missing release keystore.
- **Deterministic artifact names** (`<Slug>-<env>-v<version>[-debug].<ext>`),
  a `.sha256` file in `sha256sum` format and a JSON build manifest next to
  every artifact.
- **`--dry-run`** prints the resolved profile, the exact commands and the guard
  verdict, and builds nothing.
- **Testable**: the tool reaches the outside world only through
  `BuildEnvironment` (file system, process runner, console, clock, host OS).

## Contents

1. [Requirements](#requirements)
2. [Install](#install)
3. [Quick start](#quick-start)
4. [Command line reference](#command-line-reference)
5. [`build_config.json`](#build_configjson)
6. [Env files](#env-files)
7. [Artifact names, checksums, manifest](#artifact-names-checksums-and-manifest)
8. [Guards](#guards)
9. [Per platform](#per-platform)
10. [`--no-build` and the build stamp](#--no-build-and-the-build-stamp)
11. [CI](#ci)
12. [Embedding it](#embedding-it)
13. [Extending it](#extending-it)
14. [Known limits](#known-limits)
15. [Development](#development)

## Requirements

| Needed | For |
|---|---|
| Dart `^3.8.0` | the tool itself |
| `flutter` on `PATH` | every real build (`--help`, `--list` and `--dry-run` do not run Flutter) |
| `git` (optional) | `BUILD_SHA` and the clean-tree guard. Without it `BUILD_SHA` is `unknown` and prod refuses to build because it cannot prove the tree is clean |
| `android/key.properties` | a release-signed apk (see [apk](#apk)) |
| Windows host + [Inno Setup 6](https://jrsoftware.org/isinfo.php) (`winget install JRSoftware.InnoSetup`) | the `windows` target |
| macOS host (`hdiutil`, `cp`, `ln`) | the `macos` target |
| the [`msix`](https://pub.dev/packages/msix) package in `dev_dependencies` | `--msix` only |

Flutter cannot cross-build desktop apps, so `windows` on a Mac (or `macos` on
Windows) is refused with a message that says where to run it. `apk` and `web`
build everywhere.

## Install

The package is not on pub.dev. Add it as a development dependency of the app,
pinned to a release tag:

```yaml
# pubspec.yaml of the app
dev_dependencies:
  flutter_build_tools:
    git:
      url: https://github.com/arifnoumankhan/flutter_build_tool.git
      ref: v0.1.0
```

Then run `flutter pub get` in the app. Until you do, `dart run
flutter_build_tools` answers "Couldn't resolve the package". To upgrade, move
`ref` to a newer tag (see `CHANGELOG.md`) and run `flutter pub upgrade
flutter_build_tools`.

To work on the tool and an app side by side, keep the committed pubspec on the
tag and point at your checkout in a per-machine, git-ignored
`pubspec_overrides.yaml`:

```yaml
dependency_overrides:
  flutter_build_tools:
    path: ../flutter_build_tool
```

## Quick start

A project needs three things.

**1. The project's facts**, `tool/build/build_config.json`:

```json
{
  "app": "example",
  "slug": "ExampleApp",
  "displayName": "Example App",
  "envDir": "config/env",
  "windows": {
    "exe": "example_app.exe",
    "installerScript": "installer/example_app.iss"
  },
  "macos": { "appName": "Example App" }
}
```

**2. One env file per environment**, `config/env/dev.json`, `preprod.json`,
`prod.json`, `local.json`:

```json
{
  "APP_ENV": "preprod",
  "BASE_URL": "https://preprod.example.com/api"
}
```

**3. A pubspec with a version** (`version: 1.0.47+47`).

Then look first, build second:

```bash
dart run flutter_build_tools --list                    # platforms, envs, resolved URLs
dart run flutter_build_tools apk preprod --dry-run     # profile, commands, guard verdict
dart run flutter_build_tools apk release preprod       # the build
```

`example/` is a complete minimal project you can try these on.

### Keeping your own entry point and wrapper scripts

`dart run flutter_build_tools` works from any folder inside the project (the
nearest `pubspec.yaml` is the project). If you prefer a path inside the
project, or wrapper scripts that call one, add a five-line shim:

```dart
// tool/build/build.dart
import 'dart:io';

import 'package:flutter_build_tools/flutter_build_tools.dart';

Future<void> main(List<String> args) async {
  // tool/build/build.dart -> the project root is two folders up.
  final root = File.fromUri(Platform.script).parent.parent.parent.path;
  exitCode = await runBuildToolCli(args, projectRoot: root);
}
```

```bash
#!/usr/bin/env bash
# scripts/build.sh
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
exec dart run tool/build/build.dart "$@"
```

With the shim the help and error messages show `dart run
tool/build/build.dart ...` (the command is derived from the running script).
List the wrapper scripts under `cli.wrappers` in `build_config.json` to have
`--help` mention them.

## Command line reference

```
dart run flutter_build_tools <platform> <env> [mode] [options]
dart run flutter_build_tools                 (interactive picker, in a terminal)
```

### Platforms, environments, modes

| Platform | Alias | Builds on | Artifact | Output folder |
|---|---|---|---|---|
| `apk` | | any | `.apk` | `dist/android/` |
| `web` | | any | `.zip` of the site | `dist/web/` |
| `windows` | `exe` | Windows only | Inno Setup installer `.exe` (plus `.msix` with `--msix`) | `dist/windows/` |
| `macos` | `dmg` | macOS only | `.dmg` | `dist/macos/` |

Environments are `dev`, `preprod`, `prod` and `local` (a closed set, see
[Extending it](#extending-it)). Modes are `release` (the default), `debug` and
`profile`.

The three words may come in any order: `apk release preprod`, `apk preprod
release` and `release apk preprod` are the same request. Leaving the mode out
means release. The mode may also be given as `--mode debug` or as `--release`,
`--debug`, `--profile`. Two different modes are refused, and every wrong
command line is answered with what was expected and one example.

### Options

| Option | Effect |
|---|---|
| `--mode release\|debug\|profile` | Build mode (default `release`); the same as the bare word or the `--release`, `--debug`, `--profile` switches |
| `--base-url URL` | Override `BASE_URL` for this build. Must be a valid origin; https unless env `local` |
| `--env-file PATH` | Use another env JSON, absolute or relative to the project root. `APP_ENV` must still equal the env |
| `--version x.y.z` | Override the pubspec version, for the file name and the binary (`--build-name`) |
| `--build-number N` | Override the `+N` of the pubspec (`--build-number`) |
| `--no-build` | Skip Flutter and re-package the existing output; needs a matching [build stamp](#--no-build-and-the-build-stamp) |
| `--release-signing` | apk: sign with the release keystore (`android/key.properties`) |
| `--msix` | windows: also build an MSIX package (release only) |
| `--allow-dirty` | prod: allow a dirty git tree |
| `--allow-prod-override` | prod: allow `--base-url` and `--env-file` |
| `--dry-run` | Print the resolved profile, the exact commands and the guard verdict; build nothing |
| `--list` | Show platforms, envs and their resolved URLs (takes no other argument) |
| `-h`, `--help` | The usage text (works even when the config is broken) |

Options that take a value accept `--name value` and `--name=value`.

### Exit codes

| Code | Meaning |
|---|---|
| `0` | Built (or dry run / list / help succeeded) |
| `1` | A build, guard or environment failure. Every error says what to do. A dry run exits `1` when a real run would be refused, and still prints the plan |
| `2` | A bad command line, or not run inside a Flutter project |

### Interactive picker

With no arguments in a terminal the tool asks for platform, environment and
mode (number, name or alias; Enter takes the default), prints the equivalent
command and asks to proceed (the default is yes, except for prod). Without a
terminal, missing arguments are a usage error, so CI never hangs.

### `--list` and `--dry-run`

`--list` shows which platforms are buildable on this host and, per environment,
the resolved `BASE_URL` (and `POS_WEB_URL` / extra URL keys when present). An
env file that is invalid is shown as `INVALID: <reason>` and makes `--list`
exit `1`, so CI notices.

`--dry-run` runs the same checks as a real run and prints the profile (app,
platform, mode, version, `APP_ENV`, URLs, `BUILD_SHA`, build time, output
path, signing), the numbered plan with the exact commands, and the guard
findings. It writes nothing and runs only read-only `git` and `df` queries; it
also checks that a `--no-build` stamp matches and, on Windows, that Inno
Setup is installed.

## `build_config.json`

`tool/build/build_config.json` holds the facts of one project. Its location is
fixed. Unknown keys are an error (a typo in `devHostMarkers` would otherwise
silently disable a guard); keys starting with `$` or `_` are ignored, so a
file may carry `$schema` or `_comment`.

| Key | Type | Required | Default | Effect and validation |
|---|---|---|---|---|
| `app` | string | yes | | Short id of the app; written to the manifest as `app` and shown in the profile |
| `slug` | string | yes | | Prefix of every artifact name. Letters and digits only |
| `displayName` | string | yes | | Human name: the title of `--help`, the first line of `--list`, the DMG volume name |
| `envDir` | string | yes | | Folder with the `<env>.json` files, `/`-separated, relative to the project root (`config/env`) |
| `windows.exe` | string | yes | | File name of the Windows runner in `build/windows/x64/runner/<Mode>/` (`BINARY_NAME` in `windows/CMakeLists.txt`) |
| `windows.installerScript` | string | yes | | Inno Setup script, relative to the project root |
| `windows.cleanupPrefix` | string | no | the `slug` | Installers in `build/windows/installers` whose name starts with this (case-sensitive) and ends in `.exe` are deleted before a new one is compiled, so a stale installer is never mistaken for the new one. Must start with a letter or digit and may contain letters, digits, space, `.`, `_`, `-` (it decides which files are deleted, so no separators or wildcards) |
| `macos.appName` | string | yes | | Bundle name without `.app`; must equal `PRODUCT_NAME` in `macos/Runner/Configs/AppInfo.xcconfig` |
| `devHostMarkers` | string[] | no | `[]` | Extra substrings that make a prod URL look like a dev server, compared case-insensitively against the whole URL and checked before the built-in ones (see [Guards](#guards)). Entries are trimmed and must not be empty |
| `envFile.extraKeys` | string[] | no | `[]` | Extra plain-string keys an env file may hold. `UPPER_SNAKE_CASE`; not `APP_ENV`, `BASE_URL`, `POS_WEB_URL`, `BUILD_SHA`; no duplicates |
| `envFile.extraUrlKeys` | string[] | no | `[]` | Extra URL keys: validated like `BASE_URL`, held to https outside `local`, checked by the prod dev-URL guard, listed in the profile and `--list`, compared by `--no-build`, written to the manifest as `extraUrls`. Same naming rules |
| `cli.docs` | string | no | the package README | Where the project's own build documentation lives; named in `--help` and in the "env file not found" error |
| `cli.wrappers` | `{script, label}[]` | no | `[]` | Wrapper scripts listed in `--help`, for example `{"script": "scripts/build.sh", "label": "macOS/Linux wrapper"}` |

Every optional key has a default that reproduces the behaviour of a project
that does not set it. `example/tool/build/build_config.full.json` sets every
key.

## Env files

An environment is a flat JSON object of strings in `<envDir>/<env>.json`. It
is committed, so it must never hold secrets.

```json
{
  "APP_ENV": "preprod",
  "BASE_URL": "https://preprod.example.com/public",
  "POS_WEB_URL": "https://preprod.example.com/public/web_pos"
}
```

| Key | Required | Meaning |
|---|---|---|
| `APP_ENV` | yes | Must equal the file name (`preprod.json` says `"preprod"`) |
| `BASE_URL` | yes | API origin including any path prefix, no trailing slash. https for every env except `local` |
| `POS_WEB_URL` | no | An optional second origin (built in because the apps this tool came from use it). Validated like `BASE_URL` |
| `envFile.extraKeys` / `envFile.extraUrlKeys` | no | Whatever the project declares in `build_config.json` |

Any other key is rejected, so a typo cannot be silently ignored by the app.
`BUILD_SHA` is generated by the tool and refused in a file. A URL must be an
absolute `http(s)` URL without whitespace, credentials, query string, fragment
or trailing slash.

The tool merges the env file, the overrides and the generated values into one
temporary file, `build/build_tool/defines-<platform>-<env>.json`, passes it as
the single `--dart-define-from-file`, and deletes it afterwards. Precedence,
lowest to highest:

1. the env file;
2. `--base-url` (replaces `BASE_URL` only);
3. generated values: `APP_ENV` (the requested env) and `BUILD_SHA`
   (`git rev-parse --short HEAD`, with `-dirty` when the tree has uncommitted
   or untracked changes).

Your app reads these with `String.fromEnvironment('APP_ENV')`,
`String.fromEnvironment('BASE_URL')`, and so on.

### The build time is not a define

The UTC build time is printed in the profile, kept in the build stamp and
written as `builtAt` into the manifest, and that is all. It is deliberately
**not** a `--dart-define`: Flutter hashes every define (and the build name and
number) into `.dart_tool/flutter_build/<md5>`, a cache folder of 100-230 MB
that it never prunes. A value that changes on every run creates a new folder
on every build and makes no build incremental. `BUILD_SHA` is safe because it
changes per commit, not per run. Never add a per-run value to the defines.

## Artifact names, checksums and manifest

```
<Slug>-<env>-v<version><suffix>.<ext>
```

`version` is the `x.y.z` of `pubspec.yaml` (`version: 1.0.47+47` gives
`v1.0.47`) or `--version`; `suffix` is empty for release, `-debug` or
`-profile`; `ext` is `apk`, `zip`, `exe` or `dmg`. Examples:
`ExampleApp-preprod-v1.0.47.apk`, `ExampleApp-dev-v1.0.47-debug.dmg`.

Every artifact gets two sidecar files named after the full file name:

| File | Content |
|---|---|
| `ExampleApp-preprod-v1.0.47.apk` | the artifact |
| `ExampleApp-preprod-v1.0.47.apk.sha256` | `<hash>  <file name>`, the `sha256sum` format. Verify with `shasum -a 256 -c ExampleApp-preprod-v1.0.47.apk.sha256` in that folder |
| `ExampleApp-preprod-v1.0.47.apk.json` | the build manifest |

`dist/` and `build/` should be git-ignored. At the end the tool prints the
path, size and SHA-256.

### Manifest, schema 1

| Field | Content |
|---|---|
| `schema` | `1` |
| `app`, `env`, `platform`, `mode` | from the config and the request |
| `version`, `buildNumber` | version and build number the binary was named and built with |
| `baseUrl` | the effective `BASE_URL` (after `--base-url`) |
| `posWebUrl` | only when the env file has `POS_WEB_URL` |
| `extraUrls`, `extraDefines` | only when `envFile.extraUrlKeys` / `envFile.extraKeys` are configured and present |
| `git` | `{sha, dirty}` |
| `flutter` | for example `3.47.0 (stable)` |
| `builtAt` | UTC ISO-8601 time of the build (of the original build for `--no-build`) |
| `hostOs` | `macos`, `windows` or `linux` |
| `file`, `sizeBytes`, `sha256` | the artifact |
| `signing` | apk only: `release-keystore` or `debug-key` |

## Guards

Each guard fails loudly before anything is built and has a stable code
(printed as `error [code]`). Warnings are printed as `warning [code]` and do
not stop the build.

| Code | Rule | Severity | To fix |
|---|---|---|---|
| `app-env-mismatch` | `APP_ENV` in the env file equals the requested env | error | Fix the file |
| `not-https` | `BASE_URL`, `POS_WEB_URL` and every extra URL key are https unless env is `local` | error | Use https, or build env `local` |
| `prod-dev-url` | prod refuses a URL that looks like dev or local: the project's `devHostMarkers`, then `localhost`, `127.0.0.1`, `::1`, `10.0.2.2`, `192.168.` and `10.x` hosts | error | Fix the prod env file |
| `prod-override` | prod refuses `--base-url` and `--env-file` unless `--allow-prod-override` is given | error | Edit and commit `<envDir>/prod.json`, or pass the flag |
| `prod-mode` | prod is release only | error | Drop `--debug` / `--profile` |
| `dirty-tree` | prod needs a clean git tree (also when git cannot tell) | error on prod (warning elsewhere) | Commit or stash, or `--allow-dirty` |
| `host-windows` / `host-macos` | `windows` builds only on Windows, `macos` only on macOS | error | Run it on that OS |
| `keystore` | prod apk needs a valid release keystore | error on prod | Configure `android/key.properties` |
| `keystore` | any other release apk without a usable or opted-in keystore is signed with the debug key | warning | Pass `--release-signing` |
| `msix-mode` | `--msix` is release only | error | Drop `--debug` / `--profile` |
| `release-signing-ignored` | `--release-signing` does nothing on debug and profile builds | warning | |
| `low-disk` | fewer than 3 GB free on the volume holding the project (read with `df -Pk`; macOS and Linux only, skipped for `--no-build`). Warns, never stops a build | warning | Free space: delete `.dart_tool/flutter_build/` (a cache) or run `flutter clean` |

Findings accumulate: a bad prod build reports everything at once.

## Per platform

### apk

Runs `flutter build apk --release --dart-define-from-file=...
--build-name=... --build-number=...` and copies
`build/app/outputs/flutter-apk/app-<mode>.apk` to `dist/android/`.

Signing mirrors a standard `android/app/build.gradle` that reads
`android/key.properties`: the release keystore is used when the file has
`storePassword`, `keyPassword`, `keyAlias` and `storeFile` (relative paths
resolve from `android/app`), the file exists, and signing is opted in. Opt in
with `--release-signing` (passes `-P useReleaseSigning=true` to Flutter) or
`useReleaseSigning=true` in `key.properties`. Prod always opts in, because a
prod apk must never carry the debug key. Debug and profile builds are always
debug-signed. Keystore values are only read, never printed. Your
`build.gradle` must honour `useReleaseSigning` the same way; the tool reports
what it asked for, not what Gradle did.

### web

The site is zipped from `build/web` with the files at the zip root (so it
extracts straight into the site folder), without `.DS_Store`, `__MACOSX/`,
`.last_build_id` or `*.zip`.

The tool reads the `<base href>` from `web/index.html` (a line inside an HTML
comment is skipped), shows it in the profile and prints a deploy hint: extract
into the folder served at that path, purge the CDN cache, and never
long-cache `index.html` and `flutter_service_worker.js`. The tool does not
pass `--base-href` to Flutter: the href is whatever `web/index.html` says.

### windows

Needs Inno Setup 6. The tool finds `ISCC.exe` in the usual folders
(`%LOCALAPPDATA%\Programs\Inno Setup 6`, then `Program Files (x86)`, then
`Program Files`), then searches them recursively; it checks this before the
long Flutter build starts. It then clears old installers (see
`windows.cleanupPrefix`) in `build\windows\installers`, compiles the script
with `/DMyAppVersion`, `/DMyOutputName` and, for debug and profile,
`/DMyBuildMode`, retries once after 3 seconds if that fails (an antivirus
scanning the folder is the usual cause), and copies the installer to
`dist\windows\`.

The Inno Setup script must follow this contract (`example/installer/example_app.iss`
is a template):

| Requirement | Why |
|---|---|
| `OutputDir=..\build\windows\installers` | the tool looks for the installer there |
| `OutputBaseFilename={#MyOutputName}` | the tool names the installer through the define; it refuses a script that ignores it |
| use `{#MyAppVersion}` for the version | passed as `x.y.z` |
| `Source: "..\build\windows\x64\runner\{#MyBuildMode}\*"`, with `MyBuildMode` defaulting to `Release` | debug and profile builds package their own folder; the tool refuses a non-release build when the script has no `MyBuildMode` |

`--msix` also runs `dart run msix:create --build-windows false
--install-certificate false --version <x.y.z>.0 ...` on the same Flutter
build, writing `dist\windows\<name>.msix` with its own checksum and manifest.
`--build-windows false` is essential: otherwise the msix package would rebuild
without the defines. The tool does not touch the certificate store.

### macos

`flutter build macos`, then the `.app` is staged next to an `/Applications`
symlink in a temporary folder (`<slug in lower case>_dmg_...`) and compressed
with `hdiutil create -format UDZO`, with the display name as the volume name.
The bundle name comes from `macos.appName` and must match `PRODUCT_NAME` in
`macos/Runner/Configs/AppInfo.xcconfig`.

The tool builds **release** by default on every platform, so `dart run
flutter_build_tools macos <env>` runs `flutter build macos --release`; the tool
passes no signing identity, so a release build signs with whatever the Xcode
project selects. To get an unsigned build pass `debug`:
`macos debug dev` produces `<Slug>-dev-v<version>-debug.dmg`.

## `--no-build` and the build stamp

`--no-build` re-packages the output of an earlier build without running
Flutter. Because the file name claims an environment, the tool refuses unless
it can prove the existing output matches: after every real build it writes
`build/build_tool/stamp-<platform>-<mode>.json` (the defines, version and
build time it was compiled with; the time is what the manifest of a
re-packaged artifact reports). `--no-build` compares platform, mode, version,
build number and every key an env file may hold (`APP_ENV`, `BASE_URL`,
`POS_WEB_URL` and the extra keys) against the requested profile and lists
every difference. No stamp, an unreadable stamp or any difference stops it
with "run the same command without `--no-build`". A failed build removes the
previous stamp, so half-written output can never be vouched for.

## CI

The tool needs only Dart and Flutter on the machine; it never prompts (without
a terminal, missing arguments are a usage error) and its exit code is the build
result.

```bash
flutter pub get
dart run flutter_build_tools apk preprod        # dist/android/ExampleApp-preprod-v1.0.47.apk (+ .sha256, .json)
dart run flutter_build_tools web dev
```

Publish the folder `dist/<platform>/` as the build artifact: the `.json`
manifest travels with the binary. A CI checkout is clean, so the prod
clean-tree guard passes there. For a prod apk the runner needs
`android/key.properties` and the keystore it points to, restored from the CI
secret store before the build; the tool only checks that they are valid. Run
`dart run flutter_build_tools <platform> <env> --dry-run` as a cheap
pre-flight step.

## Embedding it

```dart
import 'package:flutter_build_tools/flutter_build_tools.dart';
```

| Symbol | Purpose |
|---|---|
| `runBuildToolCli(args, projectRoot:, options:, environment:)` | The process entry: checks for `pubspec.yaml`, runs the tool, returns the exit code. Set `exitCode =` from it |
| `runBuildTool(args, environment, options:)` | The injectable core: takes a `BuildEnvironment` |
| `BuildToolOptions(invocation:)` | The command shown in help and error messages (default `dart run flutter_build_tools`) |
| `BuildEnvironment`, `Console`, `StdConsole`, `BuildFs`, `IoFs`, `ProcessRunner`, `IoProcessRunner`, `ProcessSpec`, `CapturedProcess`, `ProcessStartException` | The seams: replace them to run the tool against an in-memory file system and a scripted process runner |
| `AppConfig`, `WrapperScript`, `PubspecVersion` | The project facts and the pubspec version |
| `EnvFile`, `EnvSchema`, `urlProblem` | Env file parsing and validation |
| `BuildPlatform`, `BuildEnv`, `BuildMode`, `BuildRequest`, `HostOs`, `BuildException`, `UsageError` | The value types |
| `artifactBaseName`, `artifactFileName` | The naming rule |
| `evaluateGuards`, `GuardInput`, `Finding`, `Severity`, `devLookingMarker` | The guards as a pure function |

A project's own test can check that its configuration is valid for the tool
(a typo is then caught in the app's suite):

```dart
import 'dart:io';

import 'package:flutter_build_tools/flutter_build_tools.dart';
import 'package:test/test.dart';

void main() {
  test('build config and env files are valid for the build tool', () {
    final config = AppConfig.parse(File(AppConfig.configPath).readAsStringSync());
    for (final env in BuildEnv.values) {
      final path = '${config.envDir}/${env.name}.json';
      final file = EnvFile.parse(
        path,
        File(path).readAsStringSync(),
        schema: config.envSchema,
      );
      expect(file.appEnv, env.name);
    }
  });
}
```

To drive a build from your own code or tests, build a `BuildEnvironment` with
your own `BuildFs`, `ProcessRunner` and `Console`:

```dart
final code = await runBuildTool(
  ['apk', 'preprod', '--dry-run'],
  BuildEnvironment(
    root: '/repo',
    host: HostOs.macos,
    vars: const {},
    fs: myFs,
    runner: myRunner,
    console: myConsole,
  ),
);
```

The package's own test suite does exactly this (`test/fakes.dart` holds an
in-memory `BuildFs`, a scripted `ProcessRunner` and a recording `Console`).

## Extending it

- **A new environment.** The set `dev`, `preprod`, `prod`, `local` is closed in
  code (`BuildEnv` in `lib/src/model.dart`), because the guards and the
  naming matrix reason about it. To add one: add the value to `BuildEnv`
  (decide whether it counts as local or prod for the guards), add its env
  file, teach your app the name, and update the naming expectations in the
  tests. A later release may make the set configurable.
- **A new guard.** Add a rule to `evaluateGuards` in `lib/src/guards.dart`
  with a stable code, and a test in `test/guards_test.dart`. `GuardInput` is
  the only thing a guard may look at, so guards stay pure.
- **A new platform.** Add a `BuildPlatform` value, its output folder in
  `lib/src/job.dart`, its commands in `lib/src/commands.dart` and its packaging
  in `lib/src/executor.dart` (plan text and execution), then the guards for it.
- **A new project key.** Add it to `AppConfig` (`lib/src/config.dart`) with a
  default that keeps today's behaviour, validate it there, and document it in
  the table above.

## Known limits

- Desktop targets only build on their own OS.
- The Windows path (Inno Setup, `ISCC.exe` discovery), `--msix` and the macOS
  DMG path (`hdiutil`) are tested against fakes only: the command lines are
  checked, but this package has not produced an installer, an MSIX or a DMG in
  CI.
- No store targets (aab, ios) and no secrets management.
- The environment set is closed (see above) and the output locations are the
  Flutter defaults (`build/web`, `build/windows/x64/runner/<Mode>`,
  `build/app/outputs/flutter-apk/app-<mode>.apk`); Android flavors are not
  supported.
- `windows` and `macos` facts are required in `build_config.json` even for a
  project that never builds those platforms.
- Flutter keeps one folder per distinct set of dart-defines, build name and
  build number in `.dart_tool/flutter_build/<hash>` (100-230 MB each) and never
  prunes them. The tool warns (`low-disk`) below 3 GB, but a folder is still
  created per commit, environment, URL and version, so delete
  `.dart_tool/flutter_build/` now and then (`flutter clean` removes it too).
- Dev, preprod and prod builds share one install identity (Android application
  id, Windows Inno `AppId`, macOS bundle id), so a dev installer replaces a prod
  install on the same device. Isolating them is a decision for the app.
- `dart run` prints `Running build hooks...` in apps whose dependencies use
  native assets; that line is Dart's, not the tool's.

## Development

```bash
dart pub get
dart analyze
dart test
dart format --output=none --set-exit-if-changed .
```

The tests run the real code against fakes: no Flutter, ISCC or hdiutil is
needed. They cover version parsing, the naming matrix, env file validation,
override precedence, every guard, the command composition for all targets,
SHA-256 vectors, manifests, zip contents, `--dry-run`, `--list`, the picker,
the free-disk check, every key of `build_config.json`, the `bin/` entry as a
process, and the files in `example/`. One test uses the real file system and
checks the produced zip and checksum with `unzip` and `shasum`.

`test/no_app_literals_test.dart` fails if an app or company name appears in
`lib/` or `bin/`: project facts belong in `build_config.json`.
