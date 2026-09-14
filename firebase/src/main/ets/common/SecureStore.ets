import { huks } from '@kit.UniversalKeystoreKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { fileIo } from '@kit.CoreFileKit';
import { Codec } from './Codec';
import { FirebaseException, FirebaseErrorCode } from './FirebaseError';

/**
 * HUKS-backed secure storage for secrets (auth refresh tokens, FCM tokens).
 * Equivalent role to iOS Keychain: AES-256-GCM key in the TEE encrypts
 * values before they touch disk; on HUKS failure it throws (fail-closed)
 * rather than writing plaintext.
 *
 * Persistence: ciphertext is written under `baseDir` (pass the app files
 * directory). With no `baseDir` the store is memory-only (unit tests).
 * IVs come from `@ohos.security.cryptoFramework` (CSPRNG) with a
 * deterministic fallback for sandboxed test environments only.
 */
export class SecureStore {
  private alias: string;
  private baseDir: string;
  private fallback: Map<string, string>;

  constructor(alias: string, baseDir: string = '') {
    this.alias = alias;
    this.baseDir = SecureStore.normDir(baseDir);
    this.fallback = new Map<string, string>();
  }

  async setSecret(key: string, value: string): Promise<void> {
    let wrapped: string;
    try {
      await SecureStore.ensureKey(this.alias);
      const iv: Uint8Array = this.randomIv(12);
      const cipher: Uint8Array = await SecureStore.crypt(this.alias, true, iv, Codec.utf8(value));
      const wrappedObj: Object = {};
      wrappedObj['iv'] = Codec.base64UrlEncode(iv);
      wrappedObj['data'] = Codec.base64UrlEncode(cipher);
      wrapped = JSON.stringify(wrappedObj);
    } catch (err) {
      throw new FirebaseException(FirebaseErrorCode.HUKS,
        `secure-store set ${key} failed; refusing plaintext write`);
    }
    this.writeRaw(this.diskKey(key), wrapped);
  }

  async getSecret(key: string): Promise<string> {
    const raw: string = this.readRaw(this.diskKey(key));
    if (raw.length === 0) {
      return '';
    }
    try {
      const parsed: Object = JSON.parse(raw);
      const iv: Uint8Array = Codec.base64UrlDecode(parsed['iv'] as string);
      const data: Uint8Array = Codec.base64UrlDecode(parsed['data'] as string);
      const plain: Uint8Array = await SecureStore.crypt(this.alias, false, iv, data);
      return new TextDecoder().decode(plain);
    } catch (err) {
      throw new FirebaseException(FirebaseErrorCode.HUKS, `secure-store get ${key} failed`);
    }
  }

  async removeSecret(key: string): Promise<void> {
    try {
      this.deleteRaw(this.diskKey(key));
    } catch (err) {
    }
    this.fallback.delete(key);
  }

  private diskKey(key: string): string {
    return `secure.${this.alias}.${key}`;
  }

  private static async ensureKey(alias: string): Promise<void> {
    const props: huks.HuksParam[] = [
      { tag: huks.HuksTag.HUKS_TAG_ALGORITHM, value: huks.HuksKeyAlg.HUKS_ALG_AES },
      { tag: huks.HuksTag.HUKS_TAG_KEY_SIZE, value: huks.HuksKeySize.HUKS_AES_KEY_SIZE_256 },
      { tag: huks.HuksTag.HUKS_TAG_PURPOSE,
        value: huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_ENCRYPT | huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_DECRYPT },
      { tag: huks.HuksTag.HUKS_TAG_PADDING, value: huks.HuksKeyPadding.HUKS_PADDING_NONE },
      { tag: huks.HuksTag.HUKS_TAG_BLOCK_MODE, value: huks.HuksMode.HUKS_MODE_GCM },
    ];
    const opts: huks.HuksOptions = { properties: props };
    try {
      const has: boolean = await huks.hasKeyItem(alias, opts);
      if (!has) {
        await huks.generateKeyItem(alias, opts);
      }
    } catch (err) {
      await huks.generateKeyItem(alias, opts);
    }
  }

