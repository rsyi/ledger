// ignore_for_file: avoid_print
//
// Branded build CLI for airledger.
//
// Reads a branding config (defaults to `~/repos/airledger-schemas/ledger.yaml`)
// and turns the generic Ledger app into a custom-branded install on a
// connected Android device:
//
//   1. Writes `android/app/src/main/res/values/strings.xml` so the launcher
//      label changes (the manifest references `@string/app_name`).
//   2. Regenerates launcher icons via `flutter_launcher_icons` from the
//      icon path in the config.
//   3. Runs `tool/sync_assets.sh` so schemas/templates/apps/SA-key are
//      bundled fresh.
//   4. `flutter build apk --release`.
//   5. `adb install -r` + `adb shell monkey` (launches the app).
//
// Usage (from anywhere):
//   dart run ~/repos/airledger/tool/brand.dart
//   dart run ~/repos/airledger/tool/brand.dart --config /path/to/ledger.yaml
//   dart run ~/repos/airledger/tool/brand.dart --device 57041FDCH002VN
//
// ledger.yaml schema (all fields except app_name optional):
//   app_name: "Fitness Logger"
//   icon: assets/fitness-icon.png        # path relative to the yaml
//   adb_device: 57041FDCH002VN           # optional default device
//   skip_icons: false                    # skip the icon regen step

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import 'build_config.dart';

const _defaultConfig = '~/repos/airledger-fitness/ledger.yaml';
const _airledgerRepo = '~/repos/ledger';
const _defaultPackage = 'com.robertyi.ledger';

Future<int> main(List<String> argv) async {
  final args = _parseArgs(argv);
  final configPath = _expand(args['config'] ?? _defaultConfig);
  final airledgerDir = Directory(_expand(_airledgerRepo));
  if (!airledgerDir.existsSync()) {
    print('error: ledger repo not found at ${airledgerDir.path}');
    return 1;
  }
  final config = _BrandConfig.load(configPath);

  print('› Branding: ${config.appName}'
      '${config.iconAbsolute != null ? "  icon=${p.basename(config.iconAbsolute!)}" : ""}');

  // 1. strings.xml
  _writeStringsXml(airledgerDir, config.appName);

  // 2. applicationId — only patch & clean when switching to a new package.
  // Switching applicationId without a clean leaves stale build artifacts
  // that confuse the install (e.g. INSTALL_FAILED_UPDATE_INCOMPATIBLE).
  final gradleFile = File(p.join(
      airledgerDir.path, 'android', 'app', 'build.gradle.kts'));
  final previousAppId = _readApplicationId(gradleFile);
  if (previousAppId != config.packageId) {
    _patchApplicationId(gradleFile, config.packageId);
    print('› applicationId: $previousAppId → ${config.packageId}');
    final r = await _run('flutter', ['clean'], workingDir: airledgerDir.path);
    if (r != 0) return r;
  }

  // 3. icons
  // Always reset launcher icons to the tracked baseline first so a brand
  // without a custom icon doesn't inherit the previous brand's logo
  // (flutter_launcher_icons writes into the shared mipmap-* dirs).
  await _resetLauncherIconsFromGit(airledgerDir);
  if (config.iconAbsolute != null && !config.skipIcons) {
    _writeLauncherIconConfig(airledgerDir, config.iconAbsolute!);
    final r = await _run('dart',
        ['run', 'flutter_launcher_icons', '-f', 'flutter_launcher_icons.yaml'],
        workingDir: airledgerDir.path);
    if (r != 0) return r;
  } else {
    print('› No custom icon — using tracked baseline');
  }

  // 4. sync_assets.sh — point at this config's schemas repo.
  final configDir = p.dirname(File(configPath).absolute.path);
  final syncSh = File(p.join(airledgerDir.path, 'tool', 'sync_assets.sh'));
  if (syncSh.existsSync()) {
    final r = await _run(
      'bash',
      [syncSh.path],
      workingDir: airledgerDir.path,
      environment: {
        'SCHEMAS_SRC': p.join(configDir, 'views'),
        'TEMPLATES_SRC': p.join(configDir, 'templates'),
        'APPS_SRC': p.join(configDir, 'apps'),
      },
    );
    if (r != 0) return r;
  }

  // 4b. Resolve <schemas-dir>/config.yml with .env-backed env vars and
  // write the result to assets/config.yaml. This is the oxy-compatible
  // databases:-style config; the bundled assets/config.yaml's legacy
  // top-level spreadsheet_id (synced by sync_assets.sh from
  // ~/.config/airledger/config.yaml) is preserved underneath as a fallback.
  final repoConfig = File(p.join(configDir, 'config.yml'));
  if (repoConfig.existsSync()) {
    final env = loadEnvFile(configDir);
    final raw = loadYaml(repoConfig.readAsStringSync());
    final resolved = resolveConfig(raw, env);
    final out = File(p.join(airledgerDir.path, 'assets', 'config.yaml'));
    out.writeAsStringSync(emitYaml(resolved));
    print('› Resolved ${repoConfig.path} → assets/config.yaml '
        '(${env.length} env var(s) available)');
  }

  // 5. flutter build apk --release
  final r1 = await _run('flutter', ['build', 'apk', '--release'],
      workingDir: airledgerDir.path);
  if (r1 != 0) return r1;

  // 5. adb install + launch
  final apk = p.join(
      airledgerDir.path, 'build', 'app', 'outputs', 'flutter-apk', 'app-release.apk');
  final adbDevice = args['device'] ?? config.adbDevice;
  final adbBase = adbDevice == null ? <String>[] : ['-s', adbDevice];
  final r2 = await _run('adb', [...adbBase, 'install', '-r', apk]);
  if (r2 != 0) return r2;
  final r3 = await _run('adb', [
    ...adbBase,
    'shell',
    'monkey',
    '-p',
    config.packageId,
    '-c',
    'android.intent.category.LAUNCHER',
    '1',
  ]);
  if (r3 != 0) return r3;

  // Restore tracked launcher icons + strings.xml + build.gradle.kts back to
  // the airledger baseline. The APK we just installed has the brand-specific
  // versions baked in; the working tree no longer needs them. Leaving these
  // dirty between builds risks a future `git add -A` sweeping the previous
  // build's branding into the airledger repo's tracked baseline — which has
  // happened (twice) and caused the next brand's build to ship the previous
  // brand's launcher icon.
  await _resetLauncherIconsFromGit(airledgerDir);
  await _run(
    'git',
    [
      'checkout',
      '--',
      'android/app/build.gradle.kts',
      'android/app/src/main/res/values/strings.xml',
    ],
    workingDir: airledgerDir.path,
  );

  print('\n✓ Installed and launched ${config.appName} '
      '(${config.packageId})');
  return 0;
}

