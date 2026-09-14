import { HttpTransport } from '../common/HttpTransport';
import { FirebaseException } from '../common/FirebaseError';
import { Json } from '../common/Json';

const DEFAULT_MEASUREMENT_URL: string = 'https://firebaselogging-pa.googleapis.com/v1/measurement';

/**
 * One parameter of a Measurement event. `value` is a JSON primitive.
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
 * A GA4 Measurement Protocol event.
 */
export class MeasurementEvent {
  name: string;
  params: Array<AnalyticsParam>;
  timestampMicros: number;

  constructor(name: string, params: Array<AnalyticsParam>, timestampMicros: number) {
    this.name = name;
    this.params = params;
    this.timestampMicros = timestampMicros;
  }

  toJson(): string {
    const body: Object = {};
    body['name'] = this.name;
    body['timestamp_micros'] = this.timestampMicros;
    const params: Object = {};
    for (let i: number = 0; i < this.params.length; i++) {
      params[this.params[i].key] = this.params[i].value;
    }
    body['params'] = params;
    return JSON.stringify(body);
  }
}

/**
 * Firebase Analytics — GA4 Measurement Protocol client.
 *
 * Every custom action/event is queued and flushed to the measurement endpoint as an
 * asynchronous batched POST (≤ {@link MAX_BATCH} events or {@link FLUSH_IDLE_MS} idle).
 * Fire-and-forget: send failures are captured by the error sink, never the caller.
 */
export class AnalyticsApi {
  static readonly MAX_BATCH: number = 750;
  static readonly FLUSH_IDLE_MS: number = 10000;

  private transport: HttpTransport;
  private endpoint: string;
  private clientAnonymousId: string;
  private sessionId: string;
  private queue: Array<MeasurementEvent>;
  private errorSink: analyticsErrorSink;
  private timerId: number;
  private flushing: boolean;

  constructor(transport: HttpTransport, endpoint: string, clientAnonymousId: string,
    errorSink: analyticsErrorSink) {
    this.transport = transport;
    this.endpoint = endpoint.length > 0 ? endpoint : DEFAULT_MEASUREMENT_URL;
    this.clientAnonymousId = clientAnonymousId;
    this.sessionId = AnalyticsApi.newSessionId();
    this.queue = new Array<MeasurementEvent>();
    this.errorSink = errorSink;
    this.timerId = 0;
    this.flushing = false;
  }

  /**
   * Starts the idle-flush timer. Call once after construction.
   */
  start(): void {
    if (this.timerId !== 0) {
      return;
    }
    this.timerId = setInterval(() => {
      this.flush();
    }, AnalyticsApi.FLUSH_IDLE_MS);
  }

  stop(): void {
    if (this.timerId !== 0) {
      clearInterval(this.timerId);
      this.timerId = 0;
    }
  }

  /**
   * Logs an event. Returns immediately; network happens in the background.
   */
  logEvent(name: string, params: Array<AnalyticsParam>): void {
    const event: MeasurementEvent = new MeasurementEvent(name, params, Date.now() * 1000);
    this.queue.push(event);
    if (this.queue.length >= AnalyticsApi.MAX_BATCH) {
      this.flush();
    }
  }

  /**
   * A convenience alias for logEvent.
   */
  logEventWithParams(name: string, firstKey: string, firstValue: Object): void {
    const params: Array<AnalyticsParam> = new Array<AnalyticsParam>();
    params.push(new AnalyticsParam(firstKey, firstValue));
    this.logEvent(name, params);
  }

  /**
   * Flushes the queue (if any). Safe to call concurrently.
   */
  async flush(): Promise<void> {
    if (this.flushing) {
      return;
    }
    if (this.queue.length === 0) {
      return;
    }
    this.flushing = true;
    const batch: Array<MeasurementEvent> = this.queue.splice(0, this.queue.length);
    try {
      await this.upload(batch);
    } catch (err) {
      if (this.errorSink !== undefined) {
        try {
          this.errorSink(err as FirebaseException);
        } catch (sinkErr) {
          // never let the sink break the analytics pipeline
        }
      }
    } finally {
      this.flushing = false;
    }
  }

  async upload(batch: Array<MeasurementEvent>): Promise<void> {
    if (batch.length === 0) {
      return;
    }
    const body: Object = {};
    body['client_anonymous_id'] = this.clientAnonymousId;
    body['session_id'] = this.sessionId;
    const events: Array<Object> = new Array<Object>();
    for (let i: number = 0; i < batch.length; i++) {
      events.push(JSON.parse(batch[i].toJson()));
    }
    body['events'] = events;
    const envelope = await this.transport.post(this.endpoint, JSON.stringify(body), [], '');
    if (!envelope.isOk()) {
      throw FirebaseException.api('analytics-measurement', Json.firebaseErrorMessage(envelope.text));
    }
  }

  static newSessionId(): string {
    return `${Date.now()}-${Math.round(Math.random() * 0xffffff)}`;
  }
}

export type analyticsErrorSink = (error: FirebaseException) => void;