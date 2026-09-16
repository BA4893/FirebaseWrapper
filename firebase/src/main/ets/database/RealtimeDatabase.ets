import { HttpTransport, HeaderPair } from '../common/HttpTransport';
import { SseStream } from '../common/SseStream';
import { FirebaseException, FirebaseErrorCode } from '../common/FirebaseError';
import { Json } from '../common/Json';

/** RTDB REST (PROTOCOLS §8). `?auth=<idToken>`, SSE long-poll watcher. */
export class RealtimeDatabase {
  private transport: HttpTransport;
  private dbUrl: string;
  private idToken: rtdbTokenProvider;
  private watchTimer: number;

  constructor(transport: HttpTransport, dbUrl: string, idToken: rtdbTokenProvider) {
    this.transport = transport;
    this.dbUrl = RealtimeDatabase.norm(dbUrl);
    this.idToken = idToken;
    this.watchTimer = 0;
  }

  async get(path: string): Promise<Object | undefined> {
    const e = await this.transport.get(this.url(path, await this.tokenSuffix()), [], '');
    if (!e.isOk()) {
      throw FirebaseException.api('rtdb.get', Json.firebaseErrorMessage(e.text));
    }
    if (e.text === 'null' || e.text.length === 0) {
      return undefined;
    }
    return Json.tryParse(e.text);
  }

  async set(path: string, value: Object): Promise<void> {
    const e = await this.transport.put(this.url(path, await this.tokenSuffix()), JSON.stringify(value), [], '');
    if (!e.isOk()) {
      throw FirebaseException.api('rtdb.set', Json.firebaseErrorMessage(e.text));
    }
  }

  async push(path: string, value: Object): Promise<string> {
    const e = await this.transport.post(this.url(path, await this.tokenSuffix()), JSON.stringify(value), [], '');
    if (!e.isOk()) {
      throw FirebaseException.api('rtdb.push', Json.firebaseErrorMessage(e.text));
    }
    const p: Object | undefined = Json.tryParse(e.text);
    if (p === undefined) {
      throw FirebaseException.api('rtdb.push', 'malformed response');
    }
    return Json.string(p, 'name', '');
  }

  async update(path: string, value: Object): Promise<void> {
    const e = await this.transport.patch(this.url(path, await this.tokenSuffix()), JSON.stringify(value), [], '');
    if (!e.isOk()) {
      throw FirebaseException.api('rtdb.update', Json.firebaseErrorMessage(e.text));
    }
  }

  async remove(path: string): Promise<void> {
    const e = await this.transport.delete(this.url(path, await this.tokenSuffix()), [], '');
    if (!e.isOk()) {
      throw FirebaseException.api('rtdb.remove', Json.firebaseErrorMessage(e.text));
    }
  }

  /** Realtime listener: attaches via SSE `Accept:text/event-stream`. */
  onValue(path: string, onValue: rtdbWatcher, onError: rtdbErrorSink): SseStream {
    const url: string = this.streamUrl(path);
    const h: Array<HeaderPair> = new Array<HeaderPair>();
    return this.transport.stream(url, h, '',
      (event: string, data: string) => {
        if (event === 'put' || event === 'patch' || event === 'message') {
          const v: Object | undefined = RealtimeDatabase.sseValue(data);
          onValue(v);
        } else if (event === 'cancel' || event === 'auth_revoked') {
          onError(new FirebaseException(FirebaseErrorCode.AUTH, `rtdb stream: ${event}`));
        }
      },
      (err: Error) => {
        onError(err);
      });
  }

  /** Legacy polling watcher (55s re-arm) for networks that break SSE. */
  watch(path: string, onValue: rtdbWatcher, onError: rtdbErrorSink): void {
    this.stopWatching();
    const tick = (): void => {
      this.pollOnce(path, onValue).catch((err: Error) => {
        onError(err);
      });
      this.watchTimer = setTimeout(tick, 55000);
    };
    tick();
  }

  stopWatching(): void {
    if (this.watchTimer !== 0) {
      clearTimeout(this.watchTimer);
      this.watchTimer = 0;
    }
  }

  private async pollOnce(path: string, onValue: rtdbWatcher): Promise<void> {
    const h: Array<HeaderPair> = new Array<HeaderPair>();
    h.push(new HeaderPair('Accept', 'text/event-stream'));
    const e = await this.transport.get(this.url(path, await this.tokenSuffix()), h, '');
    if (!e.isOk()) {
      throw FirebaseException.api('rtdb.watch', Json.firebaseErrorMessage(e.text));
    }
    const v: Object | undefined = RealtimeDatabase.sseValue(e.text);
    if (v !== undefined) {
      onValue(v);
    }
  }

  private url(path: string, extra: string): string {
    let p: string = path;
    while (p.startsWith('/')) {
      p = p.substring(1);
    }
    let u: string = `${this.dbUrl}/${p}.json`;
    u += extra.length > 0 ? extra : '';
    return u;
  }

