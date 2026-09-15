/**
 * Compile-time/profile configuration for the telemetry shim.
 *
 * This is the switch that selects which backend the shim delegates to. It is
 * intentionally separate from `FirebaseOptions` because it is not a Firebase
 * configuration value; it is a local architectural choice about where telemetry
 * is sent.
 *
 * Usage:
 *  - Set `TelemetryShimConfig.backend` in your app config before initializing
 *    the SDK or before creating the shim.
 *  - The shim factory reads this value and builds the matching backend.
 *
 * Current defaults:
 *  - `backend`: `TelemetryBackend.Firebase`
 *
 * This file is intentionally free of platform-kit imports. It only holds
 * plain configuration values.
 */
export class TelemetryShimConfig {
  /**
   * Selected telemetry backend for the whole app.
   *
   * Default: Firebase.
   */
  backend: TelemetryBackend;

  /**
   * Huawei app identity used by the Huawei backend, when enabled.
   *
   * Current state: required-by-design placeholder. The Huawei backend shell
   * will eventually need an app/channel identifier; this field exists so the
   * config surface is ready. Until the Huawei wire contract is confirmed, this
   * value is not used for anything.
   */
  huaweiAppId: string;

  constructor() {
    this.backend = TelemetryBackend.Firebase;
    this.huaweiAppId = '';
  }

  static firebase(): TelemetryShimConfig {
    const c = new TelemetryShimConfig();
    c.backend = TelemetryBackend.Firebase;
    return c;
  }

  static huawei(huaweiAppId: string): TelemetryShimConfig {
    const c = new TelemetryShimConfig();
    c.backend = TelemetryBackend.Huawei;
    c.huaweiAppId = huaweiAppId;
    return c;
  }
}
