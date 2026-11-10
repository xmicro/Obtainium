import 'dart:async';
import 'dart:io';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter_archive/flutter_archive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:obtainium/app_sources/github.dart';
import 'package:obtainium/app_sources/github_actions.dart';
import 'package:obtainium/components/ui_widgets.dart';
import 'package:obtainium/services/github_actions_archive_service.dart';

class GitHubActionsPickerButton extends StatelessWidget {
  const GitHubActionsPickerButton({
    super.key,
    required this.source,
    required this.url,
    required this.settings,
    required this.onSelected,
  });

  final GitHub source;
  final String url;
  final Map<String, dynamic> settings;
  final ValueChanged<Map<String, dynamic>> onSelected;

  @override
  Widget build(BuildContext context) => OutlinedButton.icon(
    icon: const Icon(Icons.account_tree_outlined),
    label: Text(tr('githubActionsChooseArtifact')),
    onPressed: () async {
      try {
        final selected = await showDialog<Map<String, dynamic>>(
          context: context,
          builder: (_) => _GitHubActionsPicker(
            source: source,
            url: source.standardizeUrl(url),
            settings: settings,
          ),
        );
        if (selected != null && context.mounted) onSelected(selected);
      } catch (err) {
        if (context.mounted) showError(err, context);
      }
    },
  );
}

class _GitHubActionsPicker extends StatefulWidget {
  const _GitHubActionsPicker({
    required this.source,
    required this.url,
    required this.settings,
  });

  final GitHub source;
  final String url;
  final Map<String, dynamic> settings;

  @override
  State<_GitHubActionsPicker> createState() => _GitHubActionsPickerState();
}

class _GitHubActionsPickerState extends State<_GitHubActionsPicker> {
  GitHubActionsApi? _api;
  List<String> _branches = [];
  List<Map<String, dynamic>> _workflows = [];
  List<Map<String, dynamic>> _runs = [];
  List<GitHubActionsBuild> _builds = [];
  final Map<int, List<String>> _archiveFiles = {};
  Set<String> _events = {};
  String? _branch;
  String? _workflow;
  String? _artifact;
  Object? _error;
  bool _loadingSetup = true;
  bool _loadingArtifacts = false;
  bool _advanced = false;
  int? _loadingArchive;
  int _requestSequence = 0;
  final _nameParts = TextEditingController();
  final _nameRegex = TextEditingController();
  final _apkParts = TextEditingController();
  final _apkRegex = TextEditingController();

  @override
  void initState() {
    super.initState();
    _events = githubActionsSelectedEvents(widget.settings);
    _advanced = widget.settings['githubActionsUseRegex'] == true ||
        (widget.settings['githubActionsArtifactPattern'] != null &&
            widget.settings['githubActionsMatchParts'] == null);
    _nameParts.text = widget.settings['githubActionsMatchParts']?.toString() ?? '';
    _nameRegex.text =
        widget.settings['githubActionsArtifactPattern']?.toString() ?? '';
    _apkParts.text =
        widget.settings['githubActionsApkMatchParts']?.toString() ?? '';
    _apkRegex.text =
        widget.settings['zippedApkFilterRegEx']?.toString() ?? '';
    unawaited(_loadSetup());
  }

  @override
  void dispose() {
    _nameParts.dispose();
    _nameRegex.dispose();
    _apkParts.dispose();
    _apkRegex.dispose();
    super.dispose();
  }

  String get _artifactPattern => _advanced
      ? _nameRegex.text.trim()
      : githubActionsLiteralPattern(_nameParts.text.split('\n'));

  String get _apkPattern => _advanced
      ? _apkRegex.text.trim()
      : githubActionsLiteralPattern(_apkParts.text.split('\n'));

  RegExp? _compile(String pattern) {
    if (pattern.isEmpty) return null;
    try {
      return RegExp(pattern);
    } catch (_) {
      return null;
    }
  }

  bool _matchesArtifact(String name) =>
      _compile(_artifactPattern)?.hasMatch(name) ?? false;

  bool _matchesApk(String path) {
    final pattern = _apkPattern;
    return pattern.isEmpty || (_compile(pattern)?.hasMatch(path) ?? false);
  }