  private streamUrl(path: string): string {
    let p: string = path;
    while (p.startsWith('/')) {
      p = p.substring(1);
    }
    return `${this.dbUrl}/${p}.json`;
  }

  /**
   * TRUE compare-and-set transaction (PROTOCOLS §8) via the documented RTDB
   * ETag mechanism: `GET` with `X-Firebase-ETag: true` returns the node's
   * current value AND its ETag; `PUT` with `If-Match: <etag>` succeeds only if
   * the node is unchanged — otherwise RTDB replies `412 Precondition Failed`
   * and the read-compute-write loop retries (up to `maxRetries`), so concurrent
   * writers can no longer silently interleave.
   *
   * Returning `undefined` from `update` deletes the node (If-Match DELETE is
   * not used because RTDB's documented conditional-delete support is via PUT
   * with null). Note: ETags are per-node — a transaction spanning multiple
   * locations is still read-modify-write per node (documented limitation).
   */
  async transaction(path: string, update: rtdbTransaction,
    maxRetries: number = 8): Promise<Object | undefined> {
    let tries: number = 0;
    while (true) {
      const headers: Array<HeaderPair> = new Array<HeaderPair>();
      headers.push(new HeaderPair('X-Firebase-ETag', 'true'));
      const read = await this.transport.get(this.url(path, await this.tokenSuffix()), headers, '');
      if (!read.isOk()) {
        throw FirebaseException.api('rtdb.tx.read', Json.firebaseErrorMessage(read.text));
      }
      const etag: string = read.headerValue('ETag');
      const current: Object | undefined = (read.text === 'null' || read.text.length === 0)
        ? undefined
        : Json.tryParse(read.text);
      const next: Object | undefined = update(current);
      const putHeaders: Array<HeaderPair> = new Array<HeaderPair>();
      if (etag.length > 0) {
        putHeaders.push(new HeaderPair('If-Match', etag));
      }
      const body: string = next === undefined ? 'null' : JSON.stringify(next);
      const put = await this.transport.put(this.url(path, await this.tokenSuffix()), body, putHeaders, '');
      if (put.isOk()) {
        return next;
      }
      if (put.status !== 412) {
        throw FirebaseException.api('rtdb.tx.commit', Json.firebaseErrorMessage(put.text));
      }
      tries++;
      if (tries >= maxRetries) {
        throw FirebaseException.api('rtdb.tx.conflict', 'too many concurrent modifications');
      }
    }
  }

  /** onDisconnect: queues a best-effort proxy-held write; see docs. */
  async onDisconnectSet(path: string, value: Object): Promise<void> {
    await this.proxyQueue('set', path, value);
  }

  async onDisconnectRemove(path: string): Promise<void> {
    await this.proxyQueue('remove', path, {});
  }

  private proxyBase: string = '';

  /** Configures the proxy that holds onDisconnect ops on its socket. */
  setProxy(baseUrl: string): void {
    this.proxyBase = baseUrl;
  }

  private async proxyQueue(op: string, path: string, value: Object): Promise<void> {
    if (this.proxyBase.length > 0) {
      const body: Object = {};
      body['op'] = op;
      body['path'] = path;
      body['value'] = value;
      const e = await this.transport.post(`${this.proxyBase}/v1/rtdb:onDisconnect`,
        JSON.stringify(body), [], '');
      if (!e.isOk()) {
        throw FirebaseException.api('rtdb.onDisconnect', Json.firebaseErrorMessage(e.text));
      }
      return;
    }
    if (op === 'remove') {
      await this.remove(path);
    } else {
      await this.set(path, value);
    }
  }

  async tokenSuffix(): Promise<string> {
    const t: string = await this.idToken();
    return t.length > 0 ? `?auth=${encodeURIComponent(t)}` : '';
  }

  static norm(dbUrl: string): string {
    let o: string = dbUrl;
    while (o.endsWith('/')) {
      o = o.substring(0, o.length - 1);
    }
    if (o.startsWith('https://') || o.startsWith('http://')) {
      return o;
    }
    if (o.length === 0) {
      return o;
    }
    return `https://${o}.firebaseio.com`;
  }

  static sseValue(text: string): Object | undefined {
    const lines: Array<string> = text.split('\n');
    let data: string = '';
    for (let i: number = 0; i < lines.length; i++) {
      if (lines[i].startsWith('data:')) {
        data += lines[i].substring(5);
      }
    }
    const raw: string = data.length > 0 ? data : text;
    if (raw === 'null' || raw.length === 0) {
      return undefined;
    }
    return Json.tryParse(raw);
  }
}

export type rtdbTokenProvider = () => Promise<string>;
export type rtdbWatcher = (value: Object | undefined) => void;
export type rtdbErrorSink = (error: Error) => void;
export type rtdbTransaction = (current: Object | undefined) => Object | undefined;
