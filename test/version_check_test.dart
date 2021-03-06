import 'dart:async';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:git/git.dart';
import 'package:mockito/mockito.dart';
import "package:test/test.dart";
import "package:flutter_plugin_tools/src/version_check_command.dart";
import 'package:pub_semver/pub_semver.dart';
import 'util.dart';

void testAllowedVersion(
  String masterVersion,
  String headVersion, {
  bool allowed = true,
  NextVersionType nextVersionType,
}) {
  final Version master = Version.parse(masterVersion);
  final Version head = Version.parse(headVersion);
  final Map<Version, NextVersionType> allowedVersions =
      getAllowedNextVersions(master, head);
  if (allowed) {
    expect(allowedVersions, contains(head));
    if (nextVersionType != null) {
      expect(allowedVersions[head], equals(nextVersionType));
    }
  } else {
    expect(allowedVersions, isNot(contains(head)));
  }
}

class MockGitDir extends Mock implements GitDir {}

class MockProcessResult extends Mock implements ProcessResult {}

void main() {
  group('$VersionCheckCommand', () {
    CommandRunner<VersionCheckCommand> runner;
    RecordingProcessRunner processRunner;
    List<List<String>> gitDirCommands;
    Map<String, String> gitShowResponses;

    setUp(() {
      gitDirCommands = <List<String>>[];
      gitShowResponses = <String, String>{};
      final MockGitDir gitDir = MockGitDir();
      when(gitDir.runCommand(any)).thenAnswer((Invocation invocation) {
        gitDirCommands.add(invocation.positionalArguments[0]);
        final MockProcessResult mockProcessResult = MockProcessResult();
        if (invocation.positionalArguments[0][0] == 'diff') {
          when<String>(mockProcessResult.stdout)
              .thenReturn("packages/plugin/pubspec.yaml");
        } else if (invocation.positionalArguments[0][0] == 'show') {
          final String response =
              gitShowResponses[invocation.positionalArguments[0][1]];
          when<String>(mockProcessResult.stdout).thenReturn(response);
        }
        return Future<ProcessResult>.value(mockProcessResult);
      });
      initializeFakePackages();
      processRunner = RecordingProcessRunner();
      final VersionCheckCommand command = VersionCheckCommand(
          mockPackagesDir, mockFileSystem,
          processRunner: processRunner, gitDir: gitDir);

      runner = CommandRunner<Null>(
          'version_check_command', 'Test for $VersionCheckCommand');
      runner.addCommand(command);
    });

    test('allows valid version', () async {
      createFakePlugin('plugin');
      gitShowResponses = <String, String>{
        'master:packages/plugin/pubspec.yaml': 'version: 0.0.1',
        'HEAD:packages/plugin/pubspec.yaml': 'version: 0.0.2',
      };
      final List<String> output = await runCapturingPrint(
          runner, <String>['version-check', '--base_sha=master']);

      expect(
        output,
        orderedEquals(<String>[
          'No version check errors found!',
        ]),
      );
      expect(gitDirCommands.length, equals(3));
      expect(
          gitDirCommands[0].join(' '), equals('diff --name-only master HEAD'));
      expect(gitDirCommands[1].join(' '),
          equals('show master:packages/plugin/pubspec.yaml'));
      expect(gitDirCommands[2].join(' '),
          equals('show HEAD:packages/plugin/pubspec.yaml'));
      cleanupPackages();
    });

    test('denies invalid version', () async {
      createFakePlugin('plugin');
      gitShowResponses = <String, String>{
        'master:packages/plugin/pubspec.yaml': 'version: 0.0.1',
        'HEAD:packages/plugin/pubspec.yaml': 'version: 0.2.0',
      };
      final Future<List<String>> result = runCapturingPrint(
          runner, <String>['version-check', '--base_sha=master']);

      await expectLater(
        result,
        throwsA(const TypeMatcher<Error>()),
      );
      expect(gitDirCommands.length, equals(3));
      expect(
          gitDirCommands[0].join(' '), equals('diff --name-only master HEAD'));
      expect(gitDirCommands[1].join(' '),
          equals('show master:packages/plugin/pubspec.yaml'));
      expect(gitDirCommands[2].join(' '),
          equals('show HEAD:packages/plugin/pubspec.yaml'));
      cleanupPackages();
    });

    test('gracefully handles missing pubspec.yaml', () async {
      createFakePlugin('plugin');
      mockFileSystem.currentDirectory
          .childDirectory('packages')
          .childDirectory('plugin')
          .childFile('pubspec.yaml')
          .deleteSync();
      final List<String> output = await runCapturingPrint(
          runner, <String>['version-check', '--base_sha=master']);

      expect(
        output,
        orderedEquals(<String>[
          'No version check errors found!',
        ]),
      );
      expect(gitDirCommands.length, equals(1));
      expect(gitDirCommands.first.join(' '),
          equals('diff --name-only master HEAD'));
      cleanupPackages();
    });
  });

  group("Pre 1.0", () {
    test("nextVersion allows patch version", () {
      testAllowedVersion("0.12.0", "0.12.0+1",
          nextVersionType: NextVersionType.PATCH);
      testAllowedVersion("0.12.0+4", "0.12.0+5",
          nextVersionType: NextVersionType.PATCH);
    });

    test("nextVersion does not allow jumping patch", () {
      testAllowedVersion("0.12.0", "0.12.0+2", allowed: false);
      testAllowedVersion("0.12.0+2", "0.12.0+4", allowed: false);
    });

    test("nextVersion does not allow going back", () {
      testAllowedVersion("0.12.0", "0.11.0", allowed: false);
      testAllowedVersion("0.12.0+2", "0.12.0+1", allowed: false);
      testAllowedVersion("0.12.0+1", "0.12.0", allowed: false);
    });

    test("nextVersion allows minor version", () {
      testAllowedVersion("0.12.0", "0.12.1",
          nextVersionType: NextVersionType.MINOR);
      testAllowedVersion("0.12.0+4", "0.12.1",
          nextVersionType: NextVersionType.MINOR);
    });

    test("nextVersion does not allow jumping minor", () {
      testAllowedVersion("0.12.0", "0.12.2", allowed: false);
      testAllowedVersion("0.12.0+2", "0.12.3", allowed: false);
    });
  });

  group("Releasing 1.0", () {
    test("nextVersion allows releasing 1.0", () {
      testAllowedVersion("0.12.0", "1.0.0",
          nextVersionType: NextVersionType.BREAKING_MAJOR);
      testAllowedVersion("0.12.0+4", "1.0.0",
          nextVersionType: NextVersionType.BREAKING_MAJOR);
    });

    test("nextVersion does not allow jumping major", () {
      testAllowedVersion("0.12.0", "2.0.0", allowed: false);
      testAllowedVersion("0.12.0+4", "2.0.0", allowed: false);
    });

    test("nextVersion does not allow un-releasing", () {
      testAllowedVersion("1.0.0", "0.12.0+4", allowed: false);
      testAllowedVersion("1.0.0", "0.12.0", allowed: false);
    });
  });

  group("Post 1.0", () {
    test("nextVersion allows patch jumps", () {
      testAllowedVersion("1.0.1", "1.0.2",
          nextVersionType: NextVersionType.PATCH);
      testAllowedVersion("1.0.0", "1.0.1",
          nextVersionType: NextVersionType.PATCH);
    });

    test("nextVersion does not allow build jumps", () {
      testAllowedVersion("1.0.1", "1.0.1+1", allowed: false);
      testAllowedVersion("1.0.0+5", "1.0.0+6", allowed: false);
    });

    test("nextVersion does not allow skipping patches", () {
      testAllowedVersion("1.0.1", "1.0.3", allowed: false);
      testAllowedVersion("1.0.0", "1.0.6", allowed: false);
    });

    test("nextVersion allows minor version jumps", () {
      testAllowedVersion("1.0.1", "1.1.0",
          nextVersionType: NextVersionType.MINOR);
      testAllowedVersion("1.0.0", "1.1.0",
          nextVersionType: NextVersionType.MINOR);
    });

    test("nextVersion does not allow skipping minor versions", () {
      testAllowedVersion("1.0.1", "1.2.0", allowed: false);
      testAllowedVersion("1.1.0", "1.3.0", allowed: false);
    });

    test("nextVersion allows breaking changes", () {
      testAllowedVersion("1.0.1", "2.0.0",
          nextVersionType: NextVersionType.BREAKING_MAJOR);
      testAllowedVersion("1.0.0", "2.0.0",
          nextVersionType: NextVersionType.BREAKING_MAJOR);
    });

    test("nextVersion does not allow skipping major versions", () {
      testAllowedVersion("1.0.1", "3.0.0", allowed: false);
      testAllowedVersion("1.1.0", "2.3.0", allowed: false);
    });
  });

  group('Pre releases', () {
    test('nextVersion allows jumping major & minor', () {
      testAllowedVersion("1.0.0+1", "1.1.0-dev", allowed: true);
      testAllowedVersion("1.0.0", "1.1.0-dev", allowed: true);
      testAllowedVersion("1.0.1", "1.1.0-test.1", allowed: true);
      testAllowedVersion("1.1.0", "2.0.0-dev.1", allowed: true);
    });

    test('nextVersion does not allow skipping major & minor versions', () {
      testAllowedVersion("1.0.0", "1.2.0-dev", allowed: false);
      testAllowedVersion("1.0.1", "1.2.0-test.1", allowed: false);
      testAllowedVersion("1.1.0", "3.0.0-dev.1", allowed: false);
    });

    test('nextVersion allows jumping pre number', () {
      testAllowedVersion("1.1.0-dev.1", "1.1.0-dev.2", allowed: true);
      testAllowedVersion("2.0.0-test.3", "2.0.0-test.4", allowed: true);
      testAllowedVersion("2.0.0-alpha.3", "2.0.0-beta.1", allowed: true);
      testAllowedVersion("2.0.0-alpha.3", "2.0.0-beta", allowed: true);
    });

    test('nextVersion does not allow downgrade', () {
      testAllowedVersion("1.1.0-dev.2", "1.1.0-dev.1", allowed: false);
      testAllowedVersion("2.0.0-test.4", "2.0.0-test.2", allowed: false);
      testAllowedVersion("2.0.1-alpha.3", "2.0.0-alpha.3", allowed: false);
      testAllowedVersion("1.0.0+3", "1.0.0-dev.1", allowed: false);
      testAllowedVersion("1.0.0", "1.0.0-beta", allowed: false);
      testAllowedVersion("1.0.0-dev.5", "1.0.0-dev.5", allowed: false);
    });

    test('nextVersion allow upgrade to stable versions', () {
      testAllowedVersion("1.1.0-dev.1", "1.1.0", allowed: true);
      testAllowedVersion("2.0.0-alpha", "2.0.0", allowed: true);
      testAllowedVersion("2.1.1-alpha.3", "2.1.1", allowed: true);
    });

    test("nextVersion does not allow usage build number with pre release", () {
      testAllowedVersion("2.0.0-alpha.3", "2.0.0+2", allowed: false);
      testAllowedVersion("2.0.0", "2.1.0-test.1+1", allowed: false);
      testAllowedVersion("2.0.0+1", "2.1.0-test.1+1", allowed: false);
      testAllowedVersion("2.0.0-dev.1", "2.1.0-dev.1", allowed: false);
      testAllowedVersion("2.0.0-dev.1", "2.0.0-dev.dev", allowed: false);
    });
  });
}
