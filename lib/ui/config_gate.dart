import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;

import '../services/app_config.dart';
import '../services/config_source/config_source.dart';
import '../services/config_source/config_source_registry.dart';
import '../services/google_auth/data_account.dart';
import '../services/google_auth/google_identity.dart';
import 'connect_program_screen.dart';
import 'data_account_card.dart';

/// The baked service-account key, or '' when the build has none.
Future<String> loadBakedServiceAccountKey() async {
  try {
    return await rootBundle.loadString('assets/service-account.json');
  } catch (_) {
    return '';
  }
}

GoogleAccountGateway _defaultGoogle(String? serverClientId) =>
    GoogleSignInIdentity(serverClientId: serverClientId ?? '');

/// App root (multi-user sub-project 1): resolves the active
/// [ConfigSource] before the home screen bootstraps.
///
///   baked / user-connected source → [home] (re-created, keyed on the
///     source id, whenever the source changes — a full re-bootstrap so no
///     config from the old location leaks through);
///   no source (and not a kiosk build) → [ConnectProgramScreen], the
///     minimal onboarding placeholder ("Continue without a program" lets
///     the user in with every config-driven surface inert, as builds
///     without `github:` always behaved).
///
/// Then the DATA step (multi-user sub-project 2): the owner build (baked
/// service account) passes straight through; otherwise, until the user
/// is signed in with Google AND has a spreadsheet, [DataSetupScreen]
/// ("Skip for now" lets them in offline). The home key gains the data
/// location in that mode so a spreadsheet switch re-bootstraps.
class ConfigGate extends StatefulWidget {
  final Widget Function(Key key) home;

  /// Test seams.
  final Future<AppConfig> Function() loadConfig;
  final SecretStore? store;
  final Future<String> Function() loadServiceAccountKey;
  final GoogleAccountGateway Function(String? serverClientId) google;

  const ConfigGate({
    super.key,
    required this.home,
    this.loadConfig = AppConfig.load,
    this.store,
    this.loadServiceAccountKey = loadBakedServiceAccountKey,
    this.google = _defaultGoogle,
  });

  @override
  State<ConfigGate> createState() => _ConfigGateState();
}

class _ConfigGateState extends State<ConfigGate> {
  bool _ready = false;
  bool _skipped = false;
  bool _kiosk = false;
  bool _dataSkipped = false;

  @override
  void initState() {
    super.initState();
    ConfigSourceRegistry.active.addListener(_changed);
    DataAccountRegistry.current.addListener(_changed);
    _init();
  }

  @override
  void dispose() {
    ConfigSourceRegistry.active.removeListener(_changed);
    DataAccountRegistry.current.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _init() async {
    try {
      final cfg = await widget.loadConfig();
      _kiosk = cfg.kioskView != null;
      await ConfigSourceRegistry.init(
        baked: cfg.github,
        store: widget.store,
        oauthClientId: cfg.githubOAuthClientId,
        templateRepo: cfg.githubTemplateRepo,
      );
      await DataAccountRegistry.init(
        bakedKeyJson: await widget.loadServiceAccountKey(),
        bakedSpreadsheetId: cfg.spreadsheetId,
        google: widget.google(cfg.googleServerClientId),
        store: widget.store,
      );
    } catch (_) {
      // Unreadable assets config: let the home screen bootstrap and show
      // its own error view (same failure surface as before the gate).
      _skipped = true;
    }
    if (mounted) setState(() => _ready = true);
  }

  @override
  Widget build(BuildContext context) {
    if (!_ready) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final source = ConfigSourceRegistry.active.value;
    if (source == null && !_kiosk && !_skipped) {
      return ConnectProgramScreen(
        key: const ValueKey('connect-program'),
        oauthClientId: ConfigSourceRegistry.oauthClientId,
        templateRepo: ConfigSourceRegistry.templateRepo,
        onSkip: () => setState(() => _skipped = true),
      );
    }
    final data = DataAccountRegistry.current.value;
    if (data != null &&
        !data.ready &&
        !_kiosk &&
        !_skipped &&
        !_dataSkipped) {
      return DataSetupScreen(
        key: const ValueKey('data-setup'),
        onSkip: () => setState(() => _dataSkipped = true),
      );
    }
    // Owner build: the key is unchanged from before multi-user data.
    final dataKey = data == null || data.isOwner ? '' : '|${data.key}';
    return widget.home(ValueKey('home:${source?.id ?? 'none'}$dataKey'));
  }
}
