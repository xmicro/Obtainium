import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:obtainium/app_sources/github_actions.dart';

void main() {
  group('GitHub Actions artifact matching', () {
    test('exact selection escapes regex characters', () {
      final pattern = githubActionsExactArtifactPattern('app.v2-release');
      expect(githubActionsArtifactMatches(pattern, 'app.v2-release'), isTrue);
      expect(githubActionsArtifactMatches(pattern, 'appXv2-release'), isFalse);
      expect(githubActionsArtifactMatches(pattern, 'app.v2-release-other'), isFalse);
    });

    test('a wildcard tracks changing artifact names', () {
      expect(githubActionsArtifactMatches(r'^app-.*-release$', 'app-24-release'), isTrue);
      expect(githubActionsArtifactMatches(r'^app-.*-release$', 'app-24-debug'), isFalse);
    });

    test('pull requests are excluded unless opted in', () {
      final run = {'conclusion': 'success', 'event': 'pull_request'};
      expect(githubActionsRunIsEligible(run, includePullRequests: false), isFalse);
      expect(githubActionsRunIsEligible(run, includePullRequests: true), isTrue);
      expect(githubActionsRunIsEligible({'conclusion': 'failure', 'event': 'push'}, includePullRequests: true), isFalse);
      expect(githubActionsRunIsEligible({'conclusion': 'success', 'event': 'workflow_run'}, includePullRequests: false), isTrue);
    });
  });

  group('GitHub Actions API', () {
    GitHubActionsApi apiFor(
      List<Map<String, dynamic>> runs,
      Map<int, List<Map<String, dynamic>>> artifacts, {
      List<String>? requested,
    }) {
      return GitHubActionsApi('https://api.github.com/repos/example/app', (url) async {
        requested?.add(url);
        final uri = Uri.parse(url);
        if (uri.path.endsWith('/runs')) {
          return http.Response(jsonEncode({'workflow_runs': runs}), 200);
        }
        final match = RegExp(r'/runs/(\d+)/artifacts$').firstMatch(uri.path);
        if (match != null) {
          return http.Response(jsonEncode({'artifacts': artifacts[int.parse(match.group(1)!)] ?? []}), 200);
        }
        return http.Response('Not Found', 404);
      });
    }

    Map<String, dynamic> run(int id, int number, {String event = 'push', int attempt = 1}) => {
      'id': id,
      'run_number': number,
      'run_attempt': attempt,
      'event': event,
      'conclusion': 'success',
      'created_at': '2026-01-01T00:00:00Z',
    };

    Map<String, dynamic> artifact(int id, String name, {bool expired = false}) => {
      'id': id,
      'name': name,
      'expired': expired,
    };

    test('chooses newest matching successful run and preserves rerun attempt', () async {
      final requested = <String>[];
      final api = apiFor(
        [run(30, 42, attempt: 2), run(29, 41)],
        {30: [artifact(8, 'app-42-release'), artifact(9, 'app-42-debug')]},
        requested: requested,
      );
      final build = await api.latestBuild(
        workflow: 'ci.yml',
        branch: 'master',
        artifactPattern: r'^app-.*-release$',
      );
      expect(build!.version, '42.2');
      expect(build.artifacts.single['id'], 8);
      expect(requested.first, contains('branch=master'));
      expect(requested.first, contains('status=success'));
      expect(requested.first, contains('ci.yml'));
    });

    test('skips runs without matching unexpired artifacts', () async {
      final api = apiFor(
        [run(30, 42), run(29, 41)],
        {30: [artifact(8, 'app-42-release', expired: true)], 29: [artifact(7, 'app-41-release')]},
      );
      final build = await api.latestBuild(
        workflow: 'ci.yml',
        branch: 'main',
        artifactPattern: r'^app-.*-release$',
      );
      expect(build!.version, '41.1');
    });

    test('excludes pull request run by default', () async {
      final api = apiFor(
        [run(30, 42, event: 'pull_request'), run(29, 41)],
        {30: [artifact(8, 'app-release')], 29: [artifact(7, 'app-release')]},
      );
      final build = await api.latestBuild(workflow: 'ci.yml', branch: 'main', artifactPattern: 'app-release');
      expect(build!.version, '41.1');
    });

    test('allows pull request run when enabled', () async {
      final api = apiFor(
        [run(30, 42, event: 'pull_request')],
        {30: [artifact(8, 'app-release')]},
      );
      final build = await api.latestBuild(workflow: 'ci.yml', branch: 'main', includePullRequests: true);
      expect(build!.version, '42.1');
    });

    test('returns null if no run has a matching artifact', () async {
      final api = apiFor([run(30, 42)], {30: []});
      expect(await api.latestBuild(workflow: 'ci.yml', branch: 'main', artifactPattern: 'app'), isNull);
    });
  });
}
