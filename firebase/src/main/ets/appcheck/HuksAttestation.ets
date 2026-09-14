import { huks } from '@kit.UniversalKeystoreKit';
import { Codec } from '../common/Codec';
import { FirebaseException, FirebaseErrorCode } from '../common/FirebaseError';

/**
 * Result of a HUKS key attestation.
 */
export class AttestationData {
  /** PEM X.509 certificate chain (root CA → device CA → device → key). */
  certChain: Array<string>;
  /** base64url-encoded attested public key (SPKI). */
  publicKey: string;

  constructor(certChain: Array<string>, publicKey: string) {
    this.certChain = certChain;
    this.publicKey = publicKey;
  }
}

/**
 * Wraps the Universal Keystore Kit (HUKS) for the App Check path:
 *
 *  1. {@link ensureAttestKey} — generate an ECC-256 key pair inside the device
 *     TEE (`huks.generateKeyItem`); the private key never leaves secure storage.
 *  2. {@link attestKey}       — anonymous key attestation returning an X.509
 *     chain rooted at the device root CA, bound to the server nonce via
 *     `HUKS_TAG_ATTESTATION_CHALLENGE`.
 *  3. {@link signChallenge}   — HUKS **session-flow signing**: `initSession` →
 *     `finishSession` hashes and signs `inData` inside the TEE. The returned
 *     signature is the proof the server verifies before minting the exchange
 *     token.
 *  4. {@link deleteAttestKey} — cleanup of the attestation key alias.
 *
 * This is the only appcheck class that touches the platform keystore kit;
 * everything else is pure domain logic.
 */
export class HuksAttestation {
  private useAnonymous: boolean;

  constructor(useAnonymous: boolean) {
    this.useAnonymous = useAnonymous;
  }

  /**
   * Generates the ECC P-256 signing key under `alias` when it does not exist.
   */
  async ensureAttestKey(alias: string): Promise<void> {
    const options: huks.HuksOptions = HuksAttestation.keyOptions();
    const exists: boolean = await this.run(
      () => huks.hasKeyItem(alias, options), 'ensureAttestKey.hasKeyItem');
    if (exists) {
      return;
    }
    await this.run(() => huks.generateKeyItem(alias, options), 'ensureAttestKey.generateKeyItem');
  }

  /**
   * Attests the key under `alias`, binding the certificate to `challenge`.
   * Uses anonymous attestation by default (no system permission required);
   * non-anonymous attestation is used when {@link useAnonymous} is false and the
   * app holds `ohos.permission.ATTEST_KEY`.
   */
  async attestKey(alias: string, challenge: string): Promise<AttestationData> {
    const options: huks.HuksOptions = HuksAttestation.attestOptions(challenge);
    const result: huks.HuksReturnResult = await this.run(() => {
      if (this.useAnonymous) {
        return huks.anonAttestKeyItem(alias, options);
      }
      return huks.attestKeyItem(alias, options);
    }, 'attestKey');
    const chains: Array<string> | undefined = result.certChains;
    if (chains === undefined || chains.length === 0) {
      throw HuksAttestation.fail('attestKey', 'HUKS returned no certificate chain');
    }
    const key: Uint8Array | undefined = result.outData;
    if (key === undefined || key.length === 0) {
      throw HuksAttestation.fail('attestKey', 'HUKS returned no attested public key');
    }
    return new AttestationData(chains, Codec.base64UrlEncode(key));
  }

