# Example project

The smallest project `flutter_build_tools` can build: a pubspec with a
version, `tool/build/build_config.json`, and one env file per environment.

```bash
cd example
dart pub get
dart run flutter_build_tools --list
dart run flutter_build_tools web dev --dry-run
dart run tool/build/build.dart apk preprod --dry-run   # through the shim
```

`--dry-run` prints the resolved profile and the exact commands and builds
nothing, so it works without the Flutter SDK being used.

| File | Purpose |
|---|---|
| `tool/build/build_config.json` | The minimal project facts (required keys only) |
| `tool/build/build_config.full.json` | Every optional key set, for reference; the tool does not read it |
| `config/env/<env>.json` | One committed, non-secret file per environment |
| `installer/example_app.iss` | The Inno Setup contract for the `windows` target |
| `web/index.html` | Holds the `<base href>` the web profile reports |
| `tool/build/build.dart` | Optional 5-line shim over `runBuildToolCli` |