Map<String, String> _parseArgs(List<String> argv) {
  final out = <String, String>{};
  for (var i = 0; i < argv.length; i++) {
    final a = argv[i];
    if (a == '--config' && i + 1 < argv.length) out['config'] = argv[++i];
    if (a == '--device' && i + 1 < argv.length) out['device'] = argv[++i];
    if (a == '-h' || a == '--help') {
      _printHelpAndExit();
    }
  }
  return out;
}

void _printHelpAndExit() {
  print('Usage: dart run ~/repos/airledger/tool/brand.dart [options]');
  print('  --config <path>   branding YAML (default $_defaultConfig)');
  print('  --device <serial> adb device serial');
  exit(0);
}

void _writeStringsXml(Directory airledgerDir, String appName) {
  final f = File(p.join(
    airledgerDir.path,
    'android',
    'app',
    'src',
    'main',
    'res',
    'values',
    'strings.xml',
  ));
  // XML-encode the name minimally.
  final escaped = appName
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&apos;');
  f.writeAsStringSync(
    '<?xml version="1.0" encoding="utf-8"?>\n'
    '<resources>\n'
    '    <string name="app_name">$escaped</string>\n'
    '</resources>\n',
  );
  print('› Wrote res/values/strings.xml (app_name="$appName")');
}

