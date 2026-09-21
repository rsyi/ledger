package com.robertyi.ledger

// FlutterFragmentActivity (a ComponentActivity), not FlutterActivity:
// the health plugin registers Health Connect's permission-request
// ActivityResultContract, which needs a ComponentActivity host.
import io.flutter.embedding.android.FlutterFragmentActivity

class MainActivity : FlutterFragmentActivity()
