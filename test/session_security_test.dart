import 'dart:io';

import 'package:fdb/core/commands/attach/attach.dart';
import 'package:fdb/core/commands/kill/kill.dart';
import 'package:fdb/core/commands/launch/launch.dart';
import 'package:fdb/src/controller/session.dart';
import 'package:test/test.dart';

void main() {
  test('session directory is private even when it already exists', () {
    final root = Directory.systemTemp.createTempSync('fdb-session-security-');
    addTearDown(() => root.deleteSync(recursive: true));
    final session = Directory('${root.path}/.fdb')..createSync();
    expect(Process.runSync('/bin/chmod', ['755', session.path]).exitCode, 0);
    final previousToken = File('${session.path}/controller.token')..writeAsStringSync('old-token');
    expect(Process.runSync('/bin/chmod', ['644', previousToken.path]).exitCode, 0);
    initSessionDirFromPath(session.path);

    ensureSessionDir();

    expect(FileStat.statSync(session.path).mode & 0x3f, 0);
    writeControllerToken('fixture-token');
    expect(File(controllerTokenFile).readAsStringSync(), 'fixture-token');
    expect(FileStat.statSync(controllerTokenFile).mode & 0x3f, 0);
  }, skip: Platform.isWindows);

  test('symlinked session directory and token path are refused', () {
    final root = Directory.systemTemp.createTempSync('fdb-session-link-');
    addTearDown(() => root.deleteSync(recursive: true));
    final target = Directory('${root.path}/target')..createSync();
    final link = Link('${root.path}/.fdb')..createSync(target.path);
    initSessionDirFromPath(link.path);
    expect(ensureSessionDir, throwsA(isA<FileSystemException>()));
    initSessionDirFromPath('${link.path}/');
    expect(ensureSessionDir, throwsA(isA<FileSystemException>()));

    link.deleteSync();
    final session = Directory(link.path)..createSync();
    initSessionDirFromPath(session.path);
    ensureSessionDir();
    final outside = File('${root.path}/outside')..writeAsStringSync('unchanged');
    Link(controllerTokenFile).createSync(outside.path);
    expect(() => writeControllerToken('secret'), throwsA(isA<FileSystemException>()));
    expect(outside.readAsStringSync(), 'unchanged');
  }, skip: Platform.isWindows);

  test('resolving an existing live session repairs its directory mode', () {
    final root = Directory.systemTemp.createTempSync('fdb-resolve-security-');
    addTearDown(() => root.deleteSync(recursive: true));
    final project = Directory('${root.path}/project')..createSync();
    final nested = Directory('${project.path}/lib')..createSync();
    final session = Directory('${project.path}/.fdb')..createSync();
    File('${session.path}/vm_uri.txt').writeAsStringSync('ws://127.0.0.1:1/ws');
    expect(Process.runSync('/bin/chmod', ['755', session.path]).exitCode, 0);

    expect(resolveSessionDir(start: nested), session.path);
    expect(FileStat.statSync(session.path).mode & 0x3f, 0);
  }, skip: Platform.isWindows);

  test('explicit session status repairs old directory permissions', () async {
    final root = Directory.systemTemp.createTempSync('fdb-explicit-security-');
    addTearDown(() => root.deleteSync(recursive: true));
    final session = Directory('${root.path}/.fdb')..createSync();
    File('${session.path}/vm_uri.txt').writeAsStringSync('ws://127.0.0.1:1/ws');
    expect(Process.runSync('/bin/chmod', ['755', session.path]).exitCode, 0);

    final result = await Process.run(
      Platform.resolvedExecutable,
      ['bin/fdb.dart', '--session-dir', session.path, 'status'],
      workingDirectory: Directory.current.path,
    );

    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    expect(FileStat.statSync(session.path).mode & 0x3f, 0);
  }, skip: Platform.isWindows);

  test('launch and attach reject a linked session before cleanup', () async {
    final root = Directory.systemTemp.createTempSync('fdb-cleanup-security-');
    addTearDown(() => root.deleteSync(recursive: true));
    final target = Directory('${root.path}/target')..createSync();
    final sentinel = File('${target.path}/device.txt')..writeAsStringSync('keep');
    final link = Link('${root.path}/.fdb')..createSync(target.path);

    await launchApp((
      device: 'fake-device',
      project: root.path,
      flavor: null,
      target: null,
      flutterSdk: null,
      sessionDir: link.path,
      verbose: false,
      interactive: false,
      dartDefines: <String>[],
      dartDefineFromFiles: <String>[],
      timeoutSeconds: 1,
    ));
    expect(sentinel.readAsStringSync(), 'keep');

    await attachApp((
      device: 'fake-device',
      project: root.path,
      flavor: null,
      target: null,
      flutterSdk: null,
      sessionDir: link.path,
      appId: null,
      debugUrl: null,
      verbose: false,
      interactive: false,
      timeoutSeconds: 1,
    ));
    expect(sentinel.readAsStringSync(), 'keep');
  }, skip: Platform.isWindows);

  test('automatic session lookup rejects a linked fallback before kill', () async {
    final root = Directory.systemTemp.createTempSync('fdb-kill-security-');
    addTearDown(() => root.deleteSync(recursive: true));
    final target = Directory('${root.path}/target')..createSync();
    final sentinel = File('${target.path}/device.txt')..writeAsStringSync('keep');
    Link('${root.path}/.fdb').createSync(target.path);

    expect(() => resolveSessionDir(start: root), throwsA(isA<FileSystemException>()));

    final project = Directory.current.absolute.path;
    final result = await Process.run(
      Platform.resolvedExecutable,
      [
        '--packages=$project/.dart_tool/package_config.json',
        '$project/bin/fdb.dart',
        'kill',
      ],
      workingDirectory: root.path,
    );
    expect(result.exitCode, 1, reason: '${result.stdout}\n${result.stderr}');
    expect(result.stderr, contains('Refusing a symlinked fdb session directory'));
    expect(sentinel.readAsStringSync(), 'keep');

    initSessionDirFromPath('${root.path}/.fdb');
    expect(await killApp(()), isA<KillFailed>());
    expect(sentinel.readAsStringSync(), 'keep');
  }, skip: Platform.isWindows);
}
