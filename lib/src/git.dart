/// Read-only git facts for BUILD_SHA and the clean-tree guard.
library;

import 'package:flutter_build_tools/src/runner.dart';

/// The commit and tree state of the project.
class GitInfo {
  /// Creates the facts.
  const GitInfo({required this.sha, required this.dirty});

  /// Git was not usable (not installed, not a repository).
  const GitInfo.unavailable() : sha = 'unknown', dirty = null;

  /// Short commit hash, or `unknown`.
  final String sha;

  /// True when the working tree has uncommitted or untracked changes; null
  /// when that could not be determined.
  final bool? dirty;

  /// Value of the BUILD_SHA define.
  String get buildSha => dirty == true ? '$sha-dirty' : sha;
}

/// Reads the short HEAD hash and whether the tree is dirty with read-only git
/// commands; [GitInfo.unavailable] when git cannot answer.
Future<GitInfo> readGitInfo(ProcessRunner runner, String root) async {
  try {
    final head = await runner.capture(
      ProcessSpec('git', const [
        'rev-parse',
        '--short',
        'HEAD',
      ], workingDirectory: root),
    );
    final sha = head.stdout.trim();
    if (head.exitCode != 0 || sha.isEmpty) return const GitInfo.unavailable();
    final status = await runner.capture(
      ProcessSpec('git', const [
        'status',
        '--porcelain',
      ], workingDirectory: root),
    );
    if (status.exitCode != 0) return GitInfo(sha: sha, dirty: null);
    return GitInfo(sha: sha, dirty: status.stdout.trim().isNotEmpty);
  } on ProcessStartException {
    return const GitInfo.unavailable();
  }
}
