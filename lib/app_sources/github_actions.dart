import 'dart:convert';

import 'package:easy_localization/easy_localization.dart';
import 'package:http/http.dart';
import 'package:obtainium/custom_errors.dart';
import 'package:obtainium/services/http_service.dart';

bool githubActionsArtifactMatches(String pattern, String name) =>
    RegExp(pattern).hasMatch(name);

String githubActionsLiteralPattern(Iterable<String> parts) =>
    parts.map((part) => part.trim()).where((part) => part.isNotEmpty)
        .map(RegExp.escape).join('.*');

const githubActionsDefaultEvents = <String>{
  'push', 'schedule', 'workflow_dispatch', 'repository_dispatch',
};

const githubActionsOptionalEvents = <String>{
  'pull_request', 'pull_request_target', 'merge_group', 'workflow_run',
};

Set<String> githubActionsSelectedEvents(Map<String, dynamic> settings) {
  final saved = settings['githubActionsEvents']?.toString();
  if (saved != null) return saved.split(',').where((e) => e.isNotEmpty).toSet();
  return {
    ...githubActionsDefaultEvents,
    if (settings['githubActionsIncludePullRequests'] == true)
      'pull_request',
  };
}

bool githubActionsRunIsEligible(
  Map<String, dynamic> run, {
  required bool includePullRequests,
  Set<String>? allowedEvents,
}) {
  if (run['conclusion'] != 'success') return false;
  final event = run['event']?.toString() ?? '';
  if (allowedEvents != null) return allowedEvents.contains(event);
  return includePullRequests ||
      (!event.startsWith('pull_request') && event != 'merge_group' &&
          event != 'workflow_run');
}

class GitHubActionsRateLimitError extends RateLimitError {
  GitHubActionsRateLimitError(super.remainingMinutes);

  @override
  String toString() => '${super.toString()} ${tr('githubActionsRateLimitHint')}';
}

class GitHubActionsBuild {
  const GitHubActionsBuild(this.run, this.artifacts);

  final Map<String, dynamic> run;
  final List<Map<String, dynamic>> artifacts;

  String get version => '${run['run_number']}.${run['run_attempt'] ?? 1}';
  DateTime? get date => DateTime.tryParse(
    (run['run_started_at'] ?? run['created_at'] ?? '').toString(),
  );
}

class GitHubActionsApi {
  GitHubActionsApi(this.repoApiUrl, this.request);

  final String repoApiUrl;
  final Future<Response> Function(String) request;
  bool usedAnonymousFallback = false;
  final Map<int, List<Map<String, dynamic>>> _artifactCache = {};

  Future<dynamic> _get(String url) async {
    final res = await request(url);
    if (res.statusCode != 200) throw getObtainiumHttpError(res);
    return jsonDecode(res.body);
  }

  Future<List<Map<String, dynamic>>> _paged(
    String path, {
    Map<String, String> query = const {},
    String? listKey,
    int maxPages = 10,
  }) async {
    final result = <Map<String, dynamic>>[];
    for (var page = 1; page <= maxPages; page++) {
      final uri = Uri.parse('$repoApiUrl$path').replace(
        queryParameters: {...query, 'per_page': '100', 'page': '$page'},
      );
      final response = await _get(uri.toString());
      final list = listKey == null ? response : response[listKey];
      if (list is! List) throw NoReleasesError();
      result.addAll(list.whereType<Map<String, dynamic>>());
      if (list.length < 100) break;
    }
    return result;
  }

  Future<String> defaultBranch() async {
    final repo = await _get(repoApiUrl);
    return repo['default_branch']?.toString() ?? 'main';
  }

  Future<List<Map<String, dynamic>>> branches() => _paged('/branches');

  Future<List<Map<String, dynamic>>> workflows() =>
      _paged('/actions/workflows', listKey: 'workflows');

  Future<List<Map<String, dynamic>>> workflowRuns({
    required String workflow,
    required String branch,
  }) async {
    final runs = await _paged(
      '/actions/workflows/${Uri.encodeComponent(workflow)}/runs',
      query: {'branch': branch, 'status': 'success'},
      listKey: 'workflow_runs',
      maxPages: 1,
    );
    runs.sort((a, b) {
      final first = DateTime.tryParse(
          (a['run_started_at'] ?? a['created_at'] ?? '').toString());
      final second = DateTime.tryParse(
          (b['run_started_at'] ?? b['created_at'] ?? '').toString());
      final byDate = (second ?? DateTime(1970)).compareTo(first ?? DateTime(1970));
      if (byDate != 0) return byDate;
      final byNumber = ((b['run_number'] as num?) ?? 0)
          .compareTo((a['run_number'] as num?) ?? 0);
      if (byNumber != 0) return byNumber;
      return ((b['run_attempt'] as num?) ?? 1)
          .compareTo((a['run_attempt'] as num?) ?? 1);
    });
    return runs;
  }

  Future<List<Map<String, dynamic>>> runArtifacts(int id) async {
    if (_artifactCache.containsKey(id)) return _artifactCache[id]!;
    final artifacts = await _paged(
      '/actions/runs/$id/artifacts',
      listKey: 'artifacts',
      maxPages: 1,
    );
    final valid = artifacts
        .where((a) => a['expired'] != true && a['id'] is num).toList();
    _artifactCache[id] = valid;
    return valid;
  }

  Future<List<GitHubActionsBuild>> recentBuildsFromRuns(
    List<Map<String, dynamic>> runs, {
    required Set<String> allowedEvents,
    int count = 3,
  }) async {
    final result = <GitHubActionsBuild>[];
    for (final run in runs.where((r) => githubActionsRunIsEligible(
      r, includePullRequests: false, allowedEvents: allowedEvents,
    )).take(3)) {
      if (run['id'] is! num) continue;
      final artifacts = await runArtifacts((run['id'] as num).toInt());
      if (artifacts.isNotEmpty) result.add(GitHubActionsBuild(run, artifacts));
      if (result.length >= count) break;
    }
    return result;
  }

  Future<GitHubActionsBuild?> latestBuild({
    required String workflow,
    required String branch,
    String? artifactPattern,
    bool includePullRequests = false,
    Set<String>? allowedEvents,
  }) async {
    final runs = await workflowRuns(workflow: workflow, branch: branch);
    for (final run
        in runs
            .where(
              (r) => githubActionsRunIsEligible(
                r,
                includePullRequests: includePullRequests,
                allowedEvents: allowedEvents,
              ),
            )
            .take(10)) {
      final runId = run['id'];
      if (runId is! num) continue;
      final artifacts = await runArtifacts(runId.toInt());
      final matches = artifacts.where((artifact) {
        final name = artifact['name']?.toString() ?? '';
        return artifactPattern == null ||
            githubActionsArtifactMatches(artifactPattern, name);
      }).toList();
      if (matches.isNotEmpty) return GitHubActionsBuild(run, matches);
    }
    return null;
  }
}
