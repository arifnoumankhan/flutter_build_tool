/// File system seam: the build tool only touches disk through [BuildFs], so
/// tests can run against an in-memory fake.
library;

import 'dart:io';

/// The file operations the build tool needs.
abstract class BuildFs {
  /// True when [path] is an existing file.
  bool fileExists(String path);

  /// True when [path] is an existing folder.
  bool dirExists(String path);

  /// The whole file as UTF-8 text.
  String readString(String path);

  /// The whole file as bytes.
  List<int> readBytes(String path);

  /// The file as a byte stream (used to hash large artifacts).
  Stream<List<int>> openRead(String path);

  /// Size of the file in bytes.
  int length(String path);

  /// Creates [path] and any missing parents.
  void createDir(String path);

  /// Writes [content], creating missing parent folders.
  void writeString(String path, String content);

  /// Writes [bytes], creating missing parent folders.
  void writeBytes(String path, List<int> bytes);

  /// No-op when the file does not exist.
  void deleteFile(String path);

  /// Recursive. No-op when the folder does not exist.
  void deleteDir(String path);

  /// Copies a file, creating missing parent folders of [to].
  void copyFile(String from, String to);

  /// Absolute paths of the files (not folders) under [dir]; empty when [dir]
  /// does not exist.
  List<String> listFiles(String dir, {bool recursive = false});

  /// First file called [name] anywhere under [root], skipping folders that
  /// cannot be read. Null when there is none.
  String? findFile(String root, String name);

  /// Creates a fresh temporary folder and returns its path.
  String createTempDir(String prefix);
}

/// The reason of [error] in a few words for a message, `Permission denied`
/// rather than the whole exception text (the operating system's wording when
/// it has one, else the exception's own).
String fileProblem(FileSystemException error) {
  final os = error.osError?.message.trim() ?? '';
  return os.isNotEmpty ? os : error.message;
}

/// [BuildFs] on the real disk.
class IoFs implements BuildFs {
  /// Creates the file system.
  const IoFs();

  @override
  bool fileExists(String path) => File(path).existsSync();

  @override
  bool dirExists(String path) => Directory(path).existsSync();

  @override
  String readString(String path) => File(path).readAsStringSync();

  @override
  List<int> readBytes(String path) => File(path).readAsBytesSync();

  @override
  Stream<List<int>> openRead(String path) => File(path).openRead();

  @override
  int length(String path) => File(path).lengthSync();

  @override
  void createDir(String path) => Directory(path).createSync(recursive: true);

  @override
  void writeString(String path, String content) {
    final file = File(path);
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(content);
  }

  @override
  void writeBytes(String path, List<int> bytes) {
    final file = File(path);
    file.parent.createSync(recursive: true);
    file.writeAsBytesSync(bytes);
  }

  @override
  void deleteFile(String path) {
    final file = File(path);
    if (file.existsSync()) file.deleteSync();
  }

  @override
  void deleteDir(String path) {
    final dir = Directory(path);
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  }

  @override
  void copyFile(String from, String to) {
    File(to).parent.createSync(recursive: true);
    File(from).copySync(to);
  }

  @override
  List<String> listFiles(String dir, {bool recursive = false}) {
    final directory = Directory(dir);
    if (!directory.existsSync()) return const [];
    return [
      for (final entity in directory.listSync(
        recursive: recursive,
        followLinks: false,
      ))
        if (entity is File) entity.path,
    ];
  }

  @override
  String? findFile(String root, String name) {
    final pending = <Directory>[Directory(root)];
    while (pending.isNotEmpty) {
      final dir = pending.removeLast();
      final List<FileSystemEntity> children;
      try {
        children = dir.listSync(followLinks: false);
      } on FileSystemException {
        continue; // Unreadable folder (permissions): keep searching elsewhere.
      }
      for (final child in children) {
        if (child is Directory) {
          pending.add(child);
        } else if (child is File &&
            child.uri.pathSegments.last.toLowerCase() == name.toLowerCase()) {
          return child.path;
        }
      }
    }
    return null;
  }

  @override
  String createTempDir(String prefix) =>
      Directory.systemTemp.createTempSync(prefix).path;
}
