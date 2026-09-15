/**
 * Telemetry backend switch for the FirebaseWrapper data-layer shim.
 *
 * Compile-time/profile switch that selects which telemetry backend a shim
 * delegates to. Currently supported backends:
 *  - Firebase: GA4 Measurement Protocol for Analytics and Firebase Crashlytics
 *    ingestion for crash reports.
 *  - Huawei: Huawei HiAppEvent / AGC telemetry path for Analytics and a
 *    Huawei-friendly crash/error ingest path for Crashlytics. The Huawei
 *    backend is currently a documented shell; its exact payload contract
 *    must be confirmed from Huawei platform documentation before shipping.
 *
 * This module is the single place that decides "which backend" for telemetry.
 * App code and shim facades should depend on this enum, not on backend-specific
 * endpoint constants directly.
 */
export enum TelemetryBackend {
  /**
   * Firebase REST backend.
   *
   * Analytics: GA4 Measurement Protocol batched POST to
   * `https://firebaselogging-pa.googleapis.com/v1/measurement`.
   *
   * Crashlytics: JS-level crash reports POSTed to
   * `https://firebasecrashlytics-pa.googleapis.com`.
   *
   * Known limitations (same as current SDK):
   *  - Analytics has no automatic lifecycle tracking. Foreground/background,
   *    session start, screen view, first_open, and similar events must be
   *    recorded explicitly by the app or by a lifecycle helper layer.
   *  - Crashlytics captures JS-level errors only. There is no native signal/mach
   *    capture and no dSYM symbolication from Google's NDK pipeline.
   */
  Firebase = 'firebase',

  /**
   * Huawei backend.
   *
   * Intended target: Huawei HiAppEvent / AGC telemetry for Analytics and a
   * Huawei-friendly crash/error reporting path for Crashlytics.
   *
   * Current state: shell implementation only. The exact Huawei endpoint and
   * required payload fields are not implemented yet. The shell exists so the
   * compile-time switch works and so the Huawei contract is isolated in one
   * place. Do not ship the Huawei backend until its wire contract is confirmed
   * from Huawei platform documentation.
   *
   * Known limitations (same as Firebase backend plus Huawei deltas):
   *  - Same Analytics lifecycle and Crashlytics JS-only limits apply unless
   *    Huawei provides equivalent behavior through its own APIs.
   *  - Any Huawei-specific app identity, channel, session, or batching
   *    requirements must be wired explicitly here.
   */
  Huawei = 'huawei'
}

/**
 * Stable interface an analytics shim backend must satisfy.
 *
 * The shim layer normalizes app-side `logEvent(name, params)` calls and
 * delegates to one backend. The backend owns the actual wire format and
 * flush strategy.
 */
export interface AnalyticsShimBackend {
  /**
   * Record a named analytics event with typed parameters.
   */
  logEvent(name: string, params: Array<AnalyticsParam>): void;

  /**
   * Start any background flush timer the backend needs. Called once after
   * construction in the shim.
   */
  start(): void;

  /**
   * Stop background flush work. Called on ability destroy / teardown.
   */
  stop(): void;
}

/**
 * Stable interface a crash shim backend must satisfy.
 *
 * The shim layer keeps the same reporting surface regardless of backend so
 * app code does not change when the compile-time switch is flipped.
 */
export interface CrashShimBackend {
  /**
   * Ship a crash report in the background.
   */
  report(details: CrashDetails): void;

  /**
   * Flush any persisted unsent reports.
   */
  flushQueue(): Promise<number>;

  /**
   * Add a breadcrumb attached to the next report.
   */
  log(message: string): void;

  /**
   * Set user identifier attached to subsequent reports.
   */
  setUserId(user: string): void;

  /**
   * Set a custom key attached to the next report.
   */
  setCustomKey(key: string, value: string): void;
}

/**
 * One parameter of a Measurement/telemetry event.
 *
 * Kept identical to the existing analytics module shape so backends can share
 * the same caller-facing parameter type.
 */
export class AnalyticsParam {
  key: string;
  value: Object;

  constructor(key: string, value: Object) {
    this.key = key;
    this.value = value;
  }
}

/**
 * A reportable exception detail.
 *
 * Kept identical to the existing crash module shape so backends can share the
 * same caller-facing detail type.
 */
export class CrashDetails {
  name: string;
  message: string;
  stackTrace: string;
  /** Optional key/value breadcrumbs. */
  customKeys: Array<CrashKey>;

  constructor(name: string, message: string, stackTrace: string, customKeys: Array<CrashKey>) {
    this.name = name;
    this.message = message;
    this.stackTrace = stackTrace;
    this.customKeys = customKeys;
  }

  static fromError(error: Error): CrashDetails {
    const stack: string = error.stack !== undefined ? error.stack as string : '';
    return new CrashDetails(error.name, error.message, stack, new Array<CrashKey>());
  }
}

export class CrashKey {
  key: string;
  value: string;

  constructor(key: string, value: string) {
    this.key = key;
    this.value = value;
  }
}
