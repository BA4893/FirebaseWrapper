/**
 * Firebase backend adapter for analytics.
 *
 * Delegates directly to the existing `AnalyticsApi`. This preserves current
 * behavior while letting the shim swap backends by config.
 */
import { AnalyticsApi, AnalyticsParam as FirebaseAnalyticsParam } from '../analytics/AnalyticsApi';
import { HttpTransport } from '../common/HttpTransport';
import { TelemetryShimConfig } from './ShimConfig';
import { AnalyticsShimBackend, AnalyticsShim, ShimAnalyticsParam } from './AnalyticsShim';

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
