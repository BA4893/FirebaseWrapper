/**
 * Crashlytics shim interface + Firebase backend delegation.
 *
 * The shim keeps a stable app-facing API for crash reporting and delegates to
 * one backend selected by `TelemetryBackend`. This file currently provides:
 *  - `CrashShim`: the app-facing shim facade
 *  - `FirebaseCrashBackendAdapter`: delegates to the existing `Crashlytics`
 *
 * The Huawei crash backend is not implemented yet. When it is added, it should
 * implement `CrashShimBackend` and be instantiated by the shim factory the same
 * way the Firebase adapter is.
 *
 * Current behavioral contract (inherited from `Crashlytics`):
 *  - Only JS-level errors are captured.
 *  - Reports are persisted in a `KeyValueStore` queue and flushed on the next
 *    successful send or on app start.
 *  - Breadcrumbs, user id, and custom keys are supported.
 */
import { Crashlytics, CrashContext, CrashDetails as FirebaseCrashDetails, CrashKey as FirebaseCrashKey } from '../crashlytics/Crashlytics';
import { HttpTransport } from '../common/HttpTransport';
import { KeyValueStore } from '../common/KeyValueStore';
import { TelemetryBackend, CrashShimBackend, CrashDetails, CrashKey } from './TelemetryBackend';
import { TelemetryShimConfig } from './ShimConfig';

/**
 * App-facing crash shim.
 *
 * Create this from `ShimFactory.crashBackend(...)`. The shim selects the backend
 * from `TelemetryShimConfig.backend` and delegates `report()` calls to it.
 *
 * Example:
 * ```
 * const crash = ShimFactory.crashBackend(http, context, errorSink, store, config);
 * crash.flushQueue();
 * crash.report(new CrashDetails('MyError', 'something failed', stack, []));
 * ```
 */
export class CrashShim {
  private backend: CrashShimBackend;

  constructor(backend: CrashShimBackend) {
    this.backend = backend;
  }

  report(details: CrashDetails): void {
    const fbDetails = new FirebaseCrashDetails(details.name, details.message, details.stackTrace,
      this.toFirebaseKeys(details.customKeys));
    this.backend.report(fbDetails);
  }

  flushQueue(): Promise<number> {
    return this.backend.flushQueue();
  }

  log(message: string): void {
    this.backend.log(message);
  }

  setUserId(user: string): void {
    this.backend.setUserId(user);
  }

  setCustomKey(key: string, value: string): void {
    this.backend.setCustomKey(key, value);
  }

  private toFirebaseKeys(keys: Array<CrashKey>): Array<FirebaseCrashKey> {
    const out: Array<FirebaseCrashKey> = new Array<FirebaseCrashKey>();
    for (let i: number = 0; i < keys.length; i++) {
      out.push(new FirebaseCrashKey(keys[i].key, keys[i].value));
    }
    return out;
  }
}

/**
 * Firebase backend adapter for crash reporting.
 *
 * Delegates directly to the existing `Crashlytics`. This preserves current
 * behavior while letting the shim swap backends by config.
 */
export class FirebaseCrashBackendAdapter implements CrashShimBackend {
  private crash: Crashlytics;

  constructor(http: HttpTransport, endpoint: string, context: CrashContext, errorSink: (error: Object) => void, queue?: KeyValueStore) {
    this.crash = new Crashlytics(http, endpoint, context, errorSink, queue);
  }

  report(details: FirebaseCrashDetails): void {
    this.crash.report(details);
  }

  flushQueue(): Promise<number> {
    return this.crash.flushQueue();
  }

  log(message: string): void {
    this.crash.log(message);
  }

  setUserId(user: string): void {
    this.crash.setUserId(user);
  }

  setCustomKey(key: string, value: string): void {
    this.crash.setCustomKey(key, value);
  }
}
