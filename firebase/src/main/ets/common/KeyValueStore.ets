import { fileIo } from '@kit.CoreFileKit';
import { FirebaseException, FirebaseErrorCode } from './FirebaseError';

/**
 * Durable key-value persistence backed by a JSON file, with an in-memory
 * fallback for environments without file-system access (unit tests, sandbox).
 *
 * Used by Remote Config (fetched cache + etag) and by CredentialStore.
 */
export class KeyValueStore {
  private path: string;
  private cache: Map<string, string>;
  private persistentEnabled: boolean;
  private loaded: boolean;

  constructor(path: string) {
    this.path = path;
    this.cache = new Map<string, string>();
    this.persistentEnabled = false;
    this.loaded = false;
  }

  /** Raw backing file path (CredentialStore derives its secure dir from it). */
  get filePath(): string {
    return this.path;
  }

  /**
   * Prepares the store. Call once at startup; safe to call repeatedly.
   */
  open(): void {
    if (this.loaded) {
      return;
    }
    this.loaded = true;
    try {
      const existing: string = fileIo.readTextSync(this.path);
      if (existing.length > 0) {
        const parsed: Object = JSON.parse(existing);
        const keys: Array<string> = Object.keys(parsed);
        for (let i: number = 0; i < keys.length; i++) {
          this.cache.set(keys[i], parsed[keys[i]] as string);
        }
      }
      this.persistentEnabled = true;
    } catch (err) {
      // First run (no file yet) or no FS access — stay in-memory.
      this.persistentEnabled = false;
    }
  }

  has(key: string): boolean {
    this.open();
    return this.cache.hasKey(key);
  }

  get(key: string, fallback: string): string {
    this.open();
    if (this.cache.hasKey(key)) {
      return this.cache.get(key) as string;
    }
    return fallback;
  }

  set(key: string, value: string): boolean {
    this.open();
    this.cache.set(key, value);
    if (!this.persistentEnabled) {
      return false;
    }
    return this.flush();
  }

  remove(key: string): void {
    this.open();
    if (this.cache.hasKey(key)) {
      this.cache.delete(key);
    }
    if (this.persistentEnabled) {
      this.flush();
    }
  }

  /** Lists cached keys with a prefix (used by the Crashlytics queue). */
  keysWithPrefix(prefix: string): Array<string> {
    this.open();
    const out: Array<string> = new Array<string>();
    const it: IterableIterator<string> = this.cache.keys();
    for (const k of it) {
      if (k.startsWith(prefix)) {
        out.push(k);
      }
    }
    return out;
  }

  clear(): void {
    this.open();
    this.cache = new Map<string, string>();
    if (this.persistentEnabled) {
      try {
        fileIo.unlinkSync(this.path);
      } catch (err) {
        this.persistentEnabled = false;
      }
    }
  }

  private flush(): boolean {
    try {
      const payload: Object = {};
      const entries: IterableIterator<[string, string]> = this.cache.entries();
      for (const entry of entries) {
        payload[entry[0]] = entry[1];
      }
      let file: fileIo.File | undefined = undefined;
      try {
        file = fileIo.openSync(this.path, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      } catch (err) {
        file = fileIo.openSync(this.path, fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      }
      const text: string = JSON.stringify(payload);
      const written: number = fileIo.writeSync(file.fd, text);
      fileIo.closeSync(file.fd);
      return written > 0;
    } catch (err) {
      this.persistentEnabled = false;
      return false;
    }
  }
}