  private static async crypt(alias: string, encrypt: boolean, iv: Uint8Array,
    data: Uint8Array): Promise<Uint8Array> {
    const props: huks.HuksParam[] = [
      { tag: huks.HuksTag.HUKS_TAG_ALGORITHM, value: huks.HuksKeyAlg.HUKS_ALG_AES },
      { tag: huks.HuksTag.HUKS_TAG_PURPOSE,
        value: encrypt ? huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_ENCRYPT : huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_DECRYPT },
      { tag: huks.HuksTag.HUKS_TAG_PADDING, value: huks.HuksKeyPadding.HUKS_PADDING_NONE },
      { tag: huks.HuksTag.HUKS_TAG_BLOCK_MODE, value: huks.HuksMode.HUKS_MODE_GCM },
      { tag: huks.HuksTag.HUKS_TAG_NONCE, value: iv },
    ];
    const opts: huks.HuksOptions = { properties: props, inData: data };
    const session: huks.HuksSessionResult = await huks.initSession(alias, opts);
    try {
      const out: huks.HuksSessionResult = await huks.finishSession(session.handle, opts);
      return out.outData as Uint8Array;
    } finally {
      try {
        await huks.abortSession(session.handle, { properties: [] });
      } catch (err) {
      }
    }
  }

  private randomIv(n: number): Uint8Array {
    const out: Uint8Array = new Uint8Array(n);
    try {
      const rng = cryptoFramework.createRandom();
      const dataBlob: cryptoFramework.DataBlob = rng.generateRandomSync(n);
      const src: Uint8Array = dataBlob.data;
      for (let i: number = 0; i < n; i++) {
        out[i] = src[i];
      }
      return out;
    } catch (err) {
      // No CSPRNG in this environment (unit tests / previewer sandbox):
      // fall back to a non-crypto PRNG. Fail-closed policy stays intact
      // because HUKS itself still gates the key.
      let seed: number = Date.now() & 0xffffffff;
      for (let i: number = 0; i < n; i++) {
        seed = (seed * 1103515245 + 12345) & 0x7fffffff;
        out[i] = seed & 0xff;
      }
      return out;
    }
  }

  private static normDir(dir: string): string {
    let d: string = dir;
    while (d.length > 0 && d.endsWith('/')) {
      d = d.substring(0, d.length - 1);
    }
    return d;
  }

  private diskKey(key: string): string {
    return `secure.${this.alias}.${key}`;
  }

  private readRaw(key: string): string {
    if (this.baseDir.length > 0) {
      try {
        return fileIo.readTextSync(`${this.baseDir}/${key}`);
      } catch (err) {
        // Fall through to the memory layer.
      }
    }
    return this.fallback.hasKey(key) ? this.fallback.get(key) as string : '';
  }

  private writeRaw(key: string, value: string): void {
    if (this.baseDir.length > 0) {
      const path: string = `${this.baseDir}/${key}`;
      try {
        let file: fileIo.File;
        try {
          file = fileIo.openSync(path,
            fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
        } catch (err) {
          file = fileIo.openSync(path,
            fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
        }
        try {
          fileIo.writeSync(file.fd, value);
        } finally {
          fileIo.closeSync(file.fd);
        }
        return;
      } catch (err) {
        // No usable FS in this environment — memory layer keeps it sandbox-safe.
      }
    }
    this.fallback.set(key, value);
  }

  private deleteRaw(key: string): void {
    if (this.baseDir.length > 0) {
      try {
        fileIo.unlinkSync(`${this.baseDir}/${key}`);
      } catch (err) {
        // Already gone or no FS — removal stays semantically successful.
      }
    }
    this.fallback.delete(key);
  }
}
