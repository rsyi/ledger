/// Process-wide GoogleSignIn.instance bootstrap. google_sign_in 7.x
/// exposes one app-global singleton whose `initialize` must run exactly
/// once per process — but two features share it (Kaya's Gmail import
/// and the strength form's Photos Picker). Both gateways call
/// [ensureGoogleSignInInit]; the first wins, later calls await the same
/// future. Both features use the SAME web OAuth client id
/// (`integrations.kaya_gmail.server_client_id`), so there is no
/// conflicting-config case in practice.
library;

import 'package:google_sign_in/google_sign_in.dart';

Future<void>? _initialized;

Future<void> ensureGoogleSignInInit(String serverClientId) {
  return _initialized ??=
      GoogleSignIn.instance.initialize(serverClientId: serverClientId);
}