  bool get _validPattern {
    if (_artifact == null || _compile(_artifactPattern) == null ||
        (_apkPattern.isNotEmpty && _compile(_apkPattern) == null) ||
        _builds.isEmpty) return false;
    if (!_matchesArtifact(_artifact!)) return false;
    if (!_builds.first.artifacts.any(
        (a) => a['name']?.toString() == _artifact)) return false;
    for (final build in _builds) {
      final matches = build.artifacts.where(
          (a) => _matchesArtifact(a['name']?.toString() ?? '')).toList();
      if (matches.length > 1) return false;
    }
    return true;
  }

  Future<void> _loadSetup() async {
    try {
      final api = await widget.source.actionsApi(widget.url, widget.settings);
      final responses = await Future.wait<dynamic>([
        api.defaultBranch(),
        api.branches(),
        api.workflows(),
      ]);
      if (!mounted) return;
      final branches = (responses[1] as List<Map<String, dynamic>>)
          .map((item) => item['name']?.toString() ?? '')
          .where((name) => name.isNotEmpty).toList();
      final workflows = (responses[2] as List<Map<String, dynamic>>)
          .where((item) => item['state'] == 'active').toList();
      final savedBranch = widget.settings['githubActionsBranch']?.toString();
      final savedWorkflow = widget.settings['githubActionsWorkflow']?.toString();
      setState(() {
        _api = api;
        _branches = branches;
        _workflows = workflows;
        _branch = branches.contains(savedBranch)
            ? savedBranch
            : branches.contains(responses[0])
                ? responses[0] as String
                : branches.firstOrNull;
        _workflow = workflows.any(
            (item) => item['id'].toString() == savedWorkflow)
            ? savedWorkflow : null;
        _loadingSetup = false;
      });
      if (_branch != null && _workflow != null) unawaited(_loadRuns());
    } catch (err) {
      if (!mounted) return;
      setState(() {
        _error = err;
        _loadingSetup = false;
      });
    }
  }

  Future<void> _loadRuns() async {
    final api = _api;
    final branch = _branch;
    final workflow = _workflow;
    final sequence = ++_requestSequence;
    setState(() {
      _loadingArtifacts = branch != null && workflow != null;
      _runs = [];
      _builds = [];
      _error = null;
    });
    if (api == null || branch == null || workflow == null) return;
    try {
      final runs = await api.workflowRuns(workflow: workflow, branch: branch);
      if (!mounted || sequence != _requestSequence) return;
      _runs = runs;
      await _refreshBuilds(sequence);
    } catch (err) {
      if (!mounted || sequence != _requestSequence) return;
      setState(() {
        _error = err;
        _loadingArtifacts = false;
      });
    }
  }

  Future<void> _refreshBuilds(int sequence) async {
    final api = _api;
    if (api == null) return;
    setState(() => _loadingArtifacts = true);
    try {
      final builds = await api.recentBuildsFromRuns(
        _runs, allowedEvents: _events,
      );
      if (!mounted || sequence != _requestSequence) return;
      final names = builds.isEmpty
          ? <String>[]
          : builds.first.artifacts
              .map((a) => a['name']?.toString() ?? '').toList();
      final saved = widget.settings['githubActionsArtifactName']?.toString();
      setState(() {
        _builds = builds;
        if (!names.contains(_artifact)) {
          _artifact = names.contains(saved) ? saved : null;
        }
        _loadingArtifacts = false;
      });
    } catch (err) {
      if (!mounted || sequence != _requestSequence) return;
      setState(() {
        _error = err;
        _loadingArtifacts = false;
      });
    }
  }

  void _toggleEvent(String event, bool selected) {
    setState(() {
      if (selected) {
        _events.add(event);
      } else {
        _events.remove(event);
      }
    });
    if (_runs.isNotEmpty) unawaited(_refreshBuilds(++_requestSequence));
  }

