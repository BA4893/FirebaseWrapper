import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { Json } from '../common/Json';

/**
 * Firestore offline cache backed by **ArkData** (`@kit.ArkData` preferences).
 *
 * Role-parity with the iOS SDK's local persistence: last-read documents and
 * queued offline writes survive process death. Storage is the app-private
 * preferences file identified by `dbName`; when no ArkData backend is
 * available (unit-test sandbox) the cache degrades to an in-memory map.
 *
 * Fed automatically by `Firestore.attachCache(...)`:
 * - every successful read stores its document,
 * - every `listen()` snapshot updates the cached document,
 * - writes that fail with a NETWORK error are queued locally and replayed by
 *   {@link flushWrites} when connectivity returns (iOS "offline writes").
 */
export class FirestoreCache {
  private context: common.Context;
  private dbName: string;
  private prefs: preferences.Preferences | undefined;
  private mem: Map<string, string>;
  private pending: Array<PendingWrite>;
  private loaded: boolean;
  private listeners: Array<cacheListener>;

  constructor(context: common.Context, dbName: string = 'firebase_firestore_cache') {
    this.context = context;
    this.dbName = dbName;
    this.prefs = undefined;
    this.mem = new Map<string, string>();
    this.pending = new Array<PendingWrite>();
    this.loaded = false;
    this.listeners = new Array<cacheListener>();
  }

  /** Opens the ArkData backing store. Safe to call repeatedly. */
  async open(): Promise<void> {
    if (this.loaded) {
      return;
    }
    this.loaded = true;
    try {
      const opts: preferences.Options = { name: this.dbName };
      this.prefs = preferences.getPreferencesSync(this.context, opts);
      await this.prefs.flush();
    } catch (err) {
      // No ArkData backend here (tests / previewer): memory-only mode.
      this.prefs = undefined;
    }
    this.loadPending();
  }

  /** Stores one document (JSON text of the Firestore `Document` object). */
  put(path: string, docJson: string): void {
    const key: string = FirestoreCache.docKey(path);
    this.mem.set(key, docJson);
    if (this.prefs !== undefined) {
      try {
        this.prefs.putSync(key, docJson);
        this.prefs.flush().catch(() => {
        });
      } catch (err) {
      }
    }
  }

  /** Returns the cached JSON document, or '' on a cache miss. */
  get(path: string): string {
    const key: string = FirestoreCache.docKey(path);
    if (this.prefs !== undefined) {
      try {
        const v: preferences.ValueType = this.prefs.getSync(key, '');
        if (typeof v === 'string') {
          const s: string = v as string;
          if (s.length > 0) {
            return s;
          }
        }
      } catch (err) {
      }
    }
    return this.mem.hasKey(key) ? this.mem.get(key) as string : '';
  }

  /** Pure cache read (no network): parsed document or undefined. */
  snapshot(path: string): Object | undefined {
    const raw: string = this.get(path);
    if (raw.length === 0) {
      return undefined;
    }
    return Json.tryParse(raw);
  }

  /** Queues an offline write (kind: set | update | remove). */
  queueWrite(kind: string, path: string, fieldsJson: string, maskJson: string = '[]'): void {
    this.pending.push(new PendingWrite(kind, path, fieldsJson, maskJson));
    this.persistPending();
  }

  /** Number of queued offline writes. */
  get pendingCount(): number {
    return this.pending.length;
  }

  /**
   * Replays queued writes against the live Firestore. Stops at the first
   * persistent failure; successful entries are removed.
   */
  async flushWrites(db: FirestoreLike): Promise<number> {
    let flushed: number = 0;
    while (this.pending.length > 0) {
      const w: PendingWrite = this.pending[0];
      try {
        if (w.kind === 'set') {
          const fields: Object | undefined = Json.tryParse(w.fieldsJson);
          await db.remoteCreate(FirestoreLike.parentOf(w.path), FirestoreLike.docIdOf(w.path),
            fields !== undefined ? fields : {});
        } else if (w.kind === 'update') {
          const fields2: Object | undefined = Json.tryParse(w.fieldsJson);
          const maskRaw: Object | undefined = Json.tryParse(w.maskJson);
          const mask: Array<string> = maskRaw !== undefined ? maskRaw as Array<string> : new Array<string>();
          await db.remoteUpdate(w.path, fields2 !== undefined ? fields2 : {}, mask);
        } else {
          await db.remoteDelete(w.path);
        }
      } catch (err) {
        break;
      }
      this.pending.shift();
      flushed++;
      this.persistPending();
    }
    return flushed;
  }

