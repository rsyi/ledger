import 'dart:async';

import 'package:android_intent_plus/android_intent.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import '../services/config_source/config_source_registry.dart';
import '../services/config_source/github_auth.dart';
import 'design/design.dart';

/// Opens [url] outside the app (browser / GitHub app).
Future<void> openExternalUrl(String url) async {
  await AndroidIntent(action: 'android.intent.action.VIEW', data: url)
      .launch();
}

/// "Connect your program" (multi-user sub-project 1): GitHub sign-in →
/// repo / branch / path → validate → [ConfigSourceRegistry.connect].
///
/// Sign-in: the OAuth DEVICE FLOW when the build carries
/// `github.oauth_client_id` (no secret on device), else — and always as an
/// alternative — a pasted fine-grained Personal Access Token.
///
/// Used as the onboarding placeholder (no source at all; [onSkip] lets the
/// user in without one) and from Settings → Change (pops on success).
class ConnectProgramScreen extends StatefulWidget {
  final String? oauthClientId;
  final String templateRepo;

  /// Onboarding only: "Continue without a program".
  final VoidCallback? onSkip;

  /// Test seams.
  final http.Client? httpClient;
  final Future<void> Function(String url) openUrl;
  final Future<void> Function(Duration)? sleep;

  const ConnectProgramScreen({
    super.key,
    this.oauthClientId,
    required this.templateRepo,
    this.onSkip,
    this.httpClient,
    this.openUrl = openExternalUrl,
    this.sleep,
  });

  @override
  State<ConnectProgramScreen> createState() => _ConnectProgramScreenState();
}

enum _Step { signIn, device, pat, repos }

class _ConnectProgramScreenState extends State<ConnectProgramScreen> {
  _Step _step = _Step.signIn;
  bool _busy = false;
  String? _error;

  // Sign-in.
  GithubDeviceCode? _code;
  bool _cancelled = false;
  final _patCtrl = TextEditingController();
  String? _token;
  String? _login;
  String _method = 'device';

  // Repo picker.
  List<GithubRepoSummary> _repos = const [];
  final _filterCtrl = TextEditingController();
  GithubRepoSummary? _repo;
  List<String> _branches = const [];
  String? _branch;
  final _rootCtrl = TextEditingController();
  ConfigRepoCheck? _check;

  @override
  void dispose() {
    _cancelled = true;
    _patCtrl.dispose();
    _filterCtrl.dispose();
    _rootCtrl.dispose();
    super.dispose();
  }

  bool get _hasDeviceFlow => widget.oauthClientId != null;

  GithubAccountApi _api(String token) =>
      GithubAccountApi(token, httpClient: widget.httpClient);

  Future<void> _run(Future<void> Function() fn) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await fn();
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _startDevice() => _run(() async {
        final flow = GithubDeviceFlow(
          clientId: widget.oauthClientId!,
          httpClient: widget.httpClient,
          sleep: widget.sleep,
        );
        final code = await flow.start();
        _cancelled = false;
        setState(() {
          _code = code;
          _step = _Step.device;
        });
        final token = await flow.poll(code, cancelled: () => _cancelled);
        await _signedIn(token, 'device');
      });

  Future<void> _submitPat() => _run(() async {
        final t = _patCtrl.text.trim();
        if (t.isEmpty) throw 'Paste a token first.';
        await _signedIn(t, 'pat');
      });

  Future<void> _signedIn(String token, String method) async {
    final api = _api(token);
    final login = await api.login();
    final repos = await api.repos();
    if (!mounted) return;
    setState(() {
      _token = token;
      _login = login;
      _method = method;
      _repos = repos;
      _step = _Step.repos;
    });
  }

  Future<void> _pickRepo(GithubRepoSummary r) => _run(() async {
        setState(() {
          _repo = r;
          _branch = r.defaultBranch;
          _branches = [r.defaultBranch];
          _check = null;
        });
        final b = await _api(_token!).branches(r.owner, r.name);
        if (!mounted) return;
        setState(() {
          _branches = b.isEmpty ? [r.defaultBranch] : b;
          if (!_branches.contains(_branch)) _branch = _branches.first;
        });
      });