  Future<void> _viewFiles(Map<String, dynamic> artifact) async {
    final id = (artifact['id'] as num).toInt();
    if (_archiveFiles.containsKey(id)) return;
    setState(() {
      _loadingArchive = id;
      _error = null;
    });
    Directory? directory;
    try {
      directory = await Directory.systemTemp.createTemp('obtainium-actions-');
      final api = _api!;
      var url = await widget.source.actionsArtifactUrl(
        widget.url, widget.settings, api, id,
      );
      var response = await widget.source.sourceRequest(url, widget.settings);
      if (Uri.parse(url).host != 'nightly.link' &&
          (response.statusCode == 401 || response.statusCode == 403) &&
          response.headers['x-ratelimit-remaining'] != '0' &&
          !response.headers.containsKey('retry-after')) {
        url = GitHub.nightlyActionsArtifactUrl(widget.url, id);
        response = await widget.source.sourceRequest(
          url, Map<String, dynamic>.from(widget.settings)..['skipAuth'] = true,
        );
      }
      if (response.statusCode != 200) {
        throw Exception(tr('githubActionsArchiveFailed'));
      }
      final outerZip = File('${directory.path}/artifact.zip');
      await outerZip.writeAsBytes(response.bodyBytes);
      final extracted = Directory('${directory.path}/contents');
      await ZipFile.extractToDirectory(
        zipFile: outerZip, destinationDir: extracted,
      );
      await extractOneNestedActionZipLevel(extracted);
      final paths = actionArchiveFilePaths(extracted);
      if (mounted) setState(() => _archiveFiles[id] = paths);
    } catch (err) {
      if (mounted) setState(() => _error = err);
    } finally {
      if (directory?.existsSync() == true) {
        await directory!.delete(recursive: true);
      }
      if (mounted) setState(() => _loadingArchive = null);
    }
  }

