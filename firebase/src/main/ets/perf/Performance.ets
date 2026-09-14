import { HttpTransport } from '../common/HttpTransport';
import { FirebaseException } from '../common/FirebaseError';
import { Json } from '../common/Json';

/** Performance Monitoring: traces + network spans (REST ingest). */
export class Performance {
  private transport: HttpTransport;
  private endpoint: string;
  private appId: string;
  private errorSink: perfErrorSink;

  constructor(transport: HttpTransport, endpoint: string, appId: string, errorSink: perfErrorSink) {
    this.transport = transport;
    this.endpoint = endpoint.length > 0 ? endpoint : 'https://firebaselogging-pa.googleapis.com/v1/perf';
    this.appId = appId;
    this.errorSink = errorSink;
  }

  trace(name: string): Trace {
    return new Trace(name);
  }

  async record(trace: Trace): Promise<void> {
    const body: Object = {};
    body['app_id'] = this.appId;
    body['trace'] = trace.toJsonObj();
    try {
      const e = await this.transport.post(this.endpoint, JSON.stringify(body), [], '');
      if (!e.isOk()) {
        throw FirebaseException.api('perf', Json.firebaseErrorMessage(e.text));
      }
    } catch (err) {
      if (this.errorSink !== undefined) {
        this.errorSink(err as FirebaseException);
      }
    }
  }
}

/** A single timed trace with attributes + metrics. */
export class Trace {
  name: string;
  private startedAt: number;
  private endedAt: number;
  private attrs: Array<TraceAttr>;
  private metrics: Array<TraceMetric>;

  constructor(name: string) {
    this.name = name;
    this.startedAt = Date.now() * 1000;
    this.endedAt = 0;
    this.attrs = new Array<TraceAttr>();
    this.metrics = new Array<TraceMetric>();
  }

  putAttribute(key: string, value: string): void {
    this.attrs.push(new TraceAttr(key, value));
  }

  putMetric(key: string, value: number): void {
    this.metrics.push(new TraceMetric(key, value));
  }

  stop(): void {
    this.endedAt = Date.now() * 1000;
  }

  durationMicros(): number {
    const end: number = this.endedAt > 0 ? this.endedAt : Date.now() * 1000;
    return end - this.startedAt;
  }

  toJsonObj(): Object {
    const o: Object = {};
    o['name'] = this.name;
    o['duration_micros'] = this.durationMicros();
    const a: Object = {};
    for (let i: number = 0; i < this.attrs.length; i++) {
      a[this.attrs[i].key] = this.attrs[i].value;
    }
    o['attributes'] = a;
    const m: Object = {};
    for (let i: number = 0; i < this.metrics.length; i++) {
      m[this.metrics[i].key] = this.metrics[i].value;
    }
    o['metrics'] = m;
    return o;
  }
}

class TraceAttr {
  key: string;
  value: string;

  constructor(key: string, value: string) {
    this.key = key;
    this.value = value;
  }
}

class TraceMetric {
  key: string;
  value: number;

  constructor(key: string, value: number) {
    this.key = key;
    this.value = value;
  }
}

export type perfErrorSink = (error: FirebaseException) => void;
