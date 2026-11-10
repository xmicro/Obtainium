import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:obtainium/app_sources/github_actions.dart';

void main() {
  group('GitHub Actions artifact matching', () {
    test('literal fragments escape punctuation and match changing versions', () {
      final pattern = githubActionsLiteralPattern(
        ['Neo.Zygisk-', '-release(arm64)'],
      );
      expect(githubActionsArtifactMatches(
          pattern, 'Neo.Zygisk-2.4-release(arm64)'), isTrue);
      expect(githubActionsArtifactMatches(
          pattern, 'NeoXZygisk-2.4-release(arm64)'), isFalse);
      expect(githubActionsArtifactMatches(
          pattern, 'Neo.Zygisk-2.4-debug(arm64)'), isFalse);
    });

    test('empty fragments cannot accidentally match everything', () {
      expect(githubActionsLiteralPattern(['', '  ']), isEmpty);
    });

    test('defaults exclude direct PRs and chained runs', () {
      expect(githubActionsSelectedEvents({}), contains('push'));
      expect(githubActionsSelectedEvents({}), isNot(contains('workflow_run')));
      expect(githubActionsSelectedEvents({}), isNot(contains('pull_request')));
      final included = githubActionsSelectedEvents({
        'githubActionsEvents': 'push,pull_request,workflow_run',
      });
      for (final event in ['push', 'pull_request', 'workflow_run']) {
        expect(githubActionsRunIsEligible({
          'conclusion': 'success', 'event': event,
        }, includePullRequests: false, allowedEvents: included), isTrue);
      }
      expect(githubActionsRunIsEligible({
        'conclusion': 'failure', 'event': 'push',
      }, includePullRequests: true, allowedEvents: included), isFalse);
    });
  });

  group('GitHub Actions API', () {
    GitHubActionsApi apiFor(
      List<Map<String, dynamic>> runs,
      Map<int, List<Map<String, dynamic>>> artifacts, {
      List<String>? requested,
    }) => GitHubActionsApi(
      'https://api.github.com/repos/example/app',
      (url) async {
        requested?.add(url);
        final uri = Uri.parse(url);
        if (uri.path.endsWith('/runs')) {
          return http.Response(jsonEncode({'workflow_runs': runs}), 200);
        }
        final match = RegExp(r'/runs/(\d+)/artifacts$')
            .firstMatch(uri.path);
        if (match != null) {
          return http.Response(jsonEncode({
            'artifacts': artifacts[int.parse(match.group(1)!)] ?? [],
          }), 200);
        }
        return http.Response('Not Found', 404);
      },
    );

    Map<String, dynamic> run(
      int id, int number, {
      String event = 'push',
      int attempt = 1,
      String started = '2026-01-01T00:00:00Z',
    }) => {
      'id': id,
      'run_number': number,
      'run_attempt': attempt,
      'event': event,
      'conclusion': 'success',
      'run_started_at': started,
    };

    Map<String, dynamic> artifact(int id, String name, {
      bool expired = false,
    }) => {'id': id, 'name': name, 'expired': expired};

    test('selects newest run by start date and preserves rerun attempt',
        () async {
      final requested = <String>[];
      final api = apiFor([
        run(29, 41, started: '2026-01-01T00:00:00Z'),
        run(30, 42, attempt: 2, started: '2026-01-02T00:00:00Z'),
      ], {
        29: [artifact(7, 'app-41-release')],
        30: [artifact(8, 'app-42-release'), artifact(9, 'app-42-debug')],
      }, requested: requested);
      final build = await api.latestBuild(
        workflow: 'ci.yml',
        branch: 'master',
        artifactPattern: r'^app-.*-release$',
        allowedEvents: githubActionsDefaultEvents,
      );
      expect(build!.version, '42.2');
      expect(build.artifacts.single['id'], 8);
      expect(requested.first, contains('branch=master'));
      expect(requested.first, contains('status=success'));
      expect(requested.first, contains('ci.yml'));
    });

    test('ignores expired artifacts and caches run listings', () async {
      final requested = <String>[];
      final api = apiFor([
        run(30, 42), run(29, 41),
      ], {
        30: [artifact(8, 'app-release', expired: true)],
        29: [artifact(7, 'app-release')],
      }, requested: requested);
      final build = await api.latestBuild(
        workflow: 'ci.yml',
        branch: 'main',
        artifactPattern: 'app-release',
      );
      expect(build!.version, '41.1');
      await api.runArtifacts(29);
      expect(requested.where(
          (url) => url.contains('/runs/29/artifacts')).length, 1);
    });

    test('three-run preview respects event opt-in', () async {
      final api = apiFor([
        run(30, 42, event: 'workflow_run'),
        run(29, 41),
        run(28, 40, event: 'pull_request'),
      ], {
        30: [artifact(8, 'app-ci')],
        29: [artifact(7, 'app-release')],
        28: [artifact(6, 'app-pr')],
      });
      final runs = await api.workflowRuns(workflow: 'ci', branch: 'main');
      final builds = await api.recentBuildsFromRuns(
        runs,
        allowedEvents: githubActionsDefaultEvents,
      );
      expect(builds.map((b) => b.run['id']), [29]);
      final optedIn = await api.recentBuildsFromRuns(
        runs,
        allowedEvents: {
          ...githubActionsDefaultEvents,
          'workflow_run', 'pull_request',
        },
      );
      expect(optedIn.length, 3);
    });
  });
}
