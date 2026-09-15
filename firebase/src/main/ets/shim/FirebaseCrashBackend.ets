/**
 * Firebase backend adapter for crash reporting.
 *
 * Delegates directly to the existing `Crashlytics`. This preserves current
 * behavior while letting the shim swap backends by config.
 */
import { Crashlytics, CrashContext } from '../crashlytics/Crashlytics';
import { HttpTransport } from '../common/HttpTransport';
import { KeyValueStore } from '../common/KeyValueStore';
import { TelemetryShimConfig } from './ShimConfig';
import { CrashShimBackend, CrashShim, CrashDetails, CrashKey } from './CrashShim';

export class FirebaseCrashBackendAdapter implements CrashShimBackend {
  private crash: Crashlytics;

  constructor(http: HttpTransport, endpoint: string, context: CrashContext, errorSink: (error: Object) => void, queue?: KeyValueStore) {
    this.crash = new Crashlytics(http, endpoint, context, errorSink, queue);
  }

  report(details: CrashDetails): void {
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
