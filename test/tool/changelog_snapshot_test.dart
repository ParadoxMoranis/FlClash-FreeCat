import 'dart:io';

import 'package:test/test.dart';

void main() {
  final root = Directory.current.path;
  late Directory directory;

  setUp(() {
    directory = Directory.systemTemp.createTempSync(
      'freecat-changelog-snapshot-',
    );
    for (final name in ['CHANGELOG.md', 'changelog.json']) {
      File('$root/$name').copySync('${directory.path}/$name');
    }
  });

  tearDown(() => directory.deleteSync(recursive: true));

  ProcessResult verify() => Process.runSync('dart', [
    '--packages=$root/.dart_tool/package_config.json',
    '$root/tool/changelog.dart',
    '--root',
    directory.path,
    'verify',
    '--snapshot-only',
  ]);

  test('validates imported release history without a Git repository', () {
    final result = verify();
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    expect(result.stdout, contains('JSON and Markdown are consistent'));
  });

  test('rejects divergent imported Markdown without Git tags', () {
    final markdown = File('${directory.path}/CHANGELOG.md');
    markdown.writeAsStringSync(
      markdown.readAsStringSync().replaceFirst('## ', '## Changed '),
    );
    final result = verify();
    expect(result.exitCode, 1);
    expect(result.stderr, contains('does not match changelog.json'));
  });
}
