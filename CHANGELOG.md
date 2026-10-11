## 0.1.0

* Initial release. Extracted from build scripts that lived as a copy in each app repository; apps that switch to the package keep the same command line, artifact names, guards and exit codes.
* **`dart run flutter_build_tools <platform> <env> [mode] [options]`** — builds `apk`, `web`, `windows` (Inno Setup, optional MSIX) and `macos` (DMG) for the environments `dev`, `preprod`, `prod` and `local`, with `--dry-run`, `--list`, `--no-build`, an interactive picker and a documented exit code contract.
* **Programmatic API** — `runBuildToolCli` (process entry) and `runBuildTool` (injectable core), with `BuildEnvironment`, `BuildFs`, `ProcessRunner` and `Console` as test seams; `AppConfig`, `EnvFile`, `EnvSchema`, the guards and the naming rule are exported for project-side tests.
* **Project facts stay in the project** — `tool/build/build_config.json` and `config/env/<env>.json`; the library carries no app name.
* **New optional `build_config.json` keys** (each defaults to the previous behaviour): `devHostMarkers` (project-specific dev host names for the prod guard), `windows.cleanupPrefix` (which old installers to delete, default the slug), `envFile.extraKeys` and `envFile.extraUrlKeys` (extra env file keys, URL keys get the https and prod dev-URL guards), `cli.docs` and `cli.wrappers` (what `--help` points at).
* **Unknown keys in `build_config.json` are an error**, so a typo cannot silently disable a guard; keys starting with `$` or `_` are ignored.
* `--help` is titled with the app's `displayName` (`Flutter build tool` when there is no readable config) and works with a missing or broken config.
* Messages point at the package README instead of a specific repository; the macOS staging folder is `<slug>_dmg_*` in the system temp folder.
