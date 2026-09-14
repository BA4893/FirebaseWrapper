import { http } from '@kit.NetworkKit';
import { FirebaseException } from './FirebaseError';

/**
 * A single HTTP header pair; kept as a class (no dynamic shapes).
 */
export class HeaderPair {
  name: string;
  value: string;

  constructor(name: string, value: string) {
    this.name = name;
    this.value = value;
  }
}

/**
 * Thinnest possible HTTP transport over the system HttpClient.
 *
 * Centralizes URL construction, JSON bodies, auth headers, status mapping,
 * error normalization, and body parsing — service modules stay pure domain code.
 */
export class HttpTransport {
  private client: http.HttpRequest;
  private connectTimeout: number;
  private readTimeout: number;

  constructor(connectTimeout: number, readTimeout: number) {
    this.client = http.createHttp();
    this.connectTimeout = connectTimeout;
    this.readTimeout = readTimeout;
  }

  get(url: string, headers: Array<HeaderPair>, auth: string): Promise<HttpEnvelope> {
    return this.send('GET', url, '', headers, auth);
  }

  post(url: string, body: string, headers: Array<HeaderPair>, auth: string): Promise<HttpEnvelope> {
    return this.send('POST', url, body, headers, auth);
  }

  patch(url: string, body: string, headers: Array<HeaderPair>, auth: string): Promise<HttpEnvelope> {
    return this.send('PATCH', url, body, headers, auth);
  }

  delete(url: string, headers: Array<HeaderPair>, auth: string): Promise<HttpEnvelope> {
    return this.send('DELETE', url, '', headers, auth);
  }

  put(url: string, body: string, headers: Array<HeaderPair>, auth: string): Promise<HttpEnvelope> {
    return this.send('PUT', url, body, headers, auth);
  }

  async send(method: string, url: string, body: string, extraHeaders: Array<HeaderPair>,
    auth: string): Promise<HttpEnvelope> {
    const options: http.HttpRequestOptions = this.buildOptions(method, body, extraHeaders, auth);
    let raw: http.HttpResponse;
    try {
      raw = await this.client.request(url, options);
    } catch (err) {
      if (err instanceof FirebaseException) {
        throw err;
      }
      throw FirebaseException.network(`${method} ${url} failed`, HttpTransport.asError(err));
    }
    return HttpEnvelope.from(raw);
  }

  /**
   * True SSE streaming GET. Opens a long-lived request with
   * `Accept: text/event-stream` and re-issues it on completion so callers get
   * a continuous event flow (≈55s server window, then re-arm).
   * Returns a handle; call `stop()` to end the stream.
   */
  stream(url: string, headers: Array<HeaderPair>, auth: string,
    onEvent: sseEventHandler, onError: sseErrorHandler): SseStream {
    const stream: SseStream = new SseStream(this, url, headers, auth, onEvent, onError);
    stream.start();
    return stream;
  }

  async requestOnce(url: string, headers: Array<HeaderPair>, auth: string): Promise<HttpEnvelope> {
    const merged: Array<HeaderPair> = new Array<HeaderPair>();
    merged.push(new HeaderPair('Accept', 'text/event-stream'));
    for (let i: number = 0; i < headers.length; i++) {
      merged.push(headers[i]);
    }
    return this.send('GET', url, '', merged, auth);
  }

  private buildOptions(method: string, body: string, extraHeaders: Array<HeaderPair>,
    auth: string): http.HttpRequestOptions {
    const pairs: Array<HeaderPair> = new Array<HeaderPair>();
    if (body.length > 0) {
      pairs.push(new HeaderPair('content-type', 'application/json'));
    }
    if (auth.length > 0) {
      pairs.push(new HeaderPair('authorization', auth));
    }
    for (let i: number = 0; i < extraHeaders.length; i++) {
      pairs.push(extraHeaders[i]);
    }
    const options: http.HttpRequestOptions = {
      method: HttpTransport.toRequestMethod(method),
      header: HttpTransport.pairsToObject(pairs),
      connectTimeout: this.connectTimeout,
      readTimeout: this.readTimeout,
      expectDataType: http.HttpDataType.STRING
    } as http.HttpRequestOptions;
    if (body.length > 0) {
      options.extraData = body;
    }
    return options;
  }

  private static toRequestMethod(method: string): http.RequestMethod {
    if (method === 'GET') {
      return http.RequestMethod.GET;
    }
    if (method === 'POST') {
      return http.RequestMethod.POST;
    }
    if (method === 'PATCH') {
      return http.RequestMethod.PATCH;
    }
    if (method === 'DELETE') {
      return http.RequestMethod.DELETE;
    }
    if (method === 'PUT') {
      return http.RequestMethod.PUT;
    }
    if (method === 'OPTIONS') {
      return http.RequestMethod.OPTIONS;
    }
    return http.RequestMethod.GET;
  }

  private static pairsToObject(src: Array<HeaderPair>): Object {
    const out: Object = {};
    for (let i: number = 0; i < src.length; i++) {
      out[src[i].name] = src[i].value;
    }
    return out;
  }

  private static asError(value: Object): Error | undefined {
    if (value instanceof Error) {
      return value as Error;
    }
    return undefined;
  }
}

/**
 * A normalized HTTP result.
 */
export class HttpEnvelope {
  status: number;
  /** Raw body when the response was text. */
  text: string;
  header: Object;

  constructor(status: number, text: string, header: Object) {
    this.status = status;
    this.text = text;
    this.header = header;
  }

  static from(resp: http.HttpResponse): HttpEnvelope {
    let text: string = '';
    if (resp.resultType === http.HttpDataType.STRING) {
      text = resp.result as string;
    } else {
      text = JSON.stringify(resp.result);
    }
    return new HttpEnvelope(resp.responseCode as number, text, resp.header);
  }

  isOk(): boolean {
    return this.status >= 200 && this.status < 300;
  }

  headerValue(name: string): string {
    const lower: string = name.toLowerCase();
    const keys: Array<string> = Object.keys(this.header);
    for (let i: number = 0; i < keys.length; i++) {
      if (keys[i].toLowerCase() === lower) {
        return this.header[keys[i]] as string;
      }
    }
    return '';
  }
}