  Widget _artifactPreview(GitHubActionsBuild build) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        '${tr('githubActionsRun')} ${build.version} '
        '(${build.run['event']})',
        style: Theme.of(context).textTheme.titleSmall,
      ),
      ...build.artifacts.map((artifact) {
        final id = (artifact['id'] as num).toInt();
        final name = artifact['name']?.toString() ?? '';
        final matched = _matchesArtifact(name);
        final files = _archiveFiles[id];
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  matched ? Icons.check_circle_outline : Icons.cancel_outlined,
                  color: matched ? Colors.green : Colors.red,
                  size: 18,
                ),
                const SizedBox(width: 6),
                Expanded(child: Text(name, overflow: TextOverflow.ellipsis)),
                TextButton(
                  onPressed: _loadingArchive == null
                      ? () => unawaited(_viewFiles(artifact)) : null,
                  child: Text(files == null
                      ? tr('githubActionsViewFiles')
                      : tr('githubActionsFilesLoaded')),
                ),
              ],
            ),
            if (_loadingArchive == id) const LinearProgressIndicator(),
            if (files != null)
              ...files.map((path) {
                final isApk = path.toLowerCase().endsWith('.apk');
                final matches = isApk && _matchesApk(path);
                return Padding(
                  padding: const EdgeInsets.only(left: 24),
                  child: Row(
                    children: [
                      Icon(
                        matches ? Icons.check_circle_outline : Icons.cancel_outlined,
                        size: 15,
                        color: matches ? Colors.green : Colors.red,
                      ),
                      const SizedBox(width: 4),
                      Expanded(child: Text(path,
                          style: Theme.of(context).textTheme.bodySmall)),
                    ],
                  ),
                );
              }),
          ],
        );
      }),
    ],
  );

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(tr('githubActionsChooseArtifact')),
    content: SizedBox(
      width: 560,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_loadingSetup || _loadingArtifacts)
              const LinearProgressIndicator(),
            if (_error != null) Text(_error.toString()),
            if (!_loadingSetup) ...[
              DropdownButtonFormField<String>(
                key: ValueKey('branch-$_branch'),
                initialValue: _branch,
                isExpanded: true,
                decoration: InputDecoration(labelText: tr('githubActionsBranch')),
                items: _branches.map((branch) => DropdownMenuItem(
                  value: branch,
                  child: Text(branch, overflow: TextOverflow.ellipsis),
                )).toList(),
                onChanged: (branch) {
                  setState(() => _branch = branch);
                  unawaited(_loadRuns());
                },
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                key: ValueKey('workflow-$_workflow'),
                initialValue: _workflow,
                isExpanded: true,
                decoration: InputDecoration(labelText: tr('githubActionsWorkflow')),
                items: _workflows.map((workflow) => DropdownMenuItem(
                  value: workflow['id'].toString(),
                  child: Text(
                    '${workflow['name']} (${workflow['path']})',
                    overflow: TextOverflow.ellipsis,
                  ),
                )).toList(),
                onChanged: (workflow) {
                  setState(() => _workflow = workflow);
                  unawaited(_loadRuns());
                },
              ),
              const SizedBox(height: 12),
              Text(tr('githubActionsEvents')),
              Wrap(
                spacing: 4,
                runSpacing: 0,
                children: [
                  ...githubActionsDefaultEvents,
                  ...githubActionsOptionalEvents,
                ].map((event) => FilterChip(
                  label: Text(event),
                  selected: _events.contains(event),
                  onSelected: (selected) => _toggleEvent(event, selected),
                )).toList(),
              ),
              Text(tr('githubActionsEventsHelp'),
                  style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                key: ValueKey('artifact-$_workflow-$_branch-$_artifact'),
                initialValue: _artifact,
                isExpanded: true,
                decoration: InputDecoration(labelText: tr('githubActionsArtifact')),
                items: (_builds.isEmpty
                    ? <Map<String, dynamic>>[]
                    : _builds.first.artifacts)
                    .map((artifact) => DropdownMenuItem(
                      value: artifact['name'].toString(),
                      child: Text(artifact['name'].toString(),
                          overflow: TextOverflow.ellipsis),
                    )).toList(),
                onChanged: (name) => setState(() => _artifact = name),
              ),
              if (_workflow != null && !_loadingArtifacts && _builds.isEmpty)
                Text(tr('githubActionsNoArtifacts')),
              SwitchListTile(
                value: _advanced,
                title: Text(tr('githubActionsAdvancedRegex')),
                onChanged: (value) => setState(() => _advanced = value),
              ),
              TextField(
                controller: _advanced ? _nameRegex : _nameParts,
                minLines: 1,
                maxLines: 4,
                decoration: InputDecoration(
                  labelText: tr(_advanced
                      ? 'githubActionsArtifactPattern'
                      : 'githubActionsMatchParts'),
                  helperText: tr(_advanced
                      ? 'githubActionsRegexHelp'
                      : 'githubActionsMatchPartsHelp'),
                  helperMaxLines: 4,
                ),
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _advanced ? _apkRegex : _apkParts,
                minLines: 1,
                maxLines: 3,
                decoration: InputDecoration(
                  labelText: tr(_advanced
                      ? 'githubActionsApkRegex'
                      : 'githubActionsApkMatchParts'),
                  helperText: tr('githubActionsApkHelp'),
                  helperMaxLines: 3,
                ),
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 12),
              Text(tr('githubActionsPreviewHelp')),
              for (final build in _builds) ...[
                const SizedBox(height: 8),
                _artifactPreview(build),
              ],
              if (_artifact != null && !_validPattern)
                Text(tr('githubActionsInvalidPattern')),
            ],
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: Text(tr('cancel')),
      ),
      FilledButton(
        onPressed: _loadingSetup || _loadingArtifacts || !_validPattern
            ? null
            : () => Navigator.of(context).pop({
                'githubActionsEnabled': true,
                'githubActionsBranch': _branch,
                'githubActionsWorkflow': _workflow,
                'githubActionsArtifactName': _artifact,
                'githubActionsEvents': _events.join(','),
                'githubActionsMatchParts': _nameParts.text,
                'githubActionsArtifactPattern': _artifactPattern,
                'githubActionsApkMatchParts': _apkParts.text,
                'githubActionsUseRegex': _advanced,
                'zippedApkFilterRegEx': _apkPattern,
                'versionDetection': false,
                'releaseDateAsVersion': false,
              }),
        child: Text(tr('continue')),
      ),
    ],
  );
}
