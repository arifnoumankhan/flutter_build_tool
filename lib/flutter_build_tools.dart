/// A build tool for Flutter apps: one command for any platform and
/// environment, with guards, deterministic artifact names, checksums and a
/// manifest next to each artifact.
///
/// Run it with `dart run flutter_build_tools <platform> <env> [options]`, or
/// embed it: [runBuildToolCli] is the process entry, [runBuildTool] takes a
/// [BuildEnvironment] whose file system, process runner and console you can
/// replace in tests.
library;

export 'src/cli.dart' show runBuildTool;
export 'src/config.dart' show AppConfig, PubspecVersion, WrapperScript;
export 'src/entry.dart' show runBuildToolCli;
export 'src/env_file.dart' show EnvFile, EnvSchema, urlProblem;
export 'src/environment.dart' show BuildEnvironment, Console, StdConsole;
export 'src/fs.dart' show BuildFs, IoFs;
export 'src/guards.dart'
    show Finding, GuardInput, Severity, devLookingMarker, evaluateGuards;
export 'src/model.dart'
    show
        BuildEnv,
        BuildException,
        BuildMode,
        BuildPlatform,
        BuildRequest,
        HostOs,
        UsageError;
export 'src/naming.dart' show artifactBaseName, artifactFileName;
export 'src/options.dart' show BuildToolOptions;
export 'src/runner.dart'
    show
        CapturedProcess,
        IoProcessRunner,
        ProcessRunner,
        ProcessSpec,
        ProcessStartException;
