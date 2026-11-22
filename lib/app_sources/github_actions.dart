import 'dart:convert';

import 'package:easy_localization/easy_localization.dart';
import 'package:http/http.dart';
import 'package:obtainium/custom_errors.dart';
import 'package:obtainium/services/http_service.dart';

/// GitHub upload labels are distinct from the filenames inside a download.
bool actionsArtifactNameMatches(String selected, String name) =>
    selected == name;

/// Plain-text filename portions, one per line, matched literally in order.
String actionsLiteralFilenamePattern(Iterable<String> fragments) => fragments
    .map((s) => s.trim())
    .where((s) => s.isNotEmpty)
    .map(RegExp.escape)
    .join('.*');

bool actionsFileMatches(String pattern, String filename) =>
    pattern.isEmpty || RegExp(pattern).hasMatch(filename);

/// Exact upload-label selection OR an explicit nonempty upload-name pattern.
bool actionsUploadNameMatches(String name, {
  required bool useText,
  required String exactName,
  required String pattern,
}) => useText
    ? pattern.isNotEmpty && actionsFileMatches(pattern, name)
    : exactName.isNotEmpty && actionsArtifactNameMatches(exactName, name);

const githubActionsDefaultEvents = <String>{
  'push', 'schedule', 'workflow_dispatch', 'repository_dispatch',
};
const githubActionsOptionalEvents = <String>{
  'pull_request', 'pull_request_target', 'merge_group', 'workflow_run',
};

Set<String> githubActionsSelectedEvents(Map<String, dynamic> settings) {
  final value = settings['githubActionsEvents']?.toString();
  return value == null
      ? {...githubActionsDefaultEvents}
      : value.split(',').where((s) => s.isNotEmpty).toSet();
}

bool githubActionsRunIsEligible(Map<String, dynamic> run,
    Set<String> allowedEvents) =>
    run['conclusion'] == 'success' &&
    allowedEvents.contains(run['event']?.toString() ?? '');

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
      (run['run_started_at'] ?? run['created_at'] ?? '').toString());
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

  Future<List<Map<String, dynamic>>> _paged(String path, {
    Map<String, String> query = const {},
    String? listKey,
    int maxPages = 10,
  }) async {
    final items = <Map<String, dynamic>>[];
    for (var page = 1; page <= maxPages; page++) {
      final url = Uri.parse('$repoApiUrl$path').replace(queryParameters: {
        ...query, 'per_page': '100', 'page': '$page',
      });
      final response = await _get(url.toString());
      final list = listKey == null ? response : response[listKey];
      if (list is! List) throw NoReleasesError();
      items.addAll(list.whereType<Map<String, dynamic>>());
      if (list.length < 100) break;
    }
    return items;
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
      listKey: 'workflow_runs', maxPages: 1,
    );
    runs.sort((a, b) {
      DateTime date(Map<String, dynamic> run) => DateTime.tryParse(
          (run['run_started_at'] ?? run['created_at'] ?? '').toString()) ??
          DateTime.fromMillisecondsSinceEpoch(0);
      final byDate = date(b).compareTo(date(a));
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
    final artifacts = await _paged('/actions/runs/$id/artifacts',
        listKey: 'artifacts', maxPages: 1);
    final valid = artifacts.where((item) =>
        item['expired'] != true && item['id'] is num).toList();
    _artifactCache[id] = valid;
    return valid;
  }

  /// Inspect a batch of eligible runs. Keep runs without uploads so the
  /// picker can show exactly which successful runs were examined.
  /// The caller may request successive groups of ten, up to 100 runs total.
  Future<List<GitHubActionsBuild>> recentBuildsFromRuns(
      List<Map<String, dynamic>> runs, {
    required Set<String> allowedEvents,
    int start = 0,
    int count = 10,
  }) async {
    final eligible = runs.where((r) =>
        githubActionsRunIsEligible(r, allowedEvents)).take(100).toList();
    final builds = <GitHubActionsBuild>[];
    for (final run in eligible.skip(start).take(count)) {
      final artifacts = run['id'] is num
          ? await runArtifacts((run['id'] as num).toInt())
          : <Map<String, dynamic>>[];
      builds.add(GitHubActionsBuild(run, artifacts));
    }
    return builds;
  }

  /// Find the latest run with one upload matching the saved selection rule.
  /// An ambiguous run is an error, not a reason to choose an arbitrary upload.
  Future<GitHubActionsBuild?> latestBuild({
    required String workflow,
    required String branch,
    required String artifactName,
    required bool uploadUseText,
    required String uploadPattern,
    required Set<String> allowedEvents,
  }) async {
    final runs = await workflowRuns(workflow: workflow, branch: branch);
    final eligible = runs.where((r) =>
        githubActionsRunIsEligible(r, allowedEvents)).take(100).toList();
    // One upload-metadata request per run; continue in groups of ten only
    // as needed. Do not inspect all hundred when the newest run matches.
    for (var start = 0; start < eligible.length; start += 10) {
      for (final run in eligible.skip(start).take(10)) {
        if (run['id'] is! num) continue;
        final artifacts = await runArtifacts((run['id'] as num).toInt());
        final matches = artifacts.where((item) => actionsUploadNameMatches(
          item['name']?.toString() ?? '',
          useText: uploadUseText,
          exactName: artifactName,
          pattern: uploadPattern,
        )).toList();
        if (matches.length > 1) {
          throw ObtainiumError(tr('githubActionsMultipleUploads'));
        }
        if (matches.length == 1) return GitHubActionsBuild(run, matches);
      }
    }
    return null;
  }
}
