/// Free disk space on the build volume, read with `df`. A Flutter build writes
/// hundreds of MB and a full disk makes it fail halfway, so the tool warns
/// (see the `low-disk` guard) but never refuses.
library;

import 'dart:convert';

import 'package:flutter_build_tools/src/environment.dart';
import 'package:flutter_build_tools/src/model.dart';
import 'package:flutter_build_tools/src/runner.dart';

/// Free bytes on the volume that holds the repository, or null when unknown:
/// on Windows (no `df`), when `df` is missing or fails, or when its output is
/// not understood. Unknown never blocks a build.
Future<int?> freeDiskBytes(BuildEnvironment env) async {
  if (env.host == HostOs.windows) return null;
  try {
    final result = await env.runner.capture(
      ProcessSpec('df', ['-Pk', env.root]),
    );
    return result.exitCode == 0 ? parseDfFreeBytes(result.stdout) : null;
  } on ProcessStartException {
    return null;
  }
}

/// The "Available" column of POSIX `df -P` output (one header, one data line)
/// in bytes, or null when [output] is not in that format. The block size is
/// read from the header (`1024-blocks`); `df -Pk` always says 1024.
int? parseDfFreeBytes(String output) {
  final lines = LineSplitter.split(
    output,
  ).where((line) => line.trim().isNotEmpty).toList();
  if (lines.length < 2) return null;
  final blockSize =
      int.tryParse(
        RegExp(r'(\d+)-blocks').firstMatch(lines.first)?.group(1) ?? '',
      ) ??
      1024;
  // Filesystem and mount point may contain spaces; the four numbers and the
  // capacity percentage in the middle do not.
  final match = RegExp(
    r'^.*?\s+\d+\s+\d+\s+(\d+)\s+\d+%\s+.*$',
  ).firstMatch(lines.last);
  final blocks = int.tryParse(match?.group(1) ?? '');
  return blocks == null ? null : blocks * blockSize;
}
