import 'dart:async';

import 'package:easy_localization/easy_localization.dart';
import 'package:material_ui/material_ui.dart';
import 'package:obtainium/app_sources/github.dart';
import 'package:obtainium/app_sources/github_actions.dart';
import 'package:obtainium/components/ui_widgets.dart';

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
        final standardUrl = source.standardizeUrl(url);
        final selected = await showDialog<Map<String, dynamic>>(
          context: context,
          builder: (_) => _GitHubActionsPicker(
            source: source,
            url: standardUrl,
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
  List<Map<String, dynamic>> _artifacts = [];
  String? _branch;
  String? _workflow;
  String? _artifact;
  Object? _error;
  bool _loadingSetup = true;
  bool _loadingArtifacts = false;
  int _requestSequence = 0;
  final TextEditingController _pattern = TextEditingController();

  @override
  void initState() {
    super.initState();
    _pattern.text =
        widget.settings['githubActionsArtifactPattern'] as String? ?? '';
    unawaited(_loadSetup());
  }

  @override
  void dispose() {
    _pattern.dispose();
    super.dispose();
  }

  Future<void> _loadSetup() async {
    try {
      final api = await widget.source.actionsApi(widget.url, widget.settings);
      final responses = await Future.wait<dynamic>([
        api.defaultBranch(),
        api.branches(),
        api.workflows(),
      ]);
      final defaultBranch = responses[0] as String;
      final branches = (responses[1] as List<Map<String, dynamic>>)
          .map((item) => item['name']?.toString() ?? '')
          .where((name) => name.isNotEmpty)
          .toList();
      final workflows = (responses[2] as List<Map<String, dynamic>>)
          .where((item) => item['state'] == 'active')
          .toList();
      if (!mounted) return;
      setState(() {
        _api = api;
        _branches = branches;
        _workflows = workflows;
        final savedBranch = widget.settings['githubActionsBranch'] as String?;
        _branch = branches.contains(savedBranch)
            ? savedBranch
            : branches.contains(defaultBranch)
            ? defaultBranch
            : branches.firstOrNull;
        final savedWorkflow = widget.settings['githubActionsWorkflow']
            ?.toString();
        _workflow =
            workflows.any((item) => item['id'].toString() == savedWorkflow)
            ? savedWorkflow
            : null;
        _loadingSetup = false;
      });
      if (_branch != null && _workflow != null) {
        unawaited(_loadArtifacts());
      }
    } catch (err) {
      if (!mounted) return;
      setState(() {
        _error = err;
        _loadingSetup = false;
      });
    }
  }

  Future<void> _loadArtifacts() async {
    final api = _api;
    final branch = _branch;
    final workflow = _workflow;
    final sequence = ++_requestSequence;
    setState(() {
      _loadingArtifacts = branch != null && workflow != null;
      _artifacts = [];
      _artifact = null;
      _error = null;
    });
    if (api == null || branch == null || workflow == null) return;
    try {
      final build = await api.latestBuild(
        workflow: workflow,
        branch: branch,
        includePullRequests:
            widget.settings['githubActionsIncludePullRequests'] == true,
      );
      if (!mounted || sequence != _requestSequence) return;
      setState(() {
        _artifacts = build?.artifacts ?? [];
        _artifact = _artifacts
            .where((a) {
              try {
                return _pattern.text.isNotEmpty &&
                    githubActionsArtifactMatches(
                      _pattern.text,
                      a['name'].toString(),
                    );
              } catch (_) {
                return false;
              }
            })
            .firstOrNull?['name']
            ?.toString();
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

  void _selectArtifact(String? name) {
    setState(() {
      _artifact = name;
      if (name != null) {
        _pattern.text = githubActionsExactArtifactPattern(name);
      }
    });
  }

  bool get _validPattern {
    if (_pattern.text.isEmpty || _artifact == null) return false;
    try {
      return githubActionsArtifactMatches(_pattern.text, _artifact!) &&
          _artifacts
                  .where(
                    (item) => githubActionsArtifactMatches(
                      _pattern.text,
                      item['name'].toString(),
                    ),
                  )
                  .length ==
              1;
    } catch (_) {
      return false;
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(tr('githubActionsChooseArtifact')),
    content: SizedBox(
      width: 440,
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
                decoration: InputDecoration(
                  labelText: tr('githubActionsBranch'),
                ),
                items: _branches
                    .map(
                      (branch) => DropdownMenuItem(
                        value: branch,
                        child: Text(branch, overflow: TextOverflow.ellipsis),
                      ),
                    )
                    .toList(),
                onChanged: (branch) {
                  setState(() => _branch = branch);
                  unawaited(_loadArtifacts());
                },
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                key: ValueKey('workflow-$_workflow'),
                initialValue: _workflow,
                isExpanded: true,
                decoration: InputDecoration(
                  labelText: tr('githubActionsWorkflow'),
                ),
                items: _workflows
                    .map(
                      (workflow) => DropdownMenuItem(
                        value: workflow['id'].toString(),
                        child: Text(
                          '${workflow['name']} (${workflow['path']})',
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    )
                    .toList(),
                onChanged: (workflow) {
                  setState(() => _workflow = workflow);
                  unawaited(_loadArtifacts());
                },
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                key: ValueKey('artifact-$_workflow-$_branch-$_artifact'),
                initialValue: _artifact,
                isExpanded: true,
                decoration: InputDecoration(
                  labelText: tr('githubActionsArtifact'),
                ),
                items: _artifacts
                    .map(
                      (artifact) => DropdownMenuItem(
                        value: artifact['name'].toString(),
                        child: Text(
                          artifact['name'].toString(),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    )
                    .toList(),
                onChanged: _selectArtifact,
              ),
              if (_workflow != null && !_loadingArtifacts && _artifacts.isEmpty)
                Text(tr('githubActionsNoArtifacts')),
              const SizedBox(height: 12),
              TextField(
                controller: _pattern,
                decoration: InputDecoration(
                  labelText: tr('githubActionsArtifactPattern'),
                  helperText: tr('githubActionsArtifactPatternHelp'),
                  helperMaxLines: 3,
                ),
                onChanged: (_) => setState(() {}),
              ),
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
                'githubActionsArtifactPattern': _pattern.text,
                'versionDetection': false,
                'releaseDateAsVersion': false,
              }),
        child: Text(tr('continue')),
      ),
    ],
  );
}
