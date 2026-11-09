import 'dart:convert';

import 'package:http/http.dart';
import 'package:obtainium/custom_errors.dart';
import 'package:obtainium/services/http_service.dart';

bool githubActionsArtifactMatches(String pattern, String name) =>
    RegExp(pattern).hasMatch(name);

String githubActionsExactArtifactPattern(String name) =>
    '^${RegExp.escape(name)}\$';

bool githubActionsRunIsEligible(
  Map<String, dynamic> run, {
  required bool includePullRequests,
}) {
  if (run['conclusion'] != 'success') return false;
  final event = run['event']?.toString() ?? '';
  return includePullRequests ||
      (!event.startsWith('pull_request') && event != 'merge_group');
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

  Future<GitHubActionsBuild?> latestBuild({
    required String workflow,
    required String branch,
    String? artifactPattern,
    bool includePullRequests = false,
  }) async {
    final runs = await _paged(
      '/actions/workflows/${Uri.encodeComponent(workflow)}/runs',
      query: {'branch': branch, 'status': 'success'},
      listKey: 'workflow_runs',
      maxPages: 1,
    );
    for (final run
        in runs
            .where(
              (r) => githubActionsRunIsEligible(
                r,
                includePullRequests: includePullRequests,
              ),
            )
            .take(10)) {
      final runId = run['id'];
      if (runId is! num) continue;
      final artifacts = await _paged(
        '/actions/runs/${runId.toInt()}/artifacts',
        listKey: 'artifacts',
      );
      final matches = artifacts.where((artifact) {
        if (artifact['expired'] == true || artifact['id'] is! num) {
          return false;
        }
        final name = artifact['name']?.toString() ?? '';
        return artifactPattern == null ||
            githubActionsArtifactMatches(artifactPattern, name);
      }).toList();
      if (matches.isNotEmpty) return GitHubActionsBuild(run, matches);
    }
    return null;
  }
}
