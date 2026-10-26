import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:fdb/src/controller/pid_liveness.dart';
import 'package:path/path.dart' as path;

/// Name of the session directory created inside the Flutter project.
const sessionDirName = '.fdb';

/// The active session directory. Defaults to `<CWD>/.fdb/`.
String _sessionDir = '${Directory.current.path}/$sessionDirName';

/// Override the session directory from a Flutter project path.
void initSessionDir(String projectPath) {
  final absolute = path.normalize(Directory(projectPath).absolute.path);
  _sessionDir = path.join(absolute, sessionDirName);
}

/// Override the session directory from an explicit `--session-dir` flag.
void initSessionDirFromPath(String sessionDirPath) {
  _sessionDir = path.normalize(Directory(sessionDirPath).absolute.path);
}

/// Auto-locate the session directory by walking up from [start].
String? resolveSessionDir({Directory? start}) {
  final cwd = (start ?? Directory.current).absolute.path;
  final home = Platform.environment['HOME'] ?? '/';

  var current = Directory(cwd);

  while (true) {
    final candidate = Directory('${current.path}/$sessionDirName');
    final candidateType = FileSystemEntity.typeSync(candidate.path, followLinks: false);
    if (candidateType == FileSystemEntityType.link) {
      throw FileSystemException('Refusing a symlinked fdb session directory', candidate.path);
    }
    if (candidateType == FileSystemEntityType.directory) {
      final alive = _hasLiveSessionState(candidate.path);

      if (alive) {
        final resolved = candidate.absolute.path;
        if (resolved != Directory('$cwd/$sessionDirName').absolute.path) {
          stderr.writeln('INFO: Using session dir from ${current.path}');
        }
        _sessionDir = resolved;
        ensureSessionDir();
        return resolved;
      }
    }

    final parent = current.parent;
    final atHome = current.absolute.path == Directory(home).absolute.path;
    final atRoot = parent.path == current.path;
    if (atHome || atRoot) break;
    current = parent;
  }

  _sessionDir = '$cwd/$sessionDirName';
  return null;
}

bool _hasLiveSessionState(String candidatePath) {
  for (final path in [
    '$candidatePath/controller.pid',
    '$candidatePath/fdb.app_pid',
    '$candidatePath/fdb.pid',
  ]) {
    if (_isPidFileAlive(path)) {
      return true;
    }
  }

  return File('$candidatePath/vm_uri.txt').existsSync();
}

bool _isPidFileAlive(String path) {
  final file = File(path);
  if (!file.existsSync()) {
    return false;
  }

  final pid = int.tryParse(file.readAsStringSync().trim());
  if (pid == null) {
    return false;
  }

  return isProcessAlive(pid);
}

/// Ensure the session directory exists and return its path.
String ensureSessionDir() {
  final dir = Directory(_sessionDir);
  if (FileSystemEntity.typeSync(_sessionDir, followLinks: false) == FileSystemEntityType.link) {
    throw FileSystemException('Refusing a symlinked fdb session directory', _sessionDir);
  }
  if (!dir.existsSync()) dir.createSync(recursive: true);
  if (FileSystemEntity.typeSync(_sessionDir, followLinks: false) != FileSystemEntityType.directory) {
    throw FileSystemException('fdb session path is not a directory', _sessionDir);
  }
  if (!Platform.isWindows) _setPrivateMode(_sessionDir, 0x1c0); // 0700
  return _sessionDir;
}

/// Replace the controller credential only after the session directory is
/// private. Reject links, which could redirect a token write or disclose it.
void writeControllerToken(String token) {
  ensureSessionDir();
  final file = File(controllerTokenFile);
  final type = FileSystemEntity.typeSync(file.path, followLinks: false);
  if (type != FileSystemEntityType.notFound && type != FileSystemEntityType.file) {
    throw FileSystemException('Refusing a non-file controller token path', file.path);
  }
  if (type == FileSystemEntityType.file) file.deleteSync();
  try {
    file.writeAsStringSync(token);
    if (!Platform.isWindows) _setPrivateMode(file.path, 0x180); // 0600
  } catch (_) {
    if (FileSystemEntity.typeSync(file.path, followLinks: false) == FileSystemEntityType.file) {
      file.deleteSync();
    }
    rethrow;
  }
}

final int Function(Pointer<Utf8>, int) _chmodLinux = DynamicLibrary.process()
    .lookupFunction<Int32 Function(Pointer<Utf8>, Uint32), int Function(Pointer<Utf8>, int)>('chmod');

final int Function(Pointer<Utf8>, int) _chmodMac = DynamicLibrary.process()
    .lookupFunction<Int32 Function(Pointer<Utf8>, Uint16), int Function(Pointer<Utf8>, int)>('chmod');

void _setPrivateMode(String path, int mode) {
  final nativePath = path.toNativeUtf8();
  try {
    final chmod = Platform.isMacOS ? _chmodMac : _chmodLinux;
    if (chmod(nativePath, mode) != 0) {
      throw FileSystemException('Unable to secure fdb session state', path);
    }
  } finally {
    malloc.free(nativePath);
  }
}

String get sessionDirPath => _sessionDir;

String get pidFile => '$_sessionDir/fdb.pid';
String get appPidFile => '$_sessionDir/fdb.app_pid';
String get controllerPidFile => '$_sessionDir/controller.pid';
String get controllerPortFile => '$_sessionDir/controller.port';
String get controllerTokenFile => '$_sessionDir/controller.token';
String get logFile => '$_sessionDir/logs.txt';
String get logCollectorPidFile => '$_sessionDir/log_collector.pid';
String get logCollectorScript => '$_sessionDir/log_collector.dart';
String get vmUriFile => '$_sessionDir/vm_uri.txt';
String get launcherScript => '$_sessionDir/launcher.sh';
String get deviceFile => '$_sessionDir/device.txt';
String get platformFile => '$_sessionDir/platform.txt';
String get appIdFile => '$_sessionDir/app_id.txt';
String get projectPathFile => '$_sessionDir/project_path.txt';
String get defaultScreenshotPath => '$_sessionDir/screenshot.png';
