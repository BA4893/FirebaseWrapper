import { HttpTransport, HeaderPair } from '../common/HttpTransport';
import { SseStream } from '../common/SseStream';
import { KeyValueStore } from '../common/KeyValueStore';
import { FirebaseException, FirebaseErrorCode } from '../common/FirebaseError';
import { Json } from '../common/Json';
import { FirestoreCache, CacheSource } from './FirestoreCache';

/** Firestore REST v1 (PROTOCOLS §7). Bearer idToken + optional AppCheck. */
export class Firestore {
  private transport: HttpTransport;
  private projectId: string;
  private idToken: firestoreTokenProvider;
  private appCheck: firestoreTokenProvider | undefined;
  private cache: FirestoreCache | undefined;
  private flushing: boolean = false;

  constructor(transport: HttpTransport, projectId: string,
    idToken: firestoreTokenProvider, appCheck?: firestoreTokenProvider) {
    this.transport = transport;
    this.projectId = projectId;
    this.idToken = idToken;
    this.appCheck = appCheck;
  }

  /**
   * Attaches the ArkData-backed offline cache. After this call:
   * - `getDocument`/`cachedGet` are served through the cache,
   * - `listen()` snapshots update the cache,
   * - network-failed writes are queued and replayed by `flushWrites`.
   */
  attachCache(cache: FirestoreCache): void {
    this.cache = cache;
  }

  /** True once an offline cache is attached. */
  get hasCache(): boolean {
    return this.cache !== undefined;
  }

  /**
   * Server-atomic write: `POST …:commit` with a `writes[]` envelope
   * (PROTOCOLS §7). Firestore REST v1 applies every write all-or-nothing —
   * pass a `transaction` token (from `:beginTransaction`) for transactions, or
   * a single write for batched updates.
   */
  async commitWrites(writes: Array<Object>, transaction: string = ''): Promise<Object> {
    const body: Record<string, Object> = {};
    body['writes'] = writes;
    if (transaction.length > 0) {
      body['transaction'] = transaction;
    }
    const e = await this.transport.post(`${this.base()}:commit`,
      JSON.stringify(body), await this.extra(), await this.bearer());
    if (!e.isOk()) {
      throw FirebaseException.api('firestore.commit', Json.firebaseErrorMessage(e.text));
    }
    return Firestore.need(e.text, 'firestore.commit');
  }

  /**
   * Opens a server-side transaction; returns the opaque transaction token for
   * `commitWrites(writes, token)`. Firestore rolls the transaction back if the
   * token is never committed.
   */
  async beginTransaction(): Promise<string> {
    const rw: Record<string, Object> = {};
    const opts: Record<string, Object> = {};
    opts['readWrite'] = rw;
    const body: Record<string, Object> = {};
    body['options'] = opts;
    const e = await this.transport.post(`${this.base()}:beginTransaction`,
      JSON.stringify(body), await this.extra(), await this.bearer());
    if (!e.isOk()) {
      throw FirebaseException.api('firestore.beginTransaction', Json.firebaseErrorMessage(e.text));
    }
    const p: Object = Firestore.need(e.text, 'firestore.beginTransaction');
    return Json.string(p, 'transaction', '');
  }

  /** Read-through: cache first (CACHE source), then network (NETWORK source). */
  async getDocumentCached(path: string): Promise<Object> {
    if (this.cache === undefined) {
      return this.getDocument(path);
    }
    const snap: Object | undefined = this.cache.snapshot(path);
    if (snap !== undefined) {
      this.cache.emitEvent(path, snap, CacheSource.CACHE);
      return snap;
    }
    const fresh: Object = await this.getDocument(path);
    this.cache.put(path, JSON.stringify(fresh));
    this.cache.emitEvent(path, fresh, CacheSource.NETWORK);
    return fresh;
  }

  /** Replays queued offline writes through the attached cache's backing db. */
  async flushOfflineWrites(): Promise<number> {
    if (this.cache === undefined || this.flushing) {
      return 0;
    }
    this.flushing = true;
    try {
      return await this.cache.flushWrites(this);
    } finally {
      this.flushing = false;
    }
  }

  async getDocument(path: string): Promise<Object> {
    const e = await this.transport.get(this.docUrl(path), await this.extra(), await this.bearer());
    if (!e.isOk()) {
      throw FirebaseException.api('firestore.get', Json.firebaseErrorMessage(e.text));
    }
    return Firestore.need(e.text, 'firestore.get');
  }

