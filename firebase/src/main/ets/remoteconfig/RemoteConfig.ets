import { HttpTransport, HeaderPair } from '../common/HttpTransport';
import { FirebaseException, FirebaseErrorCode } from '../common/FirebaseError';
import { Json } from '../common/Json';
import { KeyValueStore } from '../common/KeyValueStore';
import { RemoteConfigOptions } from '../common/FirebaseConfig';

const REMOTE_CONFIG_BASE: string = 'https://firebaseremoteconfig.googleapis.com/v1/projects';

/**
 * One Remote Config entry as delivered by the `configs:get` pipe.
 */
export class RemoteConfigEntry {
  key: string;
  /** JSON-serialized value. */
  value: string;
  updateTime: number;
  etag: string;

  constructor(key: string, value: string, updateTime: number, etag: string) {
    this.key = key;
    this.value = value;
    this.updateTime = updateTime;
    this.etag = etag;
  }
}

/**
 * Firebase Remote Config client with the three-layer cache model:
 *  - DefaultCache: compile-time defaults,
 *  - ActiveCache:   in-memory merged view (active over defaults),
 *  - FetchedCache:  last server payload, persisted through a KeyValueStore.
 *
 * ETag handling: the server etag is sent as `If-None-Match`; a `304` brings the
 * FetchedCache back into the ActiveCache without a network re-parse.
 */
export class RemoteConfig {
  private transport: HttpTransport;
  private projectId: string;
  private options: RemoteConfigOptions;
  private store: KeyValueStore;
  private tokenProvider: tokenProvider;

  private defaults: Map<string, string>;
  private active: Map<string, string>;
  private fetchedRaw: string;
  private etag: string;
  private lastFetchAt: number;

  constructor(transport: HttpTransport, projectId: string, options: RemoteConfigOptions,
    store: KeyValueStore, tokenProvider: tokenProvider) {
    this.transport = transport;
    this.projectId = projectId;
    this.options = options;
    this.store = store;
    this.tokenProvider = tokenProvider;
    this.defaults = new Map<string, string>();
    this.active = new Map<string, string>();
    this.fetchedRaw = '';
    this.etag = '';
    this.lastFetchAt = 0;

    // Hydrate the FetchedCache layer from disk.
    this.fetchedRaw = store.get(this.cacheKey('fetched'), '');
    this.etag = store.get(this.cacheKey('etag'), '');
    if (this.fetchedRaw.length > 0) {
      this.commitFetched(this.fetchedRaw);
    }
  }
  /** Seeds the DefaultCache layer. */
  setDefaults(entries: Array<ConfigDefault>): void {
    for (let i: number = 0; i < entries.length; i++) {
      this.defaults.set(entries[i].key, entries[i].value);
    }
  }

  /**
   * Fetches from the network (honoring the ETag). Returns true when a new
   * configuration was committed.
   */
  async fetch(): Promise<boolean> {
    const now: number = Date.now();
    const token: string = await this.tokenProvider();
    const suffix: string = this.options.compute ? 'configs:get:compute' : 'configs:get';
    const url: string = `${REMOTE_CONFIG_BASE}/${this.projectId}/namespaces/${this.options.namespace}/${suffix}`;

    const headers: Array<HeaderPair> = new Array<HeaderPair>();
    if (this.etag.length > 0) {
      headers.push(new HeaderPair('If-None-Match', this.etag));
    }

    const envelope = await this.transport.post(url, '{}', headers, `Bearer ${token}`);
    if (envelope.status === 200) {
      this.lastFetchAt = now;
      this.etag = envelope.headerValue('ETag');
      if (this.etag.length === 0) {
        // Some fixtures carry the etag inside the body instead.
        const parsedBody: Object | undefined = Json.tryParse(envelope.text);
        if (parsedBody !== undefined) {
          this.etag = Json.string(parsedBody, 'etag', '');
        }
      }
      this.fetchedRaw = envelope.text;
      this.store.set(this.cacheKey('fetched'), this.fetchedRaw);
      this.store.set(this.cacheKey('etag'), this.etag);
      this.commitFetched(this.fetchedRaw);
      return true;
    }
    if (envelope.status === 304) {
      this.lastFetchAt = now;
      if (this.fetchedRaw.length > 0) {
        this.commitFetched(this.fetchedRaw);
      }
      return false;
    }
    throw FirebaseException.api('remote-config', Json.firebaseErrorMessage(envelope.text));
  }

  /**
   * Guards {@link fetch} against hammering: returns false when the min interval
   * has not elapsed (callers then fall back to the cached view).
   */
  async fetchIfStale(): Promise<boolean> {
    const now: number = Date.now();
    if (this.options.minFetchIntervalMs > 0 && now - this.lastFetchAt < this.options.minFetchIntervalMs) {
      return false;
    }
    return this.fetch();
  }

  // ---- typed getters (Active → Default) ----

  getString(key: string, fallback: string): string {
    const raw: string = this.raw(key);
    if (raw.length === 0) {
      return fallback;
    }
    return raw;
  }

  getNumber(key: string, fallback: number): number {
    const raw: string = this.raw(key);
    if (raw.length === 0) {
      return fallback;
    }
    const n: number = Number.parseInt(raw);
    if (Number.isNaN(n)) {
      return fallback;
    }
    return n;
  }

  getBoolean(key: string, fallback: boolean): boolean {
    const raw: string = this.raw(key);
    if (raw.length === 0) {
      return fallback;
    }
    return raw === 'true';
  }

  getJson(key: string): Object | undefined {
    const raw: string = this.raw(key);
    if (raw.length === 0) {
      return undefined;
    }
    return Json.tryParse(raw);
  }

  getKeys(): Array<string> {
    const out: Array<string> = new Array<string>();
    const entries: IterableIterator<[string, string]> = this.active.entries();
    for (const entry of entries) {
      out.push(entry[0]);
    }
    const defEntries: IterableIterator<[string, string]> = this.defaults.entries();
    for (const entry of defEntries) {
      if (!this.active.hasKey(entry[0])) {
        out.push(entry[0]);
      }
    }
    return out;
  }

  etagValue(): string {
    return this.etag;
  }

  lastFetchedAt(): number {
    return this.lastFetchAt;
  }

  private raw(key: string): string {
    if (this.active.hasKey(key)) {
      return this.active.get(key) as string;
    }
    if (this.defaults.hasKey(key)) {
      return this.defaults.get(key) as string;
    }
    return '';
  }

  private commitFetched(body: string): void {
    const parsed: Object | undefined = Json.tryParse(body);
    if (parsed === undefined) {
      return;
    }
    this.active = new Map<string, string>();
    const entries: Array<Object> = parsed['entries'] as Array<Object>;
    if (entries === undefined) {
      return;
    }
    for (let i: number = 0; i < entries.length; i++) {
      const entry: Object = entries[i];
      const key: string = Json.string(entry, 'key', '');
      const value: Object | undefined = entry['value'];
      if (key.length > 0 && value !== undefined) {
        this.active.set(key, JSON.stringify(value));
      }
    }
  }

  private cacheKey(part: string): string {
    return `firebase.remoteconfig.${this.projectId}.${this.options.namespace}.${part}`;
  }
}

/**
 * A compile-time default value for the DefaultCache layer.
 */
export class ConfigDefault {
  key: string;
  value: string;

  constructor(key: string, value: string) {
    this.key = key;
    this.value = value;
  }
}

export type tokenProvider = () => Promise<string>;