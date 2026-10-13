# Example project

The smallest project `flutter_build_tools` can build, and it needs **no
`tool/build/build_config.json`**: the tool infers everything from the project.

```bash
cd example
dart pub get
dart run flutter_build_tools --list
dart run flutter_build_tools web dev --dry-run
dart run flutter_build_tools macos dev --dry-run      # the bundle is example_app.app
dart run flutter_build_tools init --dry-run           # what a new project would get
```

`--dry-run` prints the resolved profile and the exact commands and builds
nothing, so it works without the Flutter SDK being used.

| File | What the tool reads from it |
|---|---|
| `pubspec.yaml` | `name: example_app` gives the slug `ExampleApp` and the title `Example App`; `version:` the artifact version |
| `windows/CMakeLists.txt` | `BINARY_NAME` gives `windows.exe` (`example_app.exe`) |
| `macos/Runner/Configs/AppInfo.xcconfig` | `PRODUCT_NAME` gives `macos.appName` (`example_app`) |
| `installer/example_app.iss` | The only installer script: `windows.installerScript`. It also shows the Inno Setup contract of the `windows` target |
| `config/env/<env>.json` | One committed, non-secret file per environment |
| `web/index.html` | The `<base href>` the web profile reports |
| `tool/build/build_config.full.json` | Every key `build_config.json` knows, for reference; the tool does not read this file |

A real project has the complete `windows/` and `macos/` folders that
`flutter create` writes; the example keeps only the lines the tool reads.

To override one inferred fact, add `tool/build/build_config.json` with just
that key (`{"slug": "Shop"}`); `dart run flutter_build_tools init` writes the
file with all of them.

`init --dry-run` also lists `lib/app_env.dart`: `init` writes the `AppEnv`
class that reads `APP_ENV` and `BASE_URL` (`--no-app-env` skips it). The class
imports `package:flutter/foundation.dart`, so it belongs in a Flutter app; this
example is not one, and a dry run writes nothing.