  async createDocument(collection: string, docId: string, fields: Object): Promise<Object> {
    if (this.cache !== undefined) {
      try {
        return await this.remoteCreate(collection, docId, fields);
      } catch (err) {
        if (Firestore.isNetworkError(err)) {
          this.cache.queueWrite('set', `${this.trim(collection)}/${docId}`, JSON.stringify(fields));
          return {};
        }
        throw err;
      }
    }
    return this.remoteCreate(collection, docId, fields);
  }

  /** Remote-only create (also the offline-replay target via FirestoreLike). */
  async remoteCreate(collection: string, docId: string, fields: Object): Promise<Object> {
    const body: Object = {};
    body['fields'] = fields;
    let url: string = `${this.base()}/${this.trim(collection)}`;
    if (docId.length > 0) {
      url += `?documentId=${encodeURIComponent(docId)}`;
    }
    const e = await this.transport.post(url, JSON.stringify(body), await this.extra(), await this.bearer());
    if (!e.isOk()) {
      throw FirebaseException.api('firestore.create', Json.firebaseErrorMessage(e.text));
    }
    return Firestore.need(e.text, 'firestore.create');
  }

  async updateDocument(path: string, fields: Object, mask: Array<string>): Promise<Object> {
    if (this.cache !== undefined) {
      try {
        return await this.remoteUpdate(path, fields, mask);
      } catch (err) {
        if (Firestore.isNetworkError(err)) {
          this.cache.queueWrite('update', path, JSON.stringify(fields));
          return {};
        }
        throw err;
      }
    }
    return this.remoteUpdate(path, fields, mask);
  }

  /** Remote-only update (also the offline-replay target via FirestoreLike). */
  async remoteUpdate(path: string, fields: Object, mask: Array<string>): Promise<Object> {
    const body: Object = {};
    body['fields'] = fields;
    let url: string = this.docUrl(path);
    for (let i: number = 0; i < mask.length; i++) {
      url += `${i === 0 ? '?' : '&'}updateMask.fieldPaths=${encodeURIComponent(mask[i])}`;
    }
    const e = await this.transport.patch(url, JSON.stringify(body), await this.extra(), await this.bearer());
    if (!e.isOk()) {
      throw FirebaseException.api('firestore.update', Json.firebaseErrorMessage(e.text));
    }
    return Firestore.need(e.text, 'firestore.update');
  }

  async deleteDocument(path: string): Promise<void> {
    if (this.cache !== undefined) {
      try {
        await this.remoteDelete(path);
        return;
      } catch (err) {
        if (Firestore.isNetworkError(err)) {
          this.cache.queueWrite('remove', path, '{}');
          return;
        }
        throw err;
      }
    }
    await this.remoteDelete(path);
  }

  /** Remote-only delete (also the offline-replay target via FirestoreLike). */
  async remoteDelete(path: string): Promise<void> {
    const e = await this.transport.delete(this.docUrl(path), await this.extra(), await this.bearer());
    if (!e.isOk()) {
      throw FirebaseException.api('firestore.delete', Json.firebaseErrorMessage(e.text));
    }
  }

  async listDocuments(collection: string, pageSize: number): Promise<Object> {
    let url: string = `${this.base()}/${this.trim(collection)}`;
    if (pageSize > 0) {
      url += `?pageSize=${pageSize}`;
    }
    const e = await this.transport.get(url, await this.extra(), await this.bearer());
    if (!e.isOk()) {
      throw FirebaseException.api('firestore.list', Json.firebaseErrorMessage(e.text));
    }
    return Firestore.need(e.text, 'firestore.list');
  }

  async runQuery(query: Object): Promise<Array<Object>> {
    const body: Object = {};
    body['structuredQuery'] = query;
    const e = await this.transport.post(`${this.base()}:runQuery`,
      JSON.stringify(body), await this.extra(), await this.bearer());
    if (!e.isOk()) {
      throw FirebaseException.api('firestore.runQuery', Json.firebaseErrorMessage(e.text));
    }
    const p: Object | undefined = Json.tryParse(e.text);
    if (p === undefined) {
      throw FirebaseException.api('firestore.runQuery', 'malformed response');
    }
    return p as Array<Object>;
  }

