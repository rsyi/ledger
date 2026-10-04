import 'package:flutter/material.dart';

import '../services/google_auth/data_account.dart';
import 'design/design.dart';

/// Account + Spreadsheet controls (multi-user sub-project 2) — shared by
/// Settings and the first-run DataSetupScreen.
///
/// Owner build: read-only ("built into this app"). Everyone else: Google
/// sign-in / sign-out, and the spreadsheet — Create new ("Ledger" in the
/// user's Drive) or Use existing (paste an id or URL).
class DataAccountCard extends StatefulWidget {
  const DataAccountCard({super.key});

  @override
  State<DataAccountCard> createState() => _DataAccountCardState();
}

class _DataAccountCardState extends State<DataAccountCard> {
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    DataAccountRegistry.current.addListener(_changed);
  }

  @override
  void dispose() {
    DataAccountRegistry.current.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _run(Future<void> Function() fn) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await fn();
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _useExisting() async {
    final ctl = TextEditingController();
    final input = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Use an existing spreadsheet'),
        content: TextField(
          key: const ValueKey('spreadsheet-id-field'),
          controller: ctl,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'Spreadsheet URL or id'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          TextButton(
            key: const ValueKey('spreadsheet-id-save'),
            onPressed: () => Navigator.pop(ctx, ctl.text),
            child: const Text('Use'),
          ),
        ],
      ),
    );
    if (input == null) return;
    await _run(() async {
      if (!await DataAccountRegistry.useSpreadsheet(input)) {
        throw const FormatException(
          "That doesn't look like a Google Sheets URL or id",
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final a = DataAccountRegistry.current.value;
    final children = <Widget>[];
    if (a == null || a.isOwner) {
      children.addAll([
        Text(
          'Built into this app',
          key: const ValueKey('data-account-who'),
          style: AppText.row(context),
        ),
        const SizedBox(height: 2),
        Text(
          a == null || a.spreadsheetId.isEmpty
              ? 'Service account'
              : 'Service account · spreadsheet ${a.spreadsheetId}',
          key: const ValueKey('data-spreadsheet-id'),
          style: AppText.meta(context),
        ),
      ]);
    } else {
      children.addAll([
        Text(
          a.email == null ? 'Not signed in' : 'Google · ${a.email}',
          key: const ValueKey('data-account-who'),
          style: AppText.row(context),
        ),
        const SizedBox(height: 2),
        Text(
          a.spreadsheetId.isEmpty
              ? 'No spreadsheet yet'
              : 'Spreadsheet ${a.spreadsheetId}',
          key: const ValueKey('data-spreadsheet-id'),
          style: AppText.meta(context),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            if (a.email == null)
              FilledButton(
                key: const ValueKey('google-sign-in'),
                onPressed: _busy
                    ? null
                    : () => _run(DataAccountRegistry.signIn),
                child: const Text('Sign in with Google'),
              )
            else ...[
              OutlinedButton(
                key: const ValueKey('spreadsheet-create'),
                onPressed: _busy
                    ? null
                    : () => _run(() async {
                        await DataAccountRegistry.createSpreadsheet();
                      }),
                child: const Text('Create new'),
              ),
              OutlinedButton(
                key: const ValueKey('spreadsheet-use-existing'),
                onPressed: _busy ? null : _useExisting,
                child: const Text('Use existing'),
              ),
              TextButton(
                key: const ValueKey('google-sign-out'),
                onPressed: _busy
                    ? null
                    : () => _run(DataAccountRegistry.signOut),
                child: const Text('Sign out'),
              ),
            ],
          ],
        ),
      ]);
    }
    if (_busy) {
      children.addAll(const [SizedBox(height: 8), LinearProgressIndicator()]);
    }
    if (_error != null) {
      children.addAll([
        const SizedBox(height: 8),
        Text(
          _error!,
          key: const ValueKey('data-account-error'),
          style: TextStyle(color: Theme.of(context).colorScheme.error),
        ),
      ]);
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpace.gutter),
      child: AppCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: children,
        ),
      ),
    );
  }
}

/// First-run data step (bootstrap: config source → Google identity →
/// spreadsheet → home). Minimal by design — onboarding polish is
/// sub-project 4. The gate swaps to home as soon as the account is ready.
class DataSetupScreen extends StatelessWidget {
  /// "Skip for now": into the app offline (local-first rows stay on the
  /// phone; sync reports "sign in" until finished in Settings).
  final VoidCallback? onSkip;

  const DataSetupScreen({super.key, this.onSkip});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Your data')),
      body: ListView(
        padding: const EdgeInsets.only(top: 8, bottom: 24),
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpace.gutter,
              vertical: 8,
            ),
            child: Text(
              'Ledger keeps your log on this phone and mirrors it to a '
              'Google Sheet in your own Drive. Sign in with Google, then '
              'create a new spreadsheet or use one you already have.',
              style: AppText.meta(context),
            ),
          ),
          const DataAccountCard(),
          if (onSkip != null)
            Padding(
              padding: const EdgeInsets.all(AppSpace.gutter),
              child: TextButton(
                key: const ValueKey('data-setup-skip'),
                onPressed: onSkip,
                child: const Text('Skip for now'),
              ),
            ),
        ],
      ),
    );
  }
}
