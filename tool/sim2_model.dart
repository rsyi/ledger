// sim2_model.dart — shim: the v2.1 model core was LIFTED into
// lib/services/sim2_model.dart in wave 3 (the Program tab's FORECAST
// section + the nightly forecast writer consume it there). The tools
// (sim2_fit.dart, sim2_replay.dart, sim2_horizon.dart) keep importing
// this path; everything re-exports unchanged.
export 'package:airledger/services/sim2_model.dart';