  /** Realtime listener on a document via SSE stream; snapshots feed the cache. */
  listen(path: string, onSnap: firestoreWatcher, onError: firestoreErrorSink): SseStream {
    const url: string = `${this.docUrl(path)}?listen=true`;
    return this.transport.stream(url, [], '',
      (event: string, data: string) => {
        const parsed: Object | undefined = Json.tryParse(data);
        if (parsed !== undefined) {
          if (this.cache !== undefined) {
            this.cache.put(path, JSON.stringify(parsed));
            this.cache.emitEvent(path, parsed, CacheSource.NETWORK);
          }
          onSnap(parsed);
        }
      },
      (err: Error) => {
        onError(err);
      });
  }

  /** Offline cache: persists last reads through the shared store. */
  async cachedGet(path: string, store: KeyValueStore): Promise<Object> {
    try {
      const fresh: Object = await this.getDocument(path);
      store.set(`firestore.cache.${path}`, JSON.stringify(fresh));
      return fresh;
    } catch (err) {
      const raw: string = store.get(`firestore.cache.${path}`, '');
      if (raw.length > 0) {
        const back: Object | undefined = Json.tryParse(raw);
        if (back !== undefined) {
          return back;
        }
      }
      throw err;
    }
  }

  /** WriteBatch: sequential commit of queued writes. */
  batch(): WriteBatch {
    return new WriteBatch(this);
  }

  /**
   * Full document resource name for `:commit` write envelopes:
   * `projects/{p}/databases/(default)/documents/{path}`.
   */
  docName(path: string): string {
    return `${this.base()}/${this.trim(path)}`;
  }

  /**
   * Server-atomic transaction (PROTOCOLS §7): `:beginTransaction` → staged
   * reads and writes → ONE `:commit` bound to the transaction token. Firestore
   * applies all writes or none; concurrent writers abort the commit, which is
   * retried with a fresh token up to `maxRetries` times — the same contract as
   * the official SDKs' `runTransaction`.
   */
  async runTransaction(update: firestoreTx, maxRetries: number = 8): Promise<void> {
    let tries: number = 0;
    while (true) {
      const tx: FirestoreTransaction = new FirestoreTransaction(this);
      try {
        const token: string = await this.beginTransaction();
        tx.useTransaction(token);
        await update(tx);
        await tx.commit();
        return;
      } catch (err) {
        tries++;
        if (tries >= maxRetries) {
          throw err;
        }
      }
    }
  }

  /** Network failures are replayable offline; server rejections are not. */
  private static isNetworkError(err: Object): boolean {
    return err instanceof FirebaseException && (err as FirebaseException).code === FirebaseErrorCode.NETWORK;
  }

  private base(): string {
    return `https://firestore.googleapis.com/v1/projects/${this.projectId}/databases/(default)/documents`;
  }

  private docUrl(path: string): string {
    return `${this.base()}/${this.trim(path)}`;
  }

  private trim(path: string): string {
    let o: string = path;
    while (o.startsWith('/')) {
      o = o.substring(1);
    }
    while (o.endsWith('/')) {
      o = o.substring(0, o.length - 1);
    }
    return o;
  }

  private async bearer(): Promise<string> {
    const t: string = await this.idToken();
    return t.length > 0 ? `Bearer ${t}` : '';
  }

  private async extra(): Promise<Array<HeaderPair>> {
    const h: Array<HeaderPair> = new Array<HeaderPair>();
    if (this.appCheck !== undefined) {
      try {
        const t: string = await this.appCheck();
        if (t.length > 0) {
          h.push(new HeaderPair('X-Firebase-AppCheck', t));
        }
      } catch (err) {
      }
    }
    return h;
  }

  private static need(text: string, op: string): Object {
    const p: Object | undefined = Json.tryParse(text);
    if (p === undefined) {
      throw FirebaseException.api(op, 'malformed response');
    }
    return p;
  }

  static parentOf(path: string): string {
    const i: number = path.lastIndexOf('/');
    return i > 0 ? path.substring(0, i) : path;
  }

  static docIdOf(path: string): string {
    const i: number = path.lastIndexOf('/');
    return i >= 0 ? path.substring(i + 1) : path;
  }
}

export type firestoreTokenProvider = () => Promise<string>;
export type firestoreWatcher = (snapshot: Object) => void;
export type firestoreErrorSink = (error: Error) => void;

/** One staged write, rendered to a Firestore REST v1 `:commit` write envelope. */
export class WriteOp {
  kind: string;
  path: string;
  fields: Object;
  mask: Array<string>;

  constructor(kind: string, path: string, fields: Object, mask: Array<string>) {
    this.kind = kind;
    this.path = path;
    this.fields = fields;
    this.mask = mask;
  }

