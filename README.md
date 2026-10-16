# flutter_build_tools
## Quick start
```yaml
# pubspec.yaml
dev_dependencies:
  flutter_build_tools:
    git: {url: 'https://github.com/arifnoumankhan/flutter_build_tool.git', ref: v0.2.1}
```
```bash
flutter pub get
dart run flutter_build_tools init      # writes tool/build/build_config.json, config/env/*.json, scripts/ and the AppEnv class lib/app_env.dart (lib/config/app_env.dart when lib/config/ exists); offline, never overwrites
# edit BASE_URL in config/env/dev.json, preprod.json, prod.json (init writes placeholders; prod refuses them)
dart run flutter_build_tools apk dev   # -> dist/android/<Name>-dev-v<version>.apk (+ .sha256, .json); --dry-run looks first
# CI: flutter pub get && dart run flutter_build_tools apk preprod    (the exit code is the result)
```
```dart
// lib/main.dart: init prints these lines (the import names the file it wrote) and never edits the file
import 'package:my_app/app_env.dart';

void main() {
  AppEnv.ensureValid();                        // a release build without an env file stops here
  final api = Uri.parse(AppEnv.baseUrl);       // BASE_URL of the environment that was built
  // ...
}
```

One command builds a Flutter app for any platform and any environment, and the
file name says exactly what is inside. A new project needs the dependency and
`init`; everything else is inferred from the project (name, `windows/`,
`macos/`, `installer/`), and a file in `tool/build/` or `config/env/` only
says what differs.

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
between projects (name, installer, extra guard hints) is read from the project
itself (`pubspec.yaml`, `windows/`, `macos/`, `installer/`) and can be set in
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

