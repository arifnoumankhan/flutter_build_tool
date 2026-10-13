/// A build tool for Flutter apps: one command for any platform and
/// environment, with guards, deterministic artifact names, checksums and a
/// manifest next to each artifact.
///
/// Run it with `dart run flutter_build_tools <platform> <env> [options]`
/// (`dart run flutter_build_tools init` writes the files a new project needs;
/// the project facts are inferred from the project itself), or embed it:
/// [runBuildToolCli] is the process entry, [runBuildTool] takes a
/// [BuildEnvironment] whose file system, process runner and console you can
/// replace in tests.
library;

export 'src/cli.dart' show runBuildTool;
export 'src/config.dart' show AppConfig, PubspecVersion, WrapperScript;
export 'src/entry.dart'
    show findProjectRoot, runBuildToolCli, runBuildToolFromDirectory;
export 'src/env_file.dart'
    show EnvFile, EnvSchema, isPlaceholderUrl, placeholderDomain, urlProblem;
export 'src/environment.dart' show BuildEnvironment, Console, StdConsole;
export 'src/fs.dart' show BuildFs, IoFs;
export 'src/guards.dart'
    show Finding, GuardInput, Severity, devLookingMarker, evaluateGuards;
export 'src/inference.dart'
    show
        ProjectFacts,
        displayNameFromPubspecName,
        inferProjectFacts,
        slugFromPubspecName;
export 'src/init.dart' show InitOptions, runInit;
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
export 'src/profile.dart' show loadAppConfig, loadEnvFile;
export 'src/runner.dart'
    show
        CapturedProcess,
        IoProcessRunner,
        ProcessRunner,
        ProcessSpec,
        ProcessStartException;