  /**
   * Wire envelope per https://cloud.google.com/firestore/docs/reference/rest/v1/Write:
   * update/updateMask/delete carry the full `projects/.../documents/{path}` name.
   */
  toEnvelope(db: Firestore): Object {
    const name: string = db.docName(this.path);
    const env: Record<string, Object> = {};
    if (this.kind === 'set' || this.kind === 'update') {
      const upd: Record<string, Object> = {};
      upd['name'] = name;
      upd['fields'] = this.fields;
      env['update'] = upd;
      if (this.kind === 'update') {
        const m: Record<string, Object> = {};
        const paths: Array<string> = new Array<string>();
        for (let i: number = 0; i < this.mask.length; i++) {
          paths.push(this.mask[i]);
        }
        m['fieldPaths'] = paths;
        env['updateMask'] = m;
      }
    } else {
      env['delete'] = name;
    }
    return env;
  }
}

/** Atomic write batch (set/update/delete) — one server-side `:commit`. */
export class WriteBatch {
  private db: Firestore;
  private ops: Array<WriteOp>;

  constructor(db: Firestore) {
    this.db = db;
    this.ops = new Array<WriteOp>();
  }

  set(path: string, fields: Object): WriteBatch {
    this.ops.push(new WriteOp('set', path, fields, new Array<string>()));
    return this;
  }

  update(path: string, fields: Object): WriteBatch {
    return this.updateMasked(path, fields, new Array<string>());
  }

  /** `update` restricted to `fieldPaths`; omitted fields are left untouched. */
  updateMasked(path: string, fields: Object, mask: Array<string>): WriteBatch {
    this.ops.push(new WriteOp('update', path, fields, mask));
    return this;
  }

  remove(path: string): WriteBatch {
    const none: Record<string, Object> = {};
    this.ops.push(new WriteOp('remove', path, none, new Array<string>()));
    return this;
  }

  /** Writes pending since the last commit — offline replay targets. */
  pendingOps(): Array<WriteOp> {
    return this.ops;
  }

  /**
   * ONE `POST …documents:commit` — Firestore applies every write all-or-nothing.
   * No longer a sequential loop of independent REST calls.
   */
  async commit(): Promise<void> {
    if (this.ops.length === 0) {
      return;
    }
    const writes: Array<Object> = new Array<Object>();
    for (let i: number = 0; i < this.ops.length; i++) {
      writes.push(this.ops[i].toEnvelope(this.db));
    }
    await this.db.commitWrites(writes);
    this.ops.splice(0, this.ops.length);
  }
}

/** Transaction: begin → staged reads + writes → ONE atomic commit, with retry. */
export class FirestoreTransaction {
  private db: Firestore;
  private writes: Array<WriteOp>;
  private transaction: string;

  constructor(db: Firestore) {
    this.db = db;
    this.writes = new Array<WriteOp>();
    this.transaction = '';
  }

  async get(path: string): Promise<Object> {
    return this.db.getDocument(path);
  }

  set(path: string, fields: Object): void {
    this.writes.push(new WriteOp('set', path, fields, new Array<string>()));
  }

  update(path: string, fields: Object): void {
    this.writes.push(new WriteOp('update', path, fields, new Array<string>()));
  }

  /** Masked update — only `fieldPaths` are applied server-side. */
  updateMasked(path: string, fields: Object, mask: Array<string>): void {
    this.writes.push(new WriteOp('update', path, fields, mask));
  }

  remove(path: string): void {
    const none: Record<string, Object> = {};
    this.writes.push(new WriteOp('remove', path, none, new Array<string>()));
  }

  /** Writes pending since the last begin/commit — offline replay targets. */
  pendingOps(): Array<WriteOp> {
    return this.writes;
  }

  /** Binds the commit to a server-side transaction token from `beginTransaction`. */
  useTransaction(token: string): void {
    this.transaction = token;
  }

  transactionToken(): string {
    return this.transaction;
  }

  /**
   * Atomic commit: staged writes ride the bound `:beginTransaction` token, so
   * Firestore either applies every write or none of them.
   */
  async commit(): Promise<void> {
    if (this.writes.length === 0) {
      return;
    }
    const writes: Array<Object> = new Array<Object>();
    for (let i: number = 0; i < this.writes.length; i++) {
      writes.push(this.writes[i].toEnvelope(this.db));
    }
    await this.db.commitWrites(writes, this.transaction);
    this.writes.splice(0, this.writes.length);
  }
}

export type firestoreTx = (tx: FirestoreTransaction) => Promise<void>;