/// Restore launcher icons to the tracked baseline (the Airledger default).
///
/// flutter_launcher_icons writes into FOUR places — every brand-build that
/// supplies its own icon overwrites all four. To get a clean reset before
/// the next build we `git checkout` all of them, returning to whatever
/// the airledger-default icon committed at HEAD looks like:
///   - mipmap-{hdpi…xxxhdpi}/ic_launcher.png  (legacy launcher icon)
///   - mipmap-anydpi-v26/ic_launcher.xml      (adaptive icon definition)
///   - drawable-{hdpi…xxxhdpi}/ic_launcher_foreground.png  (adaptive fg)
///   - values/colors.xml                       (adaptive background color)
///
/// Unbranded builds (no `icon:` in ledger.yaml) skip the
/// flutter_launcher_icons step and ship with the airledger default.
/// Branded builds overwrite all four sets, then the next reset restores
/// the airledger default again — so brands can't bleed into each other.
Future<int> _resetLauncherIconsFromGit(Directory airledgerDir) async {
  return _run(
    'git',
    [
      'checkout',
      '--',
      'android/app/src/main/res/mipmap-hdpi',
      'android/app/src/main/res/mipmap-mdpi',
      'android/app/src/main/res/mipmap-xhdpi',
      'android/app/src/main/res/mipmap-xxhdpi',
      'android/app/src/main/res/mipmap-xxxhdpi',
      'android/app/src/main/res/mipmap-anydpi-v26',
      'android/app/src/main/res/drawable-hdpi/ic_launcher_foreground.png',
      'android/app/src/main/res/drawable-mdpi/ic_launcher_foreground.png',
      'android/app/src/main/res/drawable-xhdpi/ic_launcher_foreground.png',
      'android/app/src/main/res/drawable-xxhdpi/ic_launcher_foreground.png',
      'android/app/src/main/res/drawable-xxxhdpi/ic_launcher_foreground.png',
      'android/app/src/main/res/values/colors.xml',
    ],
    workingDir: airledgerDir.path,
  );
}

void _writeLauncherIconConfig(Directory airledgerDir, String iconPath) {
  final f = File(p.join(airledgerDir.path, 'flutter_launcher_icons.yaml'));
  f.writeAsStringSync(
    'flutter_launcher_icons:\n'
    '  android: "ic_launcher"\n'
    '  ios: false\n'
    '  image_path: "$iconPath"\n'
    '  adaptive_icon_background: "#0A0A0A"\n'
    '  adaptive_icon_foreground: "$iconPath"\n',
  );
}

Future<int> _run(
  String exe,
  List<String> args, {
  String? workingDir,
  Map<String, String>? environment,
}) async {
  print('\$ $exe ${args.join(' ')}');
  final proc = await Process.start(
    exe,
    args,
    workingDirectory: workingDir,
    environment: environment,
    includeParentEnvironment: true,
    mode: ProcessStartMode.inheritStdio,
    runInShell: true,
  );
  return proc.exitCode;
}

String? _readApplicationId(File gradle) {
  final body = gradle.readAsStringSync();
  final m = RegExp(r'applicationId\s*=\s*"([^"]+)"').firstMatch(body);
  return m?.group(1);
}

void _patchApplicationId(File gradle, String newId) {
  final body = gradle.readAsStringSync();
  final patched = body.replaceFirst(
    RegExp(r'applicationId\s*=\s*"[^"]+"'),
    'applicationId = "$newId"',
  );
  gradle.writeAsStringSync(patched);
}

String _expand(String path) {
  if (path.startsWith('~/') || path == '~') {
    final home = Platform.environment['HOME'] ?? '';
    return p.join(home, path.substring(2));
  }
  return path;
}

class _BrandConfig {
  final String appName;
  final String? iconAbsolute;
  final String? adbDevice;
  final String packageId;
  final bool skipIcons;

  _BrandConfig({
    required this.appName,
    required this.iconAbsolute,
    required this.adbDevice,
    required this.packageId,
    required this.skipIcons,
  });

  static _BrandConfig load(String configPath) {
    final f = File(configPath);
    if (!f.existsSync()) {
      // No config: ship as default "Ledger" with no icon override.
      print('› No config at $configPath — using defaults');
      return _BrandConfig(
        appName: 'Ledger',
        iconAbsolute: null,
        adbDevice: null,
        packageId: _defaultPackage,
        skipIcons: true,
      );
    }
    final node = loadYaml(f.readAsStringSync()) as YamlMap;
    final iconRel = node['icon'] as String?;
    final iconAbs = iconRel == null
        ? null
        : p.normalize(p.join(p.dirname(f.path), iconRel));
    if (iconAbs != null && !File(iconAbs).existsSync()) {
      print('warning: icon $iconAbs not found — skipping icon regen');
    }
    return _BrandConfig(
      appName: (node['app_name'] as String?) ?? 'Ledger',
      iconAbsolute:
          (iconAbs != null && File(iconAbs).existsSync()) ? iconAbs : null,
      adbDevice: node['adb_device'] as String?,
      packageId: (node['package_id'] as String?) ?? _defaultPackage,
      skipIcons: (node['skip_icons'] as bool?) ?? false,
    );
  }
}