  /**
   * Signs `challenge` with the TEE-held key using the HUKS session flow.
   * Returns a base64url ECDSA-SHA256 signature over the UTF-8 nonce.
   */
  async signChallenge(alias: string, challenge: string): Promise<string> {
    const options: huks.HuksOptions = HuksAttestation.signOptions(challenge);
    const session: huks.HuksSessionHandle = await this.run(
      () => huks.initSession(alias, options), 'initSession');
    try {
      const result: huks.HuksReturnResult = await this.run(
        () => huks.finishSession(session.handle, options), 'finishSession');
      const out: Uint8Array | undefined = result.outData;
      if (out === undefined || out.length === 0) {
        throw HuksAttestation.fail('signChallenge', 'HUKS returned an empty signature');
      }
      return Codec.base64UrlEncode(out);
    } catch (err) {
      await this.abort(session.handle);
      if (err instanceof FirebaseException) {
        throw err;
      }
      throw HuksAttestation.fail('signChallenge', HuksAttestation.errorDetail(err as Object));
    }
  }

  /**
   * Deletes the attestation key under `alias` from secure storage.
   */
  async deleteAttestKey(alias: string): Promise<void> {
    const options: huks.HuksOptions = HuksAttestation.keyOptions();
    await this.run(() => huks.deleteKeyItem(alias, options), 'deleteKeyItem');
  }
/**
   * Runs a HUKS call, normalizing thrown platform errors into a typed
   * {@link FirebaseException} with {@link FirebaseErrorCode.HUKS}.
   */
  private async run<T>(op: () => Promise<T>, opName: string): Promise<T> {
    try {
      return await op();
    } catch (err) {
      if (err instanceof FirebaseException) {
        throw err;
      }
      throw HuksAttestation.fail(opName, HuksAttestation.errorDetail(err as Object));
    }
  }

  /**
   * Best-effort session cleanup on the failure path (`abortSession` is required
   * when `initSession`/`updateSession`/`finishSession` did not complete).
   */
  private async abort(handle: number): Promise<void> {
    try {
      await huks.abortSession(handle, HuksAttestation.emptyOptions());
    } catch (err) {
      // Cleanup only — never mask the original signing failure.
    }
  }

  private static keyOptions(): huks.HuksOptions {
    const properties: Array<huks.HuksParam> = new Array<huks.HuksParam>();
    properties.push({ tag: huks.HuksTag.HUKS_TAG_ALGORITHM, value: huks.HuksKeyAlg.HUKS_ALG_ECC });
    properties.push({ tag: huks.HuksTag.HUKS_TAG_KEY_SIZE, value: huks.HuksKeySize.HUKS_AES_KEY_SIZE_256 });
    properties.push({
      tag: huks.HuksTag.HUKS_TAG_PURPOSE,
      value: huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_SIGN | huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_VERIFY
    });
    properties.push({ tag: huks.HuksTag.HUKS_TAG_DIGEST, value: huks.HuksKeyDigest.HUKS_DIGEST_SHA256 });
    const options: huks.HuksOptions = { properties: properties };
    return options;
  }

  private static attestOptions(challenge: string): huks.HuksOptions {
    const properties: Array<huks.HuksParam> = new Array<huks.HuksParam>();
    properties.push({
      tag: huks.HuksTag.HUKS_TAG_ATTESTATION_CHALLENGE,
      value: Codec.utf8(challenge)
    });
    const options: huks.HuksOptions = { properties: properties };
    return options;
  }

  private static signOptions(challenge: string): huks.HuksOptions {
    const options: huks.HuksOptions = HuksAttestation.keyOptions();
    options.inData = Codec.utf8(challenge);
    return options;
  }

  private static emptyOptions(): huks.HuksOptions {
    const options: huks.HuksOptions = { properties: new Array<huks.HuksParam>() };
    return options;
  }

  private static fail(op: string, detail: string): FirebaseException {
    return new FirebaseException(FirebaseErrorCode.HUKS, `${op}: ${detail}`);
  }

  private static errorDetail(err: Object): string {
    const code: Object | undefined = err['code'];
    const message: Object | undefined = err['message'];
    let out: string = '';
    if (code !== undefined) {
      out = String(code);
    }
    if (message !== undefined) {
      const text: string = message as string;
      if (text.length > 0) {
        out = out.length > 0 ? `${out}: ${text}` : text;
      }
    }
    return out.length > 0 ? out : 'unknown HUKS error';
  }
}