import { HttpTransport } from '../common/HttpTransport';
import { KeyValueStore } from '../common/KeyValueStore';
import { FirebaseException } from '../common/FirebaseError';
import { Json } from '../common/Json';

const DEFAULT_CRASHLYTICS_URL: string = 'https://firebasecrashlytics-pa.googleapis.com';

/**
 * Static context attached to every crash report.
 */
export class CrashContext {
  appVersion: string;
  deviceModel: string;
  platform: string;
  sessionId: string;
  user: string;

  constructor(appVersion: string, deviceModel: string, platform: string, sessionId: string, user: string) {
    this.appVersion = appVersion;
    this.deviceModel = deviceModel;
    this.platform = platform;
    this.sessionId = sessionId;
    this.user = user;
  }
}

/**
 * A single reportable exception detail.
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

/**
 * Crashlytics ingestion with a persisted unsent-report queue.
 *
 * ArkTS has no signal/mach daemon: JS errors + the EntryAbility hook are the
 * capture path. Reports that fail to upload are queued in the KeyValueStore
 * and flushed on the next successful send (mirrors iOS unsent-reports).
 */
export class Crashlytics {
  private transport: HttpTransport;
  private endpoint: string;
  private context: CrashContext;
  private errorSink: crashErrorSink;
  private queue: KeyValueStore | undefined;
  private breadcrumbs: Array<CrashKey>;

  constructor(transport: HttpTransport, endpoint: string, context: CrashContext,
    errorSink: crashErrorSink, queue?: KeyValueStore) {
    this.transport = transport;
    this.endpoint = endpoint.length > 0 ? endpoint : DEFAULT_CRASHLYTICS_URL;
    this.context = context;
    this.errorSink = errorSink;
    this.queue = queue;
    this.breadcrumbs = new Array<CrashKey>();
  }

  /** Adds a breadcrumb attached to the next report. */
  log(message: string): void {
    this.breadcrumbs.push(new CrashKey(`crumb${this.breadcrumbs.length}`, message));
    if (this.breadcrumbs.length > 32) {
      this.breadcrumbs.splice(0, this.breadcrumbs.length - 32);
    }
  }

  setUserId(user: string): void {
    this.context.user = user;
  }

  setCustomKey(key: string, value: string): void {
    this.breadcrumbs.push(new CrashKey(key, value));
  }

  /**
   * Ships a crash report in the background (no await by callers).
   */
  report(details: CrashDetails): void {
    const merged: CrashDetails = this.withCrumbs(details);
    this.send(merged).then(() => {
      this.flushQueue();
    }).catch((err: Error) => {
      this.enqueue(merged);
      if (this.errorSink !== undefined) {
        this.errorSink(err as FirebaseException);
      }
    });
  }

  /** Flushes persisted unsent reports. Call on app start. */
  async flushQueue(): Promise<number> {
    if (this.queue === undefined) {
      return 0;
    }
    let sent: number = 0;
    const keys: Array<string> = Crashlytics.pendingKeys(this.queue);
    for (let i: number = 0; i < keys.length; i++) {
      const raw: string = this.queue.get(keys[i], '');
      if (raw.length === 0) {
        continue;
      }
      try {
        const envelope = await this.transport.post(this.endpoint, raw, [], '');
        if (envelope.isOk()) {
          this.queue.remove(keys[i]);
          sent++;
        }
      } catch (err) {
        break;
      }
    }
    return sent;
  }

  private withCrumbs(details: CrashDetails): CrashDetails {
    if (this.breadcrumbs.length === 0) {
      return details;
    }
    const keys: Array<CrashKey> = new Array<CrashKey>();
    for (let i: number = 0; i < details.customKeys.length; i++) {
      keys.push(details.customKeys[i]);
    }
    for (let i: number = 0; i < this.breadcrumbs.length; i++) {
      keys.push(this.breadcrumbs[i]);
    }
    return new CrashDetails(details.name, details.message, details.stackTrace, keys);
  }

  private enqueue(details: CrashDetails): void {
    if (this.queue === undefined) {
      return;
    }
    const body: Object = {};
    body['session'] = this.context.sessionId;
    body['platform'] = this.context.platform;
    body['app_version'] = this.context.appVersion;
    body['device_model'] = this.context.deviceModel;
    body['exception'] = details.name;
    body['message'] = details.message;
    body['stack_trace'] = details.stackTrace;
    this.queue.set(`crashlytics.pending.${Date.now()}`, JSON.stringify(body));
  }

  private static pendingKeys(queue: KeyValueStore): Array<string> {
    return queue.keysWithPrefix('crashlytics.pending.');
  }

  /**
   * Convenience: build details from an Error and send.
   */
  reportError(error: Error): void {
    this.report(CrashDetails.fromError(error));
  }

  /**
   * Serializes + POSTs the report body.
   */
  async send(details: CrashDetails): Promise<void> {
    const body: Object = {};
    body['session'] = this.context.sessionId;
    body['platform'] = this.context.platform;
    body['app_version'] = this.context.appVersion;
    body['device_model'] = this.context.deviceModel;
    if (this.context.user.length > 0) {
      body['user'] = this.context.user;
    }
    body['exception'] = details.name;
    body['message'] = details.message;
    body['stack_trace'] = details.stackTrace;
    if (details.customKeys.length > 0) {
      const keys: Object = {};
      for (let i: number = 0; i < details.customKeys.length; i++) {
        keys[details.customKeys[i].key] = details.customKeys[i].value;
      }
      body['custom_keys'] = keys;
    }
    const envelope = await this.transport.post(this.endpoint, JSON.stringify(body), [], '');
    if (!envelope.isOk()) {
      throw FirebaseException.api('crashlytics', Json.firebaseErrorMessage(envelope.text));
    }
  }
}

export type crashErrorSink = (error: FirebaseException) => void;