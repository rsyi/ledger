import 'package:flutter/widgets.dart';

import 'integration.dart';

/// Session-wide set of integrations, built at bootstrap next to the
/// SyncScheduler. The scheduler calls [pullDue] before each ledger
/// sync; the Integrations page renders [integrations].
class IntegrationRegistry {
  IntegrationRegistry._(this.integrations);

  static IntegrationRegistry? instance;

  final List<Integration> integrations;

  static void init({required List<Integration> integrations}) {
    instance = IntegrationRegistry._(integrations);
  }

  /// Pull every configured+connected integration that's past its own
  /// minimum interval. Integrations contain their failures (status
  /// meta), so this never throws and never delays the ledger sync.
  Future<void> pullDue() async {
    for (final i in integrations) {
      if (!i.isConfigured) continue;
      await i.pull();
    }
  }
}

/// Placeholder card for sources we plan but haven't built — shows the
/// page's shape before the pipeline exists.
class ComingSoonIntegration implements Integration {
  ComingSoonIntegration(this.displayName, this.targetDescription);

  @override
  final String displayName;
  @override
  final String targetDescription;

  @override
  String get id => displayName.toLowerCase();
  @override
  bool get isConfigured => false;
  @override
  Future<bool> get isConnected async => false;
  @override
  Future<String> get statusLine async => 'Coming soon';
  @override
  Map<String, Future<void> Function(BuildContext)> get extraMenuActions =>
      const {};
  @override
  Future<void> connect(BuildContext context) async {}
  @override
  Future<void> disconnect() async {}
  @override
  Future<void> pull({bool force = false, bool fullReconcile = false}) async {}
}
