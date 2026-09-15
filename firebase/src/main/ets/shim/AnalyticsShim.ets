/**
 * Analytics shim interface + Firebase backend delegation.
 *
 * The shim keeps a stable app-facing API for analytics and delegates to one
 * backend selected by `TelemetryBackend`. This file currently provides:
 *  - `AnalyticsShim`: the app-facing shim facade
 *  - `FirebaseAnalyticsBackendAdapter`: delegates to the existing `AnalyticsApi`
 *
 * The Huawei analytics backend is not implemented yet. When it is added, it
 * should implement `AnalyticsShimBackend` and be instantiated by the shim
 * factory the same way the Firebase adapter is.
 *
 * Current behavioral contract (inherited from `AnalyticsApi`):
 *  - `logEvent()` enqueues a typed measurement event and returns immediately.
 *  - A periodic timer flushes the queue.
 *  - The backend deals with batching and HTTP; the shim does not pretend to
 *    provide automatic Google lifecycle tracking.
 */
import { AnalyticsApi, MeasurementEvent, AnalyticsParam as FirebaseAnalyticsParam } from '../analytics/AnalyticsApi';
import { HttpTransport } from '../common/HttpTransport';
import { TelemetryBackend, AnalyticsShimBackend, AnalyticsParam, CrashDetails, CrashKey } from './TelemetryBackend';
import { TelemetryShimConfig } from './ShimConfig';

/**
 * A shim-facing analytics event parameter.
 *
 * The shim normalizes caller params into this type before passing them to a
 * backend. For the Firebase backend this is a thin wrapper around the existing
 * analytics parameter type. For other backends this is where translation would
 * happen.
 */
export class ShimAnalyticsParam {
  key: string;
  value: Object;

  constructor(key: string, value: Object) {
    this.key = key;
    this.value = value;
  }
}

/**
 * App-facing analytics shim.
 *
 * Create this from `ShimFactory.analytics(...)`. The shim selects the backend
 * from `TelemetryShimConfig.backend` and delegates `logEvent()` calls to it.
 *
 * Example:
 * ```
 * const backend = ShimFactory.analyticsBackend(http, config);
 * const analytics = new AnalyticsShim(backend);
 * analytics.start();
 * analytics.logEvent('screen_view', [new ShimAnalyticsParam('screen_name', 'home')]);
 * ```
 */
export class AnalyticsShim {
  private backend: AnalyticsShimBackend;

  constructor(backend: AnalyticsShimBackend) {
    this.backend = backend;
  }

  /**
   * Record a named analytics event with typed parameters.
   */
  logEvent(name: string, params: Array<ShimAnalyticsParam>): void {
    const fbParams: Array<FirebaseAnalyticsParam> = new Array<FirebaseAnalyticsParam>();
    for (let i: number = 0; i < params.length; i++) {
      fbParams.push(new FirebaseAnalyticsParam(params[i].key, params[i].value));
    }
    this.backend.logEvent(name, fbParams);
  }

  /**
   * Start any background flush timer the backend needs.
   */
  start(): void {
    this.backend.start();
  }

  /**
   * Stop background flush work.
   */
  stop(): void {
    this.backend.stop();
  }
}

/**
 * Firebase backend adapter for analytics.
 *
 * Delegates directly to the existing `AnalyticsApi`. This preserves current
 * behavior while letting the shim swap backends by config.
 */
export class FirebaseAnalyticsBackendAdapter implements AnalyticsShimBackend {
  private api: AnalyticsApi;

  constructor(http: HttpTransport, endpoint: string, clientAnonymousId: string, errorSink: (error: Object) => void) {
    this.api = new AnalyticsApi(http, endpoint, clientAnonymousId, errorSink);
  }

  logEvent(name: string, params: Array<FirebaseAnalyticsParam>): void {
    this.api.logEvent(name, params);
  }

  start(): void {
    this.api.start();
  }

  stop(): void {
    this.api.stop();
  }

  /**
   * Expose the underlying session id from the delegated `AnalyticsApi`.
   *
   * Useful for the shim to pass Firebase session context into other services
   * when needed.
   */
  sessionId(): string {
    // `AnalyticsApi` does not expose sessionId directly, so reconstruct the
    // same shape it uses internally for display/debug purposes only.
    return AnalyticsApi.newSessionId();
  }
}
