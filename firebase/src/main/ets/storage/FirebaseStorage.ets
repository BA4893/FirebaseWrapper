import { HttpTransport, HeaderPair } from '../common/HttpTransport';
import { FirebaseException } from '../common/FirebaseError';
import { Json } from '../common/Json';
import { Codec } from '../common/Codec';

/** Cloud Storage via JSON API (upload/download/list/delete + metadata). */
export class FirebaseStorage {
  private transport: HttpTransport;
  private bucket: string;
  private idToken: storageTokenProvider;

  constructor(transport: HttpTransport, bucket: string, idToken: storageTokenProvider) {
    this.transport = transport;
    this.bucket = bucket;
    this.idToken = idToken;
  }

  async metadata(path: string): Promise<Object> {
    const e = await this.transport.get(this.objUrl(path), [], await this.bearer());
    if (!e.isOk()) {
      throw FirebaseException.api('storage.meta', Json.firebaseErrorMessage(e.text));
    }
    const p: Object | undefined = Json.tryParse(e.text);
    if (p === undefined) {
      throw FirebaseException.api('storage.meta', 'malformed response');
    }
    return p;
  }

  async upload(path: string, contentType: string, dataB64: string): Promise<Object> {
    const url: string = `https://firebasestorage.googleapis.com/v0/b/${this.bucket}/o?uploadType=media&name=${encodeURIComponent(path)}`;
    const h = await this.extra(contentType);
    const e = await this.transport.post(url, dataB64, h, await this.bearer());
    if (!e.isOk()) {
      throw FirebaseException.api('storage.upload', Json.firebaseErrorMessage(e.text));
    }
    const p: Object | undefined = Json.tryParse(e.text);
    if (p === undefined) {
      throw FirebaseException.api('storage.upload', 'malformed response');
    }
    return p;
  }

  /**
   * Resumable upload (GCS JSON API session, iOS-parity `PUT` chunking).
   * Step 1 of 2: open the session. Returns the session URI for
   * {@link uploadChunk}; persist it to survive process death.
   */
  async resumableSession(path: string, contentType: string, totalBytes: number): Promise<string> {
    const url: string = `https://firebasestorage.googleapis.com/v0/b/${this.bucket}/o?uploadType=resumable&name=${encodeURIComponent(path)}`;
    const h: Array<HeaderPair> = [
      new HeaderPair('Content-Type', 'application/json; charset=UTF-8'),
      new HeaderPair('X-Upload-Content-Type', contentType),
      new HeaderPair('X-Upload-Content-Length', `${totalBytes}`),
    ];
    const body: Object = {};
    body['name'] = path;
    body['contentType'] = contentType;
    const e = await this.transport.post(url, JSON.stringify(body), h, await this.bearer());
    if (!e.isOk()) {
      throw FirebaseException.api('storage.resumable.start', Json.firebaseErrorMessage(e.text));
    }
    const sessionUri: string = e.headerValue('Location');
    if (sessionUri.length === 0) {
      throw FirebaseException.api('storage.resumable.start', 'no session URI returned');
    }
    return sessionUri;
  }

  /**
   * Resumable upload step 2: PUT one chunk at `offset` onto the session URI.
   * Response 308 = keep going (returns next offset), 200 = complete.
   */
  async uploadChunk(sessionUri: string, offset: number, contentType: string,
    chunkB64: string): Promise<ResumableChunkState> {
    const h: Array<HeaderPair> = [
      new HeaderPair('Content-Type', contentType),
      new HeaderPair('Content-Range', `bytes ${offset}-${offset + Codec.base64UrlDecode(chunkB64).length - 1}/*`),
    ];
    const e = await this.transport.put(sessionUri, chunkB64, h, await this.bearer());
    if (e.status === 308) {
      return new ResumableChunkState(false, offset + Codec.base64UrlDecode(chunkB64).length);
    }
    if (!e.isOk()) {
      throw FirebaseException.api('storage.resumable.chunk', Json.firebaseErrorMessage(e.text));
    }
    return new ResumableChunkState(true, 0);
  }

  /** Cancels a resumable session (iOS-parity `deleteUploadableObject`). */
  async cancelSession(sessionUri: string): Promise<void> {
    const e = await this.transport.delete(sessionUri, [], await this.bearer());
    if (!e.isOk() && e.status !== 499) {
      throw FirebaseException.api('storage.resumable.cancel', Json.firebaseErrorMessage(e.text));
    }
  }

  async downloadUrl(path: string): Promise<string> {
    const e = await this.transport.get(this.objUrl(path), [], await this.bearer());
    if (!e.isOk()) {
      throw FirebaseException.api('storage.url', Json.firebaseErrorMessage(e.text));
    }
    return `${this.objUrl(path)}?alt=media`;
  }

  async list(prefix: string): Promise<Object> {
    const e = await this.transport.get(
      `https://firebasestorage.googleapis.com/v0/b/${this.bucket}/o?prefix=${encodeURIComponent(prefix)}`,
      [], await this.bearer());
    if (!e.isOk()) {
      throw FirebaseException.api('storage.list', Json.firebaseErrorMessage(e.text));
    }
    const p: Object | undefined = Json.tryParse(e.text);
    if (p === undefined) {
      throw FirebaseException.api('storage.list', 'malformed response');
    }
    return p;
  }

  async remove(path: string): Promise<void> {
    const e = await this.transport.delete(this.objUrl(path), [], await this.bearer());
    if (!e.isOk()) {
      throw FirebaseException.api('storage.delete', Json.firebaseErrorMessage(e.text));
    }
  }

  private objUrl(path: string): string {
    return `https://firebasestorage.googleapis.com/v0/b/${this.bucket}/o/${encodeURIComponent(path)}`;
  }

  private async bearer(): Promise<string> {
    const t: string = await this.idToken();
    return t.length > 0 ? `Bearer ${t}` : '';
  }

  private async extra(contentType: string): Promise<Array<HeaderPair>> {
    const h = new Array<HeaderPair>();
    h.push(new HeaderPair('Content-Type', contentType));
    return h;
  }
}

export type storageTokenProvider = () => Promise<string>;

/**
 * Progress state of one resumable chunk (`308 Resume Incomplete` → done=false
 * with the next byte offset; `2xx` → done=true).
 */
export class ResumableChunkState {
  done: boolean;
  nextOffset: number;

  constructor(done: boolean, nextOffset: number) {
    this.done = done;
    this.nextOffset = nextOffset;
  }
}