1. [Quick start](#quick-start) (above)
2. [Requirements](#requirements)
3. [Install](#install)
4. [`init` and what is inferred](#init-and-what-is-inferred)
5. [Command line reference](#command-line-reference)
6. [`build_config.json`](#build_configjson)
7. [Env files](#env-files)
8. [Artifact names, checksums, manifest](#artifact-names-checksums-and-manifest)
9. [Guards](#guards)
10. [Per platform](#per-platform)
11. [`--no-build` and the build stamp](#--no-build-and-the-build-stamp)
12. [CI](#ci)
13. [Embedding it](#embedding-it)
14. [Extending it](#extending-it)
15. [Known limits](#known-limits)
16. [Development](#development)

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
      ref: v0.2.1
```

Then run `flutter pub get` in the app (`dart run` also resolves a declared
dependency by itself). A project that does not list the package gets Dart's
own "Could not find package" error (exit code 255), and a
shim that imports it gets `Couldn't resolve the package`: those are Dart's
messages, before this tool runs. To upgrade, move `ref` to a newer tag (see
`CHANGELOG.md`) and run `flutter pub upgrade flutter_build_tools`.

The package needs `archive` and `path` and accepts `archive` 3.6.x and 4.x
(`>=3.6.0 <5.0.0`), so an app that already uses archive 4 resolves. The zip of
the web build is written by the tool itself, with the Deflate and CRC-32 that
both archive majors export, so the artifact is byte-for-byte the same whichever
archive version the app has (see [web](#web)).

To work on the tool and an app side by side, keep the committed pubspec on the
tag and point at your checkout in a per-machine, git-ignored
`pubspec_overrides.yaml`:

```yaml
dependency_overrides:
  flutter_build_tools:
    path: ../flutter_build_tool
```

## `init` and what is inferred

`init` writes every file a project needs, from the project itself. It works
offline, from any folder inside the project, never edits `lib/main.dart`, and
creates only what is missing:

```bash
dart run flutter_build_tools init [--force] [--dry-run] [--no-app-env]
```

| It creates | Content |
|---|---|
| `tool/build/build_config.json` | The inferred facts, written out as explicit values so you can edit them (a `$comment` key is allowed: keys starting with `$` or `_` are ignored). Only the keys it could infer; the rest it lists |
| `config/env/dev.json`, `preprod.json`, `prod.json` | `APP_ENV` and a `BASE_URL` placeholder (`https://<env>.replace-me.invalid`). Placeholders cannot be reached; prod refuses them (`placeholder-url`), dev and preprod only warn |
| `config/env/local.json` | `APP_ENV` and `http://127.0.0.1` |
| `scripts/build.sh`, `scripts/build.ps1` | Thin wrappers: `dart run flutter_build_tools "$@"`. `build.sh` is made executable |
| `lib/config/app_env.dart` (`lib/app_env.dart` when `lib/config/` does not exist), unless `--no-app-env` | A small `AppEnv` class reading `APP_ENV`, `BASE_URL` and `BUILD_SHA` through `String.fromEnvironment`, with a startup guard (`AppEnv.ensureValid()`, see [The `AppEnv` class](#the-appenv-class)); the lines for `main.dart` are printed. Written only where nothing of the project's is: a project that already defines `AppEnv` anywhere under `lib/`, or has another file at that path, keeps it, also with `--force` (then `init` names the class and prints its import) |

| Switch | Effect |
|---|---|
| (none) | Create what is missing, list what was created and what was skipped |
| `--dry-run` | List what would be written; write nothing |
| `--force` | Overwrite existing files. An env file keeps every key but `APP_ENV` and `BASE_URL` (so `POS_WEB_URL` and your own `envFile.extraKeys` values survive), and a `BASE_URL` that was a real one is reported (`BASE_URL was ...`); a config file keeps every key you set in it; a script whose text is not init's own is reported as `custom content replaced`. `AppEnv` is the one exception: it is replaced only when it is init's own text (this version's, or the one of 0.2.0), and a file of yours at its place stays. `--dry-run --force` reports the same, and writes nothing |
| `--no-app-env` | Do not write `AppEnv` (and print no `main.dart` lines) |
| `--app-env` | The default, accepted so that existing instructions keep working. Giving it together with `--no-app-env` is a usage error (exit code 2) |

It prints the next steps and every fact it could not infer, and it refuses
outside a Flutter project (no `pubspec.yaml` in the folder or above it) with
exit code 2 when the tool itself runs (a shim, `dart bin/flutter_build_tools.dart`,
an embedder); `dart run flutter_build_tools` fails earlier, with Dart's own
"Found no pubspec.yaml file" and exit code 255 (see [exit
codes](#exit-codes)). Run it again at any time: nothing it has written is
touched.

Three things it checks and only reports, never changes:

- **Keys the config does not declare.** An env file that already holds a key
  the tool does not accept (`USE_DUMMY`, say) makes `--list` and every build
  refuse it as an `unknown key`. `init` lists such keys with the snippet that
  declares them (`"envFile": {"extraKeys": ["USE_DUMMY"]}` in
  `tool/build/build_config.json`; `extraUrlKeys` for URLs). It never adds them
  itself: an env file is committed, so what counts as a secret is your call.
- **Files git ignores.** `git check-ignore` is asked (read-only, silent when
  git is missing or the folder is not a repository) about the config and the
  env files. A rule such as `build/` also matches `tool/build/`, so a clone or
  CI checkout would not have `build_config.json` and would infer every fact in
  it. Anchor the rule (`/build/`) or `git add -f` the file.
- **`.gitignore` without `dist/`**, which makes the next prod build refuse the
  tree as dirty.

### The `AppEnv` class

`init` writes it by default, because every app that builds with this tool reads
the same three values. The members are the ones of 0.2.0 (`name`, `baseUrl`,
`buildSha`, `summary`) and `ensureValid()`:

```dart
import 'package:flutter/foundation.dart' show kReleaseMode;

class AppEnv {
  AppEnv._();

  /// `dev`, `preprod`, `prod` or `local`; empty when no env file was passed.
  static const String name = String.fromEnvironment('APP_ENV');

  /// The API origin of this environment; empty when no env file was passed.
  static const String baseUrl = String.fromEnvironment('BASE_URL');

  /// The short git commit of the build (`-dirty` when the tree had changes).
  static const String buildSha = String.fromEnvironment('BUILD_SHA');

  /// One line for a log: `dev https://... 1a2b3c4`.
  static String get summary => '$name $baseUrl $buildSha';

  /// Throws a StateError in a release build without APP_ENV or BASE_URL.
  static void ensureValid() {
    if (!kReleaseMode) return;
    final missing = [
      if (name.isEmpty) 'APP_ENV',
      if (baseUrl.isEmpty) 'BASE_URL',
    ];
    if (missing.isEmpty) return;
    throw StateError(
      'AppEnv: this release build has no ${missing.join(' and ')}. ...',
    );
  }
}
```

- **`ensureValid()`** stops a release build that was made without an env file,
  with a message that says to build with `dart run flutter_build_tools
  <platform> <env>` or to pass `--dart-define-from-file=config/env/<env>.json`
  (the folder is the `envDir` of the project). It does nothing in debug and
  profile builds, so a plain `flutter run` keeps working with an empty
  `baseUrl`; pass `--dart-define-from-file=config/env/dev.json` to run against
  an environment.
- **`main.dart`** is never edited. `init` prints the import (the file it
  wrote, or the one the project already had) and the two lines to add, in
  `main()` before `runApp`: `AppEnv.ensureValid();` and
  `debugPrint(AppEnv.summary);`.
- **A project that has its own `AppEnv`** (a class, enum, mixin, extension type
  or typedef of that name in any file under `lib/`, `lib/config/app_env.dart`
  and `lib/app_env.dart` included) is left alone: `init` writes no second one,
  even with `--force`, reports the file and prints its import. Only the members
  that file has are shown, and a note says when it lacks `ensureValid()`.
- **A file of yours at its place that defines no `AppEnv`** (an enum of another
  name, say) is left alone as well, also with `--force`: `init` says so and
  prints no `main.dart` lines. Move or delete the file and run `init` again to
  get the class, or use `--no-app-env`.
- **An `AppEnv` written by 0.2.0 has no `ensureValid()`.** `init` keeps it and
  says so; delete the file and run `init` again to get the new one (`--force`
  also replaces it, without calling it custom, but resets every `BASE_URL` too).
- **`--no-app-env`** skips the class and its lines. `init` also suggests it
  when the class cannot be written (a read-only `lib/`).
- **A `lib/` folder that cannot be read** completely leaves `init` unable to
  tell whether the project already defines `AppEnv`; it writes its class and
  says so in a note.

### Zero-config: what is inferred when there is no file

Without `tool/build/build_config.json` (and for every key the file leaves
out) the tool reads the project:

| Fact | Inferred from |
|---|---|
| `slug` | PascalCase of the pubspec `name`, letters and digits only (`my_cool_app` gives `MyCoolApp`) |
| `displayName` | The pubspec name as a title (`My Cool App`) |
| `app` | `app` |
| `envDir` | `config/env` |
| `windows.exe` | `BINARY_NAME` of `windows/CMakeLists.txt`, plus `.exe` |
| `windows.installerScript` | The one `installer/*.iss`, when there is exactly one |
| `macos.appName` | `PRODUCT_NAME` of `macos/Runner/Configs/AppInfo.xcconfig` |

The file always wins, key by key: `{"slug": "Shop"}` sets the artifact prefix
and infers the rest, and `{}` is a complete config. The `windows` and `macos`
facts are needed only when that platform is built: a mobile-only project
builds `apk` and `web` without them, and `windows` or `macos` then stops
before anything runs with an error that names the missing fact, why it could
not be inferred, and how to set it. `init` writes what is inferred, so the
behaviour before and after it is the same, with one visible difference: every
build profile of a project without the file has the line `config       inferred
from the project (no tool/build/build_config.json)`. It is there so that a file
that was never committed (or is git-ignored) is noticed in CI: what only the
file can set (`devHostMarkers`, `slug`, `cleanupPrefix`, `cli.*`) is then at
its inferred or neutral value.

Then look first, build second:

```bash
dart run flutter_build_tools --list                    # platforms, envs, resolved URLs
dart run flutter_build_tools apk preprod --dry-run     # profile, commands, guard verdict
dart run flutter_build_tools apk release preprod       # the build
```

`example/` is a complete minimal project you can try these on; it has no
`build_config.json` at all.

### Keeping your own entry point and wrapper scripts (optional)

`dart run flutter_build_tools` works from any folder inside the project (the
nearest `pubspec.yaml` is the project), and `init` writes wrapper scripts that
call it. You only need a shim if you prefer a path inside the project (an
existing project with its own scripts keeps working as it is). It is five
lines:

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
dart run flutter_build_tools init [--force] [--dry-run] [--no-app-env]   (see `init`, above)
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
| `--allow-prod-debug` | prod: allow `--debug` (still marked `-debug` on the artifact and in the manifest; `--profile` stays refused) |
| `--dry-run` | Print the resolved profile, the exact commands and the guard verdict; build nothing |
| `--list` | Show platforms, envs and their resolved URLs (takes no other argument) |
| `-h`, `--help` | The usage text (works even when the config is broken) |
| `--force`, `--no-app-env`, `--app-env` | `init` only (see [`init`](#init-and-what-is-inferred)); `--dry-run` also applies to `init` |

Options that take a value accept `--name value` and `--name=value`.

### Exit codes

| Code | Meaning |
|---|---|
| `0` | Built (or dry run / list / help succeeded) |
| `1` | A build, guard or environment failure. Every error says what to do. A dry run exits `1` when a real run would be refused, and still prints the plan |
| `2` | A bad command line, or not run inside a Flutter project |

A write the operating system refuses (a read-only folder, a file where a
folder should be) is an exit `1` that names the path, never a stack trace;
`init` also lists what it had already written.

Exit `2` for "not inside a Flutter project" comes from the tool, so it is what
you get through a shim, `dart bin/flutter_build_tools.dart` or the embedding
API. `dart run flutter_build_tools` itself looks for a `pubspec.yaml` first:
with none in the folder or above it, Dart prints "Found no pubspec.yaml file
in ... or parent directories" and exits `255`, and the same exit code comes
with "Could not find package flutter_build_tools" when the project does not
list the dependency. Those two are Dart's, before this tool starts.

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

`tool/build/build_config.json` holds the facts of one project. **Every key is
optional**: a key the file leaves out is inferred from the project (see
[zero-config](#zero-config-what-is-inferred-when-there-is-no-file)), and
without the file everything is. Its location is fixed. Unknown keys are an
error (a typo in `devHostMarkers` would otherwise silently disable a guard);
keys starting with `$` or `_` are ignored, so a file may carry `$schema` or
`$comment`. `dart run flutter_build_tools init` writes the file with the
inferred values.

| Key | Type | Default (when the file leaves it out) | Effect and validation |
|---|---|---|---|
| `app` | string | `app` | Short id of the app; written to the manifest as `app` and shown in the profile |
| `slug` | string | PascalCase of the pubspec name | Prefix of every artifact name. Letters and digits only |
| `displayName` | string | the pubspec name as a title | Human name: the title of `--help`, the first line of `--list`, the DMG volume name |
| `envDir` | string | `config/env` | Folder with the `<env>.json` files, `/`-separated, relative to the project root |
| `windows.exe` | string | `BINARY_NAME` of `windows/CMakeLists.txt` + `.exe` | File name of the Windows runner in `build/windows/x64/runner/<Mode>/`. Needed only to build `windows` |
| `windows.installerScript` | string | the only `installer/*.iss` | Inno Setup script, relative to the project root. Needed only to build `windows` |
| `windows.cleanupPrefix` | string | the `slug` | Installers in `build/windows/installers` whose name starts with this (case-sensitive) and ends in `.exe` are deleted before a new one is compiled, so a stale installer is never mistaken for the new one. Must start with a letter or digit and may contain letters, digits, space, `.`, `_`, `-` (it decides which files are deleted, so no separators or wildcards) |
| `macos.appName` | string | `PRODUCT_NAME` of `macos/Runner/Configs/AppInfo.xcconfig` | Bundle name without `.app`. Needed only to build `macos` |
| `devHostMarkers` | string[] | `[]` | Extra substrings that make a prod URL look like a dev server, compared case-insensitively against the whole URL and checked before the built-in ones (see [Guards](#guards)). Entries are trimmed and must not be empty |
| `envFile.extraKeys` | string[] | `[]` | Extra plain-string keys an env file may hold. `UPPER_SNAKE_CASE`; not `APP_ENV`, `BASE_URL`, `POS_WEB_URL`, `BUILD_SHA`; no duplicates |
| `envFile.extraUrlKeys` | string[] | `[]` | Extra URL keys: validated like `BASE_URL`, held to https outside `local`, checked by the prod dev-URL guard, listed in the profile and `--list`, compared by `--no-build`, written to the manifest as `extraUrls`. Same naming rules |
| `cli.docs` | string | the package README | Where the project's own build documentation lives; named in `--help` and in the "env file not found" error |
| `cli.wrappers` | `{script, label}[]` | `[]` | Wrapper scripts listed in `--help`, for example `{"script": "scripts/build.sh", "label": "macOS/Linux wrapper"}` |

A `windows` or `macos` fact that is neither in the file nor inferable is not
an error until that platform is built.

`init` writes `windows.exe` and `macos.appName` as explicit values, so a later
rename of `BINARY_NAME` or `PRODUCT_NAME` must be followed there (or delete
the keys to follow the project again). A build that finishes without the
expected bundle or exe says which key is out of date and what the project now
gives, rather than telling you to run without `--no-build`; that remedy is
only given when you did pass `--no-build`.

### Defaults of the optional keys

The optional keys default to the neutral behaviour of a project that sets
none of them: no extra dev host marker, the slug as installer cleanup prefix,
no extra env file keys, the package README as the documentation and no
wrapper scripts in `--help`. A project that moves over from its own build
scripts sets the keys for anything those scripts did differently:

| What the previous scripts did | Key to set |
|---|---|
| Refused a prod URL containing a project-specific dev host name | `"devHostMarkers": ["devhost"]` |
| Deleted old installers by a prefix that is not the slug | `"windows": {"cleanupPrefix": "Prefix"}` |
| Accepted more keys in the env files | `"envFile": {"extraKeys": [...], "extraUrlKeys": [...]}` |
| Pointed `--help` at their own documentation and wrapper scripts | `"cli": {"docs": "tool/build/README.md", "wrappers": [{"script": "scripts/build.sh", "label": "macOS/Linux wrapper"}]}` |
| Used an artifact prefix or a bundle name that is not the pubspec name | `"slug"`, `"displayName"`, `"macos": {"appName": ...}` |

Without them the tool still builds, but a guard, a cleanup or a help line that
the old script had is missing. `example/tool/build/build_config.full.json`
sets every key.

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
| `POS_WEB_URL` | no | An optional second origin (for example a web POS or a companion site). Validated like `BASE_URL` |
| `envFile.extraKeys` / `envFile.extraUrlKeys` | no | Whatever the project declares in `build_config.json` |

Any other key is rejected, so a typo cannot be silently ignored by the app. A
key that is meant (`USE_DUMMY`, `SHOP_URL`) is allowed by declaring it in
`tool/build/build_config.json` under `envFile.extraKeys` (plain strings) or
`envFile.extraUrlKeys` (URLs); `dart run flutter_build_tools init` lists the
undeclared keys of the env files it finds and prints that snippet.
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

Your app reads these through `AppEnv` (`AppEnv.name`, `AppEnv.baseUrl`,
`AppEnv.buildSha`), the class `init` writes, which is
`String.fromEnvironment('APP_ENV')`, `String.fromEnvironment('BASE_URL')` and
`String.fromEnvironment('BUILD_SHA')` underneath; any other key of the file
is read with `String.fromEnvironment('<KEY>')`.

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

`/dist/` and `/build/` should be git-ignored, **anchored** with the leading
slash: a bare `build/` rule also matches `tool/build/`, where
`build_config.json` lives, so the file is silently left out of every commit
and a CI clone infers its facts. `init` checks this with `git check-ignore`.
At the end the tool prints the path, size and SHA-256.

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
| `placeholder-url` | a URL whose host ends in `.invalid` (what `init` writes) is still a placeholder. Prod refuses it; other envs warn, because the binary cannot reach a server | error on prod (warning elsewhere) | Put the real URL in the env file |
| `prod-override` | prod refuses `--base-url` and `--env-file` unless `--allow-prod-override` is given | error | Edit and commit `<envDir>/prod.json`, or pass the flag |
| `prod-mode` | prod is release only, unless `--allow-prod-debug` is given for debug (profile stays refused). The override is a loud warning; the artifact name ends in `-debug` and the manifest has `"mode": "debug"` and `"allowProdDebug": true` | error (warning when `--allow-prod-debug` and debug) | Drop `--debug` / `--profile`, or pass `--allow-prod-debug` for a marked debug prod artifact |
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

The zip is a pure function of the file names, their content and the build
time: entries are sorted, permissions are fixed, there is no random value, and
the entry times are the build time **in UTC** (0.1.0 wrote the machine's local
time, so the same build gave different bytes in another time zone). It is
written by the tool, using only `Deflate` and `getCrc32` of `package:archive`
(unchanged in 3.6.x and 4.x), so the bytes do not change with the archive
version either: `archive` 4 would otherwise compress with the native zlib and
produce a different file. A plain zip holds at most 65535 files and 4 GiB; the
tool says so instead of writing a corrupt zip.

The tool reads the `<base href>` from `web/index.html` (a line inside an HTML
comment is skipped), shows it in the profile and prints a deploy hint: extract
into the folder served at that path, purge the CDN cache, and never
long-cache `index.html` and `flutter_service_worker.js`. The tool does not
pass `--base-href` to Flutter: the href is whatever `web/index.html` says. The
`index.html` that `flutter create` writes says `$FLUTTER_BASE_HREF`, a
placeholder Flutter replaces with the `--base-href` of the build, which is `/`
when none is passed: the profile then reads `/` and says so, and the deploy
hint names `/`. A project that serves the site from a folder hardcodes it
(`<base href="/web_admin/">`) and the tool shows exactly that.

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
| `runBuildToolFromDirectory(args, directory:, fs:, console:, ...)` | What `bin/flutter_build_tools.dart` does once Dart has started it: finds the project from any folder inside it (`findProjectRoot`), exit code 2 when there is none (`dart run flutter_build_tools` never gets that far without a `pubspec.yaml`: Dart exits 255 first). `fs` and `console` are seams, so "outside a project" is testable on any machine |
| `runBuildTool(args, environment, options:)` | The injectable core: takes a `BuildEnvironment` |
| `BuildToolOptions(invocation:)` | The command shown in help and error messages (default `dart run flutter_build_tools`) |
| `BuildEnvironment`, `Console`, `StdConsole`, `BuildFs`, `IoFs`, `ProcessRunner`, `IoProcessRunner`, `ProcessSpec`, `CapturedProcess`, `ProcessStartException` | The seams: replace them to run the tool against an in-memory file system and a scripted process runner |
| `AppConfig`, `WrapperScript`, `PubspecVersion`, `loadAppConfig` | The project facts (the file, completed by inference) and the pubspec version |
| `ProjectFacts`, `inferProjectFacts`, `slugFromPubspecName`, `displayNameFromPubspecName` | What is inferred, as a pure function over `BuildFs` |
| `runInit`, `InitOptions` | The `init` command as a function |
| `EnvFile`, `EnvSchema`, `urlProblem`, `isPlaceholderUrl`, `loadEnvFile` | Env file parsing and validation |
| `BuildPlatform`, `BuildEnv`, `BuildMode`, `BuildRequest`, `HostOs`, `BuildException`, `UsageError` | The value types |
| `artifactBaseName`, `artifactFileName` | The naming rule |
| `evaluateGuards`, `GuardInput`, `Finding`, `Severity`, `devLookingMarker` | The guards as a pure function |

A project's own test can check that its configuration is valid for the tool
(a typo is then caught in the app's suite). It needs only `dart:io`, this
package and `flutter_test`, which every Flutter app has:

```dart
import 'dart:io';

import 'package:flutter_build_tools/flutter_build_tools.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('build config and env files are valid for the build tool', () {
    final env = BuildEnvironment.system(Directory.current.path);
    final config = loadAppConfig(env); // the file, or what is inferred
    for (final buildEnv in BuildEnv.values) {
      final file = loadEnvFile(env, config, buildEnv); // keys, URLs
      expect(file.appEnv, buildEnv.name);
    }
  });
}
```

Run it with `flutter test` from the project root (the working directory is the
project root there).

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
  neutral default (and, if the project can state the fact itself, an
  inference in `lib/src/inference.dart`), validate it there, and document it
  in the table above, including what an existing app must set to keep a
  behaviour it had before.

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
- The `windows` and `macos` facts are inferred from the Flutter templates
  (`BINARY_NAME`, `PRODUCT_NAME`) and from a single `installer/*.iss`. A
  project that moved them (a variable in `BINARY_NAME`, two installer scripts)
  sets them in `build_config.json`; the error says which and how.
- The web zip is a plain (not zip64) zip: at most 65535 files and 4 GiB.
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
needed. They cover version parsing, the naming matrix, inference and `init`,
env file validation, override precedence, every guard, the command composition
for all targets, SHA-256 vectors, manifests, zip contents and bytes,
`--dry-run`, `--list`, the picker, the free-disk check, every key of
`build_config.json`, the `bin/` entry as a process, and the files in
`example/`. One test uses the real file system and checks the produced zip and
checksum with `unzip` and `shasum`.

`test/no_app_literals_test.dart` fails if an app or company name appears in
`lib/` or `bin/`: project facts belong in `build_config.json`. Name them in
`FORBIDDEN_LITERALS=name1,name2 dart test test/no_app_literals_test.dart`.

### Both archive majors

`archive` is declared as `>=3.6.0 <5.0.0`. To run the zip tests against a
major other than the one in your lock file, use an uncommitted
`pubspec_overrides.yaml` (it is git-ignored; delete it afterwards):

```yaml
dependency_overrides:
  archive: 4.0.9   # or 3.6.1
```

```bash
dart pub get && dart test test/web_zip_test.dart test/cli_test.dart
```

`test/web_zip_test.dart` holds the SHA-256 of the zip that 0.1.0 produced on
archive 3.6.1; it passes unchanged on 3.6.x and on 4.x.
