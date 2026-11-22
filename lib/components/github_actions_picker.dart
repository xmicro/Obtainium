import 'dart:async';
import 'dart:io';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/foundation.dart' show compute;
import 'package:http/http.dart' as http;
import 'package:material_ui/material_ui.dart';
import 'package:obtainium/app_sources/github.dart';
import 'package:obtainium/app_sources/github_actions.dart';
import 'package:obtainium/components/ui_widgets.dart';
import 'package:obtainium/services/github_actions_archive_service.dart';
import 'package:obtainium/services/http_service.dart';

Future<List<ActionsArchiveEntry>> _scanActionsZip((String, String) args) =>
    inspectActionsArtifact(File(args.$1), Directory(args.$2));

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
  List<GitHubActionsBuild> _candidateBuilds = [];
  bool _uploadAmbiguous = false;
  final Map<int, List<ActionsArchiveEntry>> _archiveFiles = {};
  Set<String> _events = {};
  String? _branch;
  String? _workflow;
  String? _artifactName;
  Object? _error;
  bool _loadingSetup = true;
  bool _loadingRuns = false;
  bool _advanced = false;
  bool _uploadUseText = false;
  ActionsApkLocation _location = ActionsApkLocation.anywhere;
  int? _loadingArchive;
  String _archiveStage = '';
  double? _archiveProgress;
  int _archiveBytes = 0;
  int _requestSequence = 0;
  Future<void> Function()? _cancelArchive;

  final _uploadParts = TextEditingController();
  final _uploadRegex = TextEditingController();
  final _zipParts = TextEditingController();
  final _zipRegex = TextEditingController();
  final _apkParts = TextEditingController();
  final _apkRegex = TextEditingController();

  @override
  void initState() {
    super.initState();
    _events = githubActionsSelectedEvents(widget.settings);
    _advanced = widget.settings['githubActionsUseRegex'] == true;
    _uploadUseText = widget.settings['githubActionsUploadUseText'] == true;
    _uploadParts.text = widget.settings['githubActionsUploadMatchParts']?.toString() ?? '';
    _uploadRegex.text = widget.settings['githubActionsUploadPattern']?.toString() ?? '';
    _location = ActionsFileSelection.fromSettings(widget.settings).location;
    _zipParts.text = widget.settings['githubActionsZipMatchParts']?.toString() ?? '';
    _zipRegex.text = widget.settings['githubActionsZipPattern']?.toString() ?? '';
    _apkParts.text = widget.settings['githubActionsApkMatchParts']?.toString() ?? '';
    _apkRegex.text = widget.settings['githubActionsApkPattern']?.toString() ?? '';
    unawaited(_loadSetup());
  }

  @override
  void dispose() {
    _uploadParts.dispose();
    _uploadRegex.dispose();
    _zipParts.dispose();
    _zipRegex.dispose();
    _apkParts.dispose();
    _apkRegex.dispose();
    super.dispose();
  }

  String get _uploadPattern => _advanced
      ? _uploadRegex.text.trim()
      : actionsLiteralFilenamePattern(_uploadParts.text.split('\n'));
  String get _zipPattern => _advanced
      ? _zipRegex.text.trim()
      : actionsLiteralFilenamePattern(_zipParts.text.split('\n'));
  String get _apkPattern => _advanced
      ? _apkRegex.text.trim()
      : actionsLiteralFilenamePattern(_apkParts.text.split('\n'));

  bool _validRegex(String text) {
    if (text.isEmpty) return true;
    try { RegExp(text); return true; } catch (_) { return false; }
  }

  bool get _validPatterns => _validRegex(_apkPattern) &&
      (_location != ActionsApkLocation.nested || _validRegex(_zipPattern)) &&
      (!_uploadUseText || _validRegex(_uploadPattern));

  bool get _uploadReady => _uploadUseText
      ? _uploadPattern.isNotEmpty && _validRegex(_uploadPattern)
      : _artifactName != null;

  List<Map<String, dynamic>> _matchingUploads(GitHubActionsBuild build) {
    if (!_uploadReady) return [];
    return build.artifacts.where((artifact) => actionsUploadNameMatches(
      artifact['name']?.toString() ?? '',
      useText: _uploadUseText,
      exactName: _artifactName ?? '',
      pattern: _uploadPattern,
    )).toList();
  }

  /// Local-only selection: no API requests or ZIP downloads on text changes.
  void _updateUploadPreview() {
    final selected = <GitHubActionsBuild>[];
    var ambiguous = false;
    for (final build in _candidateBuilds) {
      final count = _matchingUploads(build).length;
      if (count > 1) ambiguous = true;
      if (count == 1 && selected.length < 3) selected.add(build);
    }
    _builds = selected;
    _uploadAmbiguous = ambiguous;
  }

  List<Map<String, dynamic>> get _availableUploads =>
      _candidateBuilds.isEmpty ? [] : _candidateBuilds.first.artifacts;

  ActionsFileSelection get _selection => ActionsFileSelection(
      location: _location, apkPattern: _apkPattern, zipPattern: _zipPattern);

  bool get _validSelection =>
      _branch != null && _workflow != null && _uploadReady &&
      !_uploadAmbiguous && _builds.isNotEmpty && _validPatterns;

  Future<void> _loadSetup() async {
    try {
      final api = await widget.source.actionsApi(widget.url, widget.settings);
      final response = await Future.wait<dynamic>([
        api.defaultBranch(), api.branches(), api.workflows(),
      ]);
      if (!mounted) return;
      final branches = (response[1] as List<Map<String, dynamic>>)
          .map((e) => e['name']?.toString() ?? '')
          .where((e) => e.isNotEmpty).toList();
      final workflows = (response[2] as List<Map<String, dynamic>>)
          .where((e) => e['state'] == 'active').toList();
      final previousBranch = widget.settings['githubActionsBranch']?.toString();
      final previousWorkflow = widget.settings['githubActionsWorkflow']?.toString();
      setState(() {
        _api = api;
        _branches = branches;
        _workflows = workflows;
        _branch = branches.contains(previousBranch)
            ? previousBranch
            : branches.contains(response[0]) ? response[0] as String
                : branches.firstOrNull;
        _workflow = workflows.any((e) => e['id'].toString() == previousWorkflow)
            ? previousWorkflow : null;
        _loadingSetup = false;
      });
      if (_branch != null && _workflow != null) unawaited(_loadRuns());
    } catch (e) {
      if (mounted) setState(() { _error = e; _loadingSetup = false; });
    }
  }

  Future<void> _loadRuns() async {
    final seq = ++_requestSequence;
    final branch = _branch, workflow = _workflow;
    final previousArtifact = _artifactName;
    setState(() {
      _loadingRuns = true;
      _runs = [];
      _builds = [];
      _candidateBuilds = [];
      _uploadAmbiguous = false;
      _artifactName = null;
      _error = null;
    });
    if (_api == null || branch == null || workflow == null) {
      if (mounted) setState(() => _loadingRuns = false);
      return;
    }
    try {
      final runs = await _api!.workflowRuns(workflow: workflow, branch: branch);
      if (!mounted || seq != _requestSequence) return;
      _runs = runs;
      await _refreshBuilds(seq, preferredName: previousArtifact);
    } catch (e) {
      if (mounted && seq == _requestSequence) {
        setState(() { _error = e; _loadingRuns = false; });
      }
    }
  }

  Future<void> _refreshBuilds(int seq, {String? preferredName}) async {
    if (_api == null) return;
    setState(() { _loadingRuns = true; _error = null; });
    try {
      final builds = await _api!.recentBuildsFromRuns(
          _runs, allowedEvents: _events, count: 10);
      if (!mounted || seq != _requestSequence) return;
      final names = builds.isEmpty ? <String>[]
          : builds.first.artifacts.map((e) => e['name']?.toString() ?? '').toList();
      final previous = preferredName ?? widget.settings['githubActionsArtifactName']?.toString();
      setState(() {
        _candidateBuilds = builds;
        if (!names.contains(_artifactName)) {
          _artifactName = names.contains(previous) ? previous : names.firstOrNull;
        }
        _updateUploadPreview();
        _loadingRuns = false;
      });
    } catch (e) {
      if (mounted && seq == _requestSequence) {
        setState(() { _error = e; _loadingRuns = false; });
      }
    }
  }

  void _toggleEvent(String event, bool selected) {
    setState(() {
      if (selected) { _events.add(event); } else { _events.remove(event); }
    });
    if (_runs.isNotEmpty) unawaited(_refreshBuilds(++_requestSequence));
  }

  void _setArchiveProgress(String stage, int received, int? total) {
    if (!mounted) return;
    // Limit rebuilds to percentage changes, or roughly 256 KiB with unknown length.
    if (_archiveStage == stage && received > _archiveBytes &&
        (total == null
            ? received - _archiveBytes < 262144
            : (received * 100 ~/ total) == (_archiveBytes * 100 ~/ total))) {
      return;
    }
    setState(() {
      _archiveStage = stage;
      _archiveBytes = received;
      _archiveProgress = total == null || total <= 0 ? null
          : (received / total).clamp(0.0, 1.0);
    });
  }

  Future<void> _viewFiles(Map<String, dynamic> artifact) async {
    final id = (artifact['id'] as num).toInt();
    if (_archiveFiles.containsKey(id) || _loadingArchive != null) return;
    setState(() {
      _loadingArchive = id;
      _archiveStage = tr('githubActionsDownloading');
      _archiveProgress = null;
      _archiveBytes = 0;
      _error = null;
    });
    Directory? directory;
    IOSink? sink;
    StreamSubscription<List<int>>? subscription;
    var cancelled = false;
    try {
      directory = await Directory.systemTemp.createTemp('obtainium-actions-');
      final file = File('${directory.path}/artifact.zip');
      final api = _api!;
      var url = await widget.source.actionsArtifactUrl(
          widget.url, widget.settings, api, id);

      Future<MapEntry<Uri, http.StreamedResponse>> openStream(String requestedUrl,
          {bool anonymous = false}) async {
        final modified = await widget.source.generalReqPrefetchModifier(
            requestedUrl, widget.settings);
        final settings = Map<String, dynamic>.from(widget.settings)
          ..['url'] = modified
          ..['skipAuth'] = anonymous;
        final headers = await widget.source.getRequestHeaders(
            settings, modified, forAPKDownload: true);
        return HttpService().requestStream('GET', headers, settings)
            .timeout(const Duration(seconds: 40));
      }

      // GitHub redirects authenticated ZIP requests to a signed URL. The
      // shared HTTP service strips credentials on cross-origin redirects.
      var pair = await openStream(url);
      var response = pair.value;
      if (Uri.parse(url).host != 'nightly.link' &&
          (response.statusCode == 401 || response.statusCode == 403) &&
          response.headers['x-ratelimit-remaining'] != '0' &&
          !response.headers.containsKey('retry-after')) {
        await cancelStreamedResponse(response);
        url = GitHub.nightlyActionsArtifactUrl(widget.url, id);
        pair = await openStream(url, anonymous: true);
        response = pair.value;
      }
      if (response.statusCode != 200) {
        await cancelStreamedResponse(response);
        throw Exception(tr('githubActionsArchiveFailed'));
      }

      // Stream to disk, never buffer the whole artifact in RAM.
      sink = file.openWrite();
      final contentLength = response.contentLength;
      final int? total = contentLength != null && contentLength > 0
          ? contentLength : null;
      final done = Completer<void>();
      var received = 0;
      subscription = response.stream.timeout(const Duration(seconds: 45)).listen(
        (data) {
          sink!.add(data);
          received += data.length;
          _setArchiveProgress(tr('githubActionsDownloading'), received, total);
        },
        onError: (Object error, StackTrace trace) {
          if (!done.isCompleted) done.completeError(error, trace);
        },
        onDone: () { if (!done.isCompleted) done.complete(); },
        cancelOnError: true,
      );
      _cancelArchive = () async {
        cancelled = true;
        await subscription?.cancel();
        if (!done.isCompleted) done.completeError(StateError('Cancelled'));
      };
      await done.future;
      await sink.flush();
      await sink.close();
      sink = null;
      if (cancelled) return;
      if (mounted) setState(() => _cancelArchive = null);
      _setArchiveProgress(tr('githubActionsScanning'), received, null);
      final outerPath = file.path;
      final scratchPath = directory.path;
      // Parse ZIP directory entries off the UI isolate. No APK extraction.
      final paths = await compute(_scanActionsZip, (outerPath, scratchPath));
      if (mounted && !cancelled) setState(() => _archiveFiles[id] = paths);
    } catch (err) {
      if (mounted && !cancelled) setState(() => _error = err);
    } finally {
      await subscription?.cancel();
      if (sink != null) { try { await sink.close(); } catch (_) {} }
      if (directory?.existsSync() == true) {
        await directory!.delete(recursive: true);
      }
      if (mounted) setState(() {
        _loadingArchive = null; _cancelArchive = null;
        _archiveProgress = null;
      });
    }
  }

  bool _fileIsSelected(ActionsArchiveEntry entry) =>
      _validPatterns && _selection.matchesEntry(entry);

  Widget _filePreview(List<ActionsArchiveEntry> entries) {
    final count = entries.where((entry) =>
        entry.isInstallable && _fileIsSelected(entry)).length;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      for (final entry in entries)
        Padding(
          padding: EdgeInsetsDirectional.only(
            start: entry.parentZip == null ? 0 : 24, top: 3, bottom: 3),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(_fileIsSelected(entry) ? Icons.check_circle_outline
                : Icons.remove_circle_outline,
                color: _fileIsSelected(entry) ? Colors.green : Colors.grey,
                size: 18),
            const SizedBox(width: 8),
            if (entry.isOuterZip) ...[
              const Icon(Icons.folder_open_outlined, size: 18),
              const SizedBox(width: 4),
            ],
            Expanded(child: Text(entry.path, softWrap: true)),
          ]),
        ),
      if (count > 1)
        Padding(padding: const EdgeInsets.only(top: 8),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Icon(Icons.warning_amber_rounded),
            const SizedBox(width: 8),
            Expanded(child: Text(tr('githubActionsMultipleMatches',
                args: [count.toString()]), softWrap: true)),
          ])),
    ]);
  }

  Widget _runPreview(GitHubActionsBuild build) {
    final matching = _matchingUploads(build);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const SizedBox(height: 12),
      Text('${tr('githubActionsRun')} ${build.version} (${build.run['event']})',
          style: Theme.of(context).textTheme.titleSmall),
      if (matching.isEmpty)
        Text(tr('githubActionsUploadMissing')),
      for (final item in matching) ...[
        Text(item['name']?.toString() ?? '', softWrap: true),
        TextButton.icon(
          onPressed: _loadingArchive == null
              ? () => unawaited(_viewFiles(item)) : null,
          icon: const Icon(Icons.folder_open_outlined),
          label: Text(_archiveFiles.containsKey((item['id'] as num).toInt())
              ? tr('githubActionsFilesLoaded') : tr('githubActionsViewFiles')),
        ),
        if (_loadingArchive == (item['id'] as num).toInt()) ...[
          Text(_archiveStage),
          if (_archiveBytes > 0)
            Text('${(_archiveBytes / 1048576).toStringAsFixed(1)} MiB'),
          LinearProgressIndicator(value: _archiveProgress),
          TextButton(onPressed: _cancelArchive == null ? null
                  : () => unawaited(_cancelArchive!()),
              child: Text(tr('cancel'))),
        ],
        if (_archiveFiles[(item['id'] as num).toInt()] != null)
          _filePreview(_archiveFiles[(item['id'] as num).toInt()]!),
      ],
    ]);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    insetPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 18),
    title: Text(tr('githubActionsChooseArtifact')),
    content: SizedBox(
      width: 560,
      height: MediaQuery.sizeOf(context).height * 0.68,
      child: SingleChildScrollView(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (_loadingSetup || _loadingRuns) const LinearProgressIndicator(),
          if (_error != null) Text(_error.toString()),
          if (!_loadingSetup) ...[
            const SizedBox(height: 8),
            Text(tr('githubActionsBranch')),
            DropdownButtonFormField<String>(
              key: ValueKey('branch-$_branch'), initialValue: _branch,
              isExpanded: true,
              items: _branches.map((branch) => DropdownMenuItem(
                  value: branch, child: Text(branch, softWrap: true))).toList(),
              onChanged: (name) { setState(() => _branch = name); unawaited(_loadRuns()); },
            ),
            const SizedBox(height: 12),
            Text(tr('githubActionsWorkflow')),
            DropdownButtonFormField<String>(
              key: ValueKey('workflow-$_workflow'), initialValue: _workflow,
              isExpanded: true,
              items: _workflows.map((workflow) => DropdownMenuItem(
                value: workflow['id'].toString(),
                child: Text(workflow['name']?.toString() ?? '',
                    overflow: TextOverflow.visible),
              )).toList(),
              onChanged: (name) { setState(() => _workflow = name); unawaited(_loadRuns()); },
            ),
            const SizedBox(height: 12),
            Text(tr('githubActionsEvents')),
            Wrap(spacing: 4, children: [
              ...githubActionsDefaultEvents, ...githubActionsOptionalEvents,
            ].map((event) => FilterChip(
              label: Text(event), selected: _events.contains(event),
              onSelected: (selected) => _toggleEvent(event, selected),
            )).toList()),
            Text(tr('githubActionsEventsHelp'), softWrap: true),
            const SizedBox(height: 12),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(tr('githubActionsAdvancedRegex'), softWrap: true),
              value: _advanced,
              onChanged: (selected) => setState(() {
                if (selected && !_advanced) {
                  _uploadRegex.text = _uploadPattern;
                  _zipRegex.text = _zipPattern;
                  _apkRegex.text = _apkPattern;
                }
                _advanced = selected;
                _updateUploadPreview();
              }),
            ),
            const SizedBox(height: 8),
            Text(tr('githubActionsUploadSelection')),
            RadioListTile<bool>(
              contentPadding: EdgeInsets.zero,
              title: Text(tr('githubActionsUploadExact')),
              value: false, groupValue: _uploadUseText,
              onChanged: (value) => setState(() {
                _uploadUseText = value ?? false;
                _updateUploadPreview();
              }),
            ),
            RadioListTile<bool>(
              contentPadding: EdgeInsets.zero,
              title: Text(tr('githubActionsUploadText')),
              value: true, groupValue: _uploadUseText,
              onChanged: (value) => setState(() {
                _uploadUseText = value ?? true;
                _updateUploadPreview();
              }),
            ),
            if (!_uploadUseText) ...[
              Text(tr('githubActionsArtifact')),
              DropdownButtonFormField<String>(
                key: ValueKey('artifact-$_branch-$_workflow-$_artifactName'),
                initialValue: _availableUploads.any((a) =>
                    a['name'] == _artifactName) ? _artifactName : null,
                isExpanded: true,
                items: _availableUploads.map((a) => DropdownMenuItem<String>(
                  value: a['name']?.toString(),
                  child: Text(a['name']?.toString() ?? '', softWrap: true),
                )).toList(),
                onChanged: (name) => setState(() {
                  _artifactName = name;
                  _updateUploadPreview();
                }),
              ),
              Text(tr('githubActionsUploadHelp'), softWrap: true),
            ] else ...[
              Text(tr(_advanced ? 'githubActionsUploadRegex'
                  : 'githubActionsUploadParts')),
              TextField(
                controller: _advanced ? _uploadRegex : _uploadParts,
                minLines: 1, maxLines: 4,
                onChanged: (_) => setState(_updateUploadPreview),
              ),
              Text(tr('githubActionsUploadPartsHelp'), softWrap: true),
              if (_uploadPattern.isEmpty)
                Text(tr('githubActionsUploadPatternRequired')),
              if (!_validRegex(_uploadPattern))
                Text(tr('githubActionsInvalidPattern')),
            ],
            if (_candidateBuilds.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(tr('githubActionsUploadNamesRecent')),
              Card(child: Padding(
                padding: const EdgeInsets.all(8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final artifact in _availableUploads)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 3),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Icon(_matchingUploads(_candidateBuilds.first)
                                    .contains(artifact)
                                ? Icons.check_circle_outline
                                : Icons.remove_circle_outline,
                                color: _matchingUploads(_candidateBuilds.first)
                                        .contains(artifact)
                                    ? Colors.green : Colors.grey,
                                size: 18),
                            const SizedBox(width: 8),
                            Expanded(child: Text(
                                artifact['name']?.toString() ?? '',
                                softWrap: true)),
                          ],
                        ),
                      ),
                  ],
                ),
              )),
            ],
            if (_uploadAmbiguous)
              Text(tr('githubActionsMultipleUploads')),
            if (!_loadingRuns && _candidateBuilds.isNotEmpty &&
                _uploadReady && _builds.isEmpty && !_uploadAmbiguous)
              Text(tr('githubActionsNoMatchingUploads')),
            const SizedBox(height: 12),
            Text(tr('githubActionsApkLocation')),
            DropdownButtonFormField<ActionsApkLocation>(
              initialValue: _location, isExpanded: true,
              items: [
                DropdownMenuItem(value: ActionsApkLocation.anywhere,
                    child: Text(tr('githubActionsApkAnywhere'))),
                DropdownMenuItem(value: ActionsApkLocation.direct,
                    child: Text(tr('githubActionsApkDirect'))),
                DropdownMenuItem(value: ActionsApkLocation.nested,
                    child: Text(tr('githubActionsApkNested'))),
              ],
              onChanged: (value) {
                if (value != null) setState(() => _location = value);
              },
            ),
            if (_location == ActionsApkLocation.nested) ...[
              const SizedBox(height: 8),
              Text(tr(_advanced ? 'githubActionsZipRegex' : 'githubActionsZipParts')),
              TextField(
                controller: _advanced ? _zipRegex : _zipParts,
                minLines: 1, maxLines: 4,
                onChanged: (_) => setState(() {}),
              ),
              Text(tr('githubActionsZipHelp'), softWrap: true),
            ],
            const SizedBox(height: 16),
            Text(tr(_advanced ? 'githubActionsApkRegex' : 'githubActionsApkMatchParts')),
            TextField(
              controller: _advanced ? _apkRegex : _apkParts,
              minLines: 1, maxLines: 3,
              onChanged: (_) => setState(() {}),
            ),
            Text(tr('githubActionsApkHelp'), softWrap: true),
            if (!_validPatterns)
              Text(tr('githubActionsInvalidPattern')),
            const SizedBox(height: 16),
            Text(tr('githubActionsPreviewHelp'), softWrap: true),
            if (!_loadingRuns && _branch != null && _workflow != null &&
                _error == null && _candidateBuilds.isEmpty)
              Text(tr('githubActionsEmptyPreview'), softWrap: true),
            for (final build in _builds) _runPreview(build),
          ],
        ]),
      ),
    ),
    actions: [
      TextButton(onPressed: () => Navigator.of(context).pop(),
          child: Text(tr('cancel'))),
      FilledButton(
        onPressed: (_loadingSetup || _loadingRuns || !_validSelection)
            ? null : () => Navigator.of(context).pop({
          'githubActionsEnabled': true,
          'githubActionsBranch': _branch,
          'githubActionsWorkflow': _workflow,
          'githubActionsArtifactName': _artifactName,
          'githubActionsUploadUseText': _uploadUseText,
          'githubActionsUploadMatchParts': _uploadParts.text,
          'githubActionsUploadPattern': _uploadPattern,
          'githubActionsEvents': _events.join(','),
          'githubActionsApkLocation': _location.name,
          'githubActionsZipMatchParts': _zipParts.text,
          'githubActionsZipPattern': _zipPattern,
          'githubActionsApkMatchParts': _apkParts.text,
          'githubActionsUseRegex': _advanced,
          'githubActionsApkPattern': _apkPattern,
        }),
        child: Text(tr('continue')),
      ),
    ],
  );
}