  /** Clears all cached documents and pending writes. */
  clear(): void {
    this.mem.clear();
    this.pending = new Array<PendingWrite>();
    if (this.prefs !== undefined) {
      try {
        this.prefs.clearSync();
        this.prefs.flush().catch(() => {
        });
      } catch (err) {
      }
    }
  }

  /** Subscribes to cache events (firestore:cache). */
  onCacheEvent(handler: cacheListener): void {
    this.listeners.push(handler);
  }

  emitEvent(path: string, doc: Object, source: CacheSource): void {
    for (let i: number = 0; i < this.listeners.length; i++) {
      this.listeners[i](path, doc, source);
    }
  }

  private loadPending(): void {
    const raw: string = this.readString('firestore.pending');
    if (raw.length === 0) {
      return;
    }
    const parsed: Object | undefined = Json.tryParse(raw);
    if (parsed === undefined) {
      return;
    }
    const list: Array<Object> = parsed as Array<Object>;
    for (let i: number = 0; i < list.length; i++) {
      const o: Object = list[i];
      this.pending.push(new PendingWrite(Json.string(o, 'kind', 'set'),
        Json.string(o, 'path', ''), Json.string(o, 'fields', '{}'), Json.string(o, 'mask', '[]')));
    }
  }

  private persistPending(): void {
    const json: string = JSON.stringify(viaList(this.pending));
    this.mem.set('firestore.pending', json);
    if (this.prefs !== undefined) {
      try {
        this.prefs.putSync('firestore.pending', json);
        this.prefs.flush().catch(() => {
        });
      } catch (err) {
      }
    }
  }

  private readString(key: string): string {
    if (this.prefs !== undefined) {
      try {
        const v: preferences.ValueType = this.prefs.getSync(key, '');
        if (typeof v === 'string') {
          return v as string;
        }
      } catch (err) {
      }
    }
    return this.mem.hasKey(key) ? this.mem.get(key) as string : '';
  }

  private static docKey(path: string): string {
    return `firestore.doc.${path}`;
  }
}

function viaList(pending: Array<PendingWrite>): Array<Object> {
  const arr: Array<Object> = new Array<Object>();
  for (let i: number = 0; i < pending.length; i++) {
    const o: Object = {};
    o['kind'] = pending[i].kind;
    o['path'] = pending[i].path;
    o['fields'] = pending[i].fieldsJson;
    o['mask'] = pending[i].maskJson;
    arr.push(o);
  }
  return arr;
}

export enum CacheSource {
  NETWORK = 0,
  CACHE = 1
}

export const FIRESTORE_CACHE_EVENT: string = 'firestore:cache';

export type cacheListener = (path: string, doc: Object, source: CacheSource) => void;

/** Minimal remote-only surface of Firestore needed to replay offline writes. */
export interface FirestoreLike {
  remoteCreate(collection: string, docId: string, fields: Object): Promise<Object>;
  remoteUpdate(path: string, fields: Object, mask: Array<string>): Promise<Object>;
  remoteDelete(path: string): Promise<void>;
}

class PendingWrite {
  kind: string;
  path: string;
  fieldsJson: string;
  maskJson: string;

  constructor(kind: string, path: string, fieldsJson: string, maskJson: string) {
    this.kind = kind;
    this.path = path;
    this.fieldsJson = fieldsJson;
    this.maskJson = maskJson;
  }
}

/** Static path helpers mirrored from Firestore. */
export namespace FirestoreLike {
  export function parentOf(path: string): string {
    const i: number = path.lastIndexOf('/');
    return i > 0 ? path.substring(0, i) : path;
  }

  export function docIdOf(path: string): string {
    const i: number = path.lastIndexOf('/');
    return i >= 0 ? path.substring(i + 1) : path;
  }
}
