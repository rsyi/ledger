/// Injectable seam between MacrofactorIntegration and the `health`
/// plugin. Platform-channel calls can't run in tests (or on the host at
/// all), so the integration depends on this interface and the thin
/// [HealthPluginGateway] adapter is the only code that touches the
/// plugin. The adapter converts plugin objects to plain maps at the
/// boundary; everything downstream (transforms, ingest) is pure Dart —
/// see `macrofactor.dart`.
library;

import 'package:health/health.dart';

/// Health Connect SDK availability on this device.
enum HcAvailability {
  /// SDK ready — permissions and reads will work.
  available,

  /// The Health Connect provider APK needs to be installed or updated
  /// (Android 13 and below, or stale provider).
  needsInstall,

  /// Health Connect can't run on this device.
  unavailable,
}

/// Minimal Health Connect surface the Macrofactor integration needs.
abstract class HealthConnectGateway {
  Future<HcAvailability> availability();

  /// Open the Play Store install/update flow for the provider APK.
  Future<void> installHealthConnect();

  /// Show the system permission sheet for READ nutrition. Returns true
  /// when access was granted.
  Future<bool> requestNutritionPermission();

  /// True when READ nutrition is currently granted.
  Future<bool> hasNutritionPermission();

  /// Nutrition records in [start, end) as plain maps:
  /// `{uuid, date_from (DateTime, local), name, meal_type, calories,
  /// protein, carbs, fat, source_name}` — the shape
  /// `hcNutritionToRecords` consumes. Throws on plugin/platform errors
  /// (the integration's pull() contains them).
  Future<List<Map<String, dynamic>>> readNutrition(
      DateTime start, DateTime end);
}

/// Real adapter over the `health` plugin. Thin by design: convert,
/// don't decide — all policy lives in the integration + transforms.
class HealthPluginGateway implements HealthConnectGateway {
  HealthPluginGateway({Health? health}) : _health = health ?? Health();

  final Health _health;
  bool _configured = false;

  static const _types = [HealthDataType.NUTRITION];
  static const _perms = [HealthDataAccess.READ];

  Future<void> _ensureConfigured() async {
    if (_configured) return;
    await _health.configure();
    _configured = true;
  }

  @override
  Future<HcAvailability> availability() async {
    await _ensureConfigured();
    final status = await _health.getHealthConnectSdkStatus();
    return switch (status) {
      HealthConnectSdkStatus.sdkAvailable => HcAvailability.available,
      HealthConnectSdkStatus.sdkUnavailableProviderUpdateRequired =>
        HcAvailability.needsInstall,
      _ => HcAvailability.unavailable,
    };
  }

  @override
  Future<void> installHealthConnect() async {
    await _ensureConfigured();
    await _health.installHealthConnect();
  }

  @override
  Future<bool> requestNutritionPermission() async {
    await _ensureConfigured();
    return _health.requestAuthorization(_types, permissions: _perms);
  }

  @override
  Future<bool> hasNutritionPermission() async {
    await _ensureConfigured();
    return await _health.hasPermissions(_types, permissions: _perms) ??
        false;
  }

  @override
  Future<List<Map<String, dynamic>>> readNutrition(
      DateTime start, DateTime end) async {
    await _ensureConfigured();
    final points = await _health.getHealthDataFromTypes(
      types: _types,
      startTime: start,
      endTime: end,
    );
    return [
      for (final p in points)
        {
          'uuid': p.uuid,
          'date_from': p.dateFrom,
          // A NUTRITION point's value is always NutritionHealthValue;
          // guard anyway so a plugin surprise degrades to a macro-less
          // map (the raw uuid still reaches the reconcile diff).
          if (p.value case final NutritionHealthValue v) ...{
            'name': v.name,
            'meal_type': v.mealType,
            'calories': v.calories,
            'protein': v.protein,
            'carbs': v.carbs,
            'fat': v.fat,
          },
          'source_name': p.sourceName,
        },
    ];
  }
}
