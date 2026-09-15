/**
 * Huawei backend shells for the telemetry shim.
 *
 * These exist so the compile-time switch compiles and so the Huawei contract is
 * isolated now instead of being invented later inline.
 *
 * Until the Huawei HiAppEvent / AGC event-reporting and crash/error-reporting
 * API contracts are confirmed from Huawei platform documentation, these
 * adapters no-op and report through the error sink when one is provided.
 *
 * Do not ship the Huawei backend until the wire contract is implemented and
 * reviewed. The rest of the shim is backend-agnostic and should not depend on
 * assumptions about Huawei field names here.
 */
import { HttpTransport } from '../common/HttpTransport';
import { KeyValueStore } from '../common/KeyValueStore';
import { CrashContext } from '../crashlytics/Crashlytics';
import { TelemetryBackend, TelemetryShimConfig } from './TelemetryBackend';
import { AnalyticsShim, ShimAnalyticsParam } from './AnalyticsShim';
import { CrashShim, CrashDetails, CrashKey } from './CrashShim';

/**
 * Placeholder Huawei analytics backend.
 */
export class HuaweiAnalyticsBackendAdapter {
  private errorSink: (error: Object) => void;

  constructor(http: HttpTransport, config: TelemetryShimConfig, clientAnonymousId: string, errorSink: (error: Object) => void) {
    this.errorSink = errorSink;
    // The actual Huawei transport/identity wiring would go here once the
    // Huawei API contract is known.
    (void)http;
    (void)config;
    (void)clientAnonymousId;
  }

  logEvent(name: string, params: Array<ShimAnalyticsParam>): void {
    this.enqueueOrNoop(name, params);
  }

  start(): void {
    // Huawei analytics may or may not need an explicit start step.
    // Placeholder.
  }

  stop(): void {
    // Placeholder.
  }

  private enqueueOrNoop(name: string, params: Array<ShimAnalyticsParam>): void {
    if (this.errorSink !== undefined) {
      try {
        this.errorSink({
          code: 'SHIM_HUAWEI_ANALYTICS_UNAVAILABLE',
          detail: `Analytics backend is set to Huawei but the Huawei analytics backend is not implemented yet. event=${name}`
        });
      } catch (err) {
        // Never let the sink break the app.
      }
    }
  }
}

/**
 * Placeholder Huawei crash backend.
 */
export class HuaweiCrashBackendAdapter {
  private errorSink: (error: Object) => void;
  private breadcrumbs: Array<CrashKey>;
  private userId: string;

  constructor(http: HttpTransport, config: TelemetryShimConfig, context: CrashContext, errorSink: (error: Object) => void, queue?: KeyValueStore) {
    this.errorSink = errorSink;
    this.breadcrumbs = new Array<CrashKey>();
    this.userId = context.user;
    // The actual Huawei transport/queue/identity wiring would go here once the
    // Huawei API contract is known.
    (void)http;
    (void)config;
    (void)context;
    (void)queue;
  }

  report(details: CrashDetails): void {
    this.enqueueOrNoop(details);
  }

  flushQueue(): Promise<number> {
    return Promise.resolve(0);
  }

  log(message: string): void {
    this.breadcrumbs.push(new CrashKey(`crumb${this.breadcrumbs.length}`, message));
    if (this.breadcrumbs.length > 32) {
      this.breadcrumbs.splice(0, this.breadcrumbs.length - 32);
    }
  }

  setUserId(user: string): void {
    this.userId = user;
  }

  setCustomKey(key: string, value: string): void {
    this.breadcrumbs.push(new CrashKey(key, value));
  }

  private enqueueOrNoop(details: CrashDetails): void {
    if (this.errorSink !== undefined) {
      try {
        this.errorSink({
          code: 'SHIM_HUAWEI_CRASH_UNAVAILABLE',
          detail: `Crash backend is set to Huawei but the Huawei crash backend is not implemented yet. error=${details.name}`
        });
      } catch (err) {
        // Never let the sink break the app.
      }
    }
  }
}

function huaweiAnalyticsShim(
  http: HttpTransport,
  config: TelemetryShimConfig,
  clientAnonymousId: string,
  errorSink: (error: Object) => void
): AnalyticsShim {
  const adapter = new HuaweiAnalyticsBackendAdapter(http, config, clientAnonymousId, errorSink);
  return new AnalyticsShim(adapter);
}

function huaweiCrashShim(
  http: HttpTransport,
  config: TelemetryShimConfig,
  context: CrashContext,
  errorSink: (error: Object) => void,
  queue?: KeyValueStore
): CrashShim {
  const adapter = new HuaweiCrashBackendAdapter(http, config, context, errorSink, queue);
  return new CrashShim(adapter);
}
