/**
 * Firebase backend factory for the telemetry shim.
 *
 * This is the place that builds the current Firebase-backed implementations
 * from the existing SDK pieces. When a Huawei backend is added, its factory
 * should live in the same shim package and be selected by the same config.
 */
import { HttpTransport } from '../common/HttpTransport';
import { KeyValueStore } from '../common/KeyValueStore';
import { CrashContext } from '../crashlytics/Crashlytics';
import { TelemetryBackend, TelemetryShimConfig } from './TelemetryBackend';
import { AnalyticsShim, FirebaseAnalyticsBackendAdapter } from './AnalyticsShim';
import { CrashShim, FirebaseCrashBackendAdapter } from './CrashShim';

/**
 * Build an analytics shim backed by Firebase REST.
 *
 * This is the current production backend. It delegates to `AnalyticsApi` and
 * preserves the existing batching, queue, and fire-and-forget behavior.
 */
export function firebaseAnalyticsBackend(
  http: HttpTransport,
  config: TelemetryShimConfig,
  clientAnonymousId: string,
  errorSink: (error: Object) => void
): AnalyticsShim {
  const adapter = new FirebaseAnalyticsBackendAdapter(
    http,
    'https://firebaselogging-pa.googleapis.com/v1/measurement',
    clientAnonymousId,
    errorSink
  );
  return new AnalyticsShim(adapter);
}

/**
 * Build a crash backend shim backed by Firebase Crashlytics ingestion.
 *
 * This is the current production backend. It delegates to `Crashlytics` and
 * preserves the existing breadcrumb, queue, and flush-on-start behavior.
 */
export function firebaseCrashBackend(
  http: HttpTransport,
  config: TelemetryShimConfig,
  context: CrashContext,
  errorSink: (error: Object) => void,
  queue?: KeyValueStore
): CrashShim {
  const adapter = new FirebaseCrashBackendAdapter(
    http,
    'https://firebasecrashlytics-pa.googleapis.com',
    context,
    errorSink,
    queue
  );
  return new CrashShim(adapter);
}

/**
 * Build the analytics shim selected by config.
 *
 * Currently this only returns the Firebase backend. The Huawei backend is a
 * documented shell and is not implemented yet.
 */
export function analyticsShim(
  http: HttpTransport,
  config: TelemetryShimConfig,
  clientAnonymousId: string,
  errorSink: (error: Object) => void
): AnalyticsShim {
  if (config.backend === TelemetryBackend.Huawei) {
    return huaweiAnalyticsShim(http, config, clientAnonymousId, errorSink);
  }
  return firebaseAnalyticsBackend(http, config, clientAnonymousId, errorSink);
}

/**
 * Build the crash shim selected by config.
 *
 * Currently this only returns the Firebase backend. The Huawei backend is a
 * documented shell and is not implemented yet.
 */
export function crashShim(
  http: HttpTransport,
  config: TelemetryShimConfig,
  context: CrashContext,
  errorSink: (error: Object) => void,
  queue?: KeyValueStore
): CrashShim {
  if (config.backend === TelemetryBackend.Huawei) {
    return huaweiCrashShim(http, config, context, errorSink, queue);
  }
  return firebaseCrashBackend(http, config, context, errorSink, queue);
}
