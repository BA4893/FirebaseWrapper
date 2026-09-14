import { pushService } from '@kit.PushKit';
import { FirebaseException, FirebaseErrorCode } from '../common/FirebaseError';
import { Firestore } from '../firestore/Firestore';
import { Json } from '../common/Json';

/**
 * Client-side Push Kit token provider — the missing "device registered itself"
 * half that the official iOS/Android SDKs do transparently via APNs/FCM.
 *
 * Calls `pushService.getToken()` (@kit.PushKit) to obtain the HarmonyOS push
 * token, and upserts it into the caller's Firestore profile doc under
 * `devicePushToken` so a server (Cloud Function or proxy) can fan out sends.
 * See docs/PROTOCOLS.md §12 for the full `hw:` token contract.
 *
 * The `hw:` prefix is the transport tag the server router dispatches on:
 * `hw:<pushToken>` → Huawei Push Kit REST, absence → FCM v1 REST. The prefix
 * never reaches Push Kit — it is stripped/parsed server-side only.
 */
export class PushKitTokenProvider {
  private token: string = '';

  /**
   * Requests the device push token from Push Kit (cached per instance).
   * Throws fail-loudly — no synthetic FID tokens (parity with the SDK's
   * no-stubs policy).
   */
  async getToken(): Promise<string> {
    if (this.token.length > 0) {
      return this.token;
    }
    try {
      const t: string = await pushService.getToken();
      if (t === undefined || t.length === 0) {
        throw new FirebaseException(FirebaseErrorCode.UNKNOWN, 'pushkit: empty token');
      }
      this.token = t;
      return this.token;
    } catch (err) {
      if (err instanceof FirebaseException) {
        throw err;
      }
      throw new FirebaseException(FirebaseErrorCode.UNKNOWN,
        `pushkit getToken failed: ${(err as Error).message}`);
    }
  }

  /**
   * Convenience: token already obtained this session, else '' (the app may
   * still be registering lazily). Mirrors `AppCheckTokenProvider.cachedToken`.
   */
  cachedToken(): string {
    return this.token;
  }

  /** The `hw:`-tagged token as stored in the profile doc. */
  async prefixedToken(): Promise<string> {
    const t: string = await this.getToken();
    return PushKitTokenProvider.tag(t);
  }

  /** Applies the `hw:` transport tag (also the unit-test seam). */
  static tag(pushToken: string): string {
    if (pushToken.startsWith('hw:')) {
      return pushToken;
    }
    return `hw:${pushToken}`;
  }

  /** Inverse of {@link tag}; returns the raw Push Kit token. */
  static untag(value: string): string {
    return value.startsWith('hw:') ? value.substring(3) : value;
  }

  /**
   * Firestore REST typed-field update for the registry write: the tagged
   * token under `devicePushToken` as a `stringValue` (deterministic — the
   * unit-test seam for the token-registry logic).
   */
  static profileFields(tagged: string): Object {
    const fields: Object = {};
    const typed: Object = {};
    typed['stringValue'] = tagged;
    fields['devicePushToken'] = typed;
    return fields;
  }

  /**
   * Upserts the tagged token into the user's Firestore profile doc at
   * `users/{uid}` field `devicePushToken`. Idempotent — when the stored value
   * already matches, no write is issued.
   */
  async registerDeviceToken(db: Firestore, uid: string): Promise<string> {
    const tagged: string = await this.prefixedToken();
    const existing: Object = await this.readProfile(db, uid);
    const current: string = Json.string(existing, 'devicePushToken', '');
    if (current !== tagged) {
      await db.updateDocument(`users/${uid}`, PushKitTokenProvider.profileFields(tagged),
        ['devicePushToken']);
    }
    return tagged;
  }

  /** Profile read; a missing doc means no registration has happened yet. */
  private async readProfile(db: Firestore, uid: string): Promise<Object> {
    try {
      return await db.getDocument(`users/${uid}`);
    } catch (err) {
      return {};
    }
  }
}
