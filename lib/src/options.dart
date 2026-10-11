/// Presentation options of one run: how the tool is invoked (it only changes
/// the text of help, examples and the picker, never behaviour).
library;

/// Options for [runBuildTool]. Everything has a default, so embedding the tool
/// needs none.
class BuildToolOptions {
  /// Creates options. [invocation] is the command a person types.
  const BuildToolOptions({this.invocation = defaultInvocation});

  /// What `dart run flutter_build_tools` prints in help and examples.
  static const String defaultInvocation = 'dart run flutter_build_tools';

  /// The command line that starts the tool, for example
  /// `dart run tool/build/build.dart` when a project wraps it in a shim.
  final String invocation;
}