  String get _root => _rootCtrl.text.trim().replaceAll(RegExp(r'^/+|/+$'), '');

  Future<void> _validate() => _run(() async {
        final r = _repo!;
        final c = await _api(_token!).validate(r.owner, r.name, _branch!, _root);
        if (!mounted) return;
        setState(() => _check = c);
        if (c.ok) await _connect();
      });

  Future<void> _connect() async {
    final r = _repo!;
    await ConfigSourceRegistry.connect(GithubSourceSettings(
      token: _token!,
      owner: r.owner,
      repo: r.name,
      branch: _branch!,
      root: _root,
      login: _login,
      method: _method,
    ));
    if (!mounted) return;
    final nav = Navigator.of(context);
    if (nav.canPop()) nav.pop(true);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Connect your program')),
      body: ListView(
        padding: const EdgeInsets.all(AppSpace.gutter),
        children: [
          ..._body(context),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(_error!,
                key: const ValueKey('connect-error'),
                style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ],
          if (widget.onSkip != null) ...[
            const SizedBox(height: 24),
            TextButton(
              onPressed: widget.onSkip,
              child: const Text('Continue without a program'),
            ),
          ],
        ],
      ),
    );
  }

  List<Widget> _body(BuildContext context) {
    switch (_step) {
      case _Step.signIn:
        return [
          Text(
            'Ledger reads your trackers (views/) and training program '
            '(coach/program.yaml) from a GitHub repo you own. Sign in and '
            'pick the repo.',
            style: AppText.row(context),
          ),
          const SizedBox(height: 16),
          if (_hasDeviceFlow)
            FilledButton.icon(
              key: const ValueKey('github-sign-in'),
              onPressed: _busy ? null : _startDevice,
              icon: const Icon(Icons.login),
              label: const Text('Sign in with GitHub'),
            ),
          OutlinedButton(
            key: const ValueKey('use-token'),
            onPressed:
                _busy ? null : () => setState(() => _step = _Step.pat),
            child: Text(_hasDeviceFlow
                ? 'Use a personal access token instead'
                : 'Connect with a GitHub token'),
          ),
          const SizedBox(height: 16),
          _templateHelp(context),
        ];
      case _Step.device:
        final code = _code!;
        return [
          Text('Enter this code on GitHub:', style: AppText.row(context)),
          const SizedBox(height: 8),
          SelectableText(code.userCode,
              key: const ValueKey('device-user-code'),
              style: Theme.of(context)
                  .textTheme
                  .headlineMedium
                  ?.copyWith(letterSpacing: 4)),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: code.userCode));
              await widget.openUrl(code.verificationUri);
            },
            icon: const Icon(Icons.open_in_new),
            label: const Text('Copy code & open GitHub'),
          ),
          const SizedBox(height: 12),
          Row(children: [
            const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2)),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                  'Waiting for approval at ${code.verificationUri} …',
                  style: AppText.meta(context)),
            ),
          ]),
          TextButton(
            onPressed: () => setState(() {
              _cancelled = true;
              _step = _Step.signIn;
            }),
            child: const Text('Cancel'),
          ),
        ];
      case _Step.pat:
        return [
          Text('Paste a fine-grained personal access token',
              style: AppText.row(context)),
          const SizedBox(height: 8),
          Text(
            '1. github.com → Settings → Developer settings → Personal access '
            'tokens → Fine-grained tokens → Generate new token.\n'
            '2. Repository access: "Only select repositories" → your Ledger '
            'config repo (just that one).\n'
            '3. Permissions → Repository → Contents: Read and write '
            '(Metadata: read-only is added automatically).\n'
            '4. Generate, copy, paste below. The token stays on this phone '
            '(encrypted storage).',
            style: AppText.meta(context),
          ),
          TextButton.icon(
            onPressed: () => widget.openUrl(
                'https://github.com/settings/personal-access-tokens/new'),
            icon: const Icon(Icons.open_in_new, size: 16),
            label: const Text('Open the token page'),
          ),
          TextField(
            key: const ValueKey('pat-field'),
            controller: _patCtrl,
            obscureText: true,
            autocorrect: false,
            decoration: const InputDecoration(
                labelText: 'github_pat_…', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 12),
          Row(children: [
            FilledButton(
              key: const ValueKey('pat-continue'),
              onPressed: _busy ? null : _submitPat,
              child: const Text('Continue'),
            ),
            const SizedBox(width: 8),
            TextButton(
              onPressed: () => setState(() => _step = _Step.signIn),
              child: const Text('Back'),
            ),
            if (_busy) const CircularProgressIndicator(),
          ]),
        ];
      case _Step.repos:
        return _repoPicker(context);
    }
  }

  List<Widget> _repoPicker(BuildContext context) {
    final q = _filterCtrl.text.trim().toLowerCase();
    final shown = [
      for (final r in _repos)
        if (q.isEmpty || r.fullName.toLowerCase().contains(q)) r,
    ];
    final repo = _repo;
    return [
      Text('Signed in as $_login', style: AppText.meta(context)),
      const SizedBox(height: 8),
      if (repo == null) ...[
        TextField(
          controller: _filterCtrl,
          decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search), hintText: 'Filter repos'),
          onChanged: (_) => setState(() {}),
        ),
        if (_repos.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text(
                'No repos visible to this token. Create one from the '
                'template (below), then sign in again.',
                style: AppText.meta(context)),
          ),
        for (final r in shown.take(50))
          ListTile(
            key: ValueKey('repo-${r.fullName}'),
            contentPadding: EdgeInsets.zero,
            leading: Icon(r.isPrivate ? Icons.lock_outline : Icons.public),
            title: Text(r.fullName),
            onTap: _busy ? null : () => _pickRepo(r),
          ),
      ] else ...[
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(repo.fullName),
          trailing: TextButton(
            onPressed: () => setState(() {
              _repo = null;
              _check = null;
            }),
            child: const Text('Change'),
          ),
        ),
        DropdownButtonFormField<String>(
          key: const ValueKey('branch-picker'),
          initialValue: _branch,
          decoration: const InputDecoration(labelText: 'Branch'),
          items: [
            for (final b in _branches) DropdownMenuItem(value: b, child: Text(b)),
          ],
          onChanged: (b) => setState(() {
            _branch = b;
            _check = null;
          }),
        ),
        TextField(
          key: const ValueKey('root-field'),
          controller: _rootCtrl,
          decoration: const InputDecoration(
            labelText: 'Folder in the repo',
            hintText: '(repo root)',
            helperText: 'Where views/ and coach/ live — blank = repo root',
          ),
          onChanged: (_) => setState(() => _check = null),
        ),
        const SizedBox(height: 16),
        Row(children: [
          FilledButton(
            key: const ValueKey('connect-repo'),
            onPressed: _busy ? null : _validate,
            child: const Text('Check & connect'),
          ),
          const SizedBox(width: 12),
          if (_busy) const CircularProgressIndicator(),
        ]),
        if (_check != null && !_check!.ok) ...[
          const SizedBox(height: 12),
          Text(_check!.problem ?? '',
              key: const ValueKey('check-problem'),
              style: AppText.row(context)),
          if (_check!.error == null && _check!.hasViews)
            TextButton(
              key: const ValueKey('connect-anyway'),
              onPressed: _busy ? null : () => _run(_connect),
              child: const Text('Connect anyway'),
            ),
          const SizedBox(height: 8),
          _templateHelp(context),
        ],
      ],
    ];
  }

  Widget _templateHelp(BuildContext context) {
    final url = 'https://github.com/${widget.templateRepo}';
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('No config repo yet?', style: AppText.row(context)),
          const SizedBox(height: 4),
          Text(
            'Use the template: open ${widget.templateRepo} on GitHub → '
            '"Use this template" → create a PRIVATE repo, then pick it here. '
            'It holds starter views/ and coach/program.yaml you can edit.',
            style: AppText.meta(context),
          ),
          TextButton.icon(
            key: const ValueKey('open-template'),
            onPressed: () => widget.openUrl(url),
            icon: const Icon(Icons.open_in_new, size: 16),
            label: const Text('Open the template'),
          ),
        ],
      ),
    );
  }
}
