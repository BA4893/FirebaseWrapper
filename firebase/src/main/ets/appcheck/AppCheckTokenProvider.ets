import { CredentialStore } from '../common/CredentialStore';
import { AppCheck } from './AppCheck';

/**
 * Supplies the Firebase App Check token to the other SDK services (Firestore /
 * RTDB / Remote Config) which attach it as `X-Firebase-AppCheck`.
 *
 * Matches the SDK's `tokenProvider` shape `() => Promise<string>` — wrap with
 * `() => provider.getToken(false)`, or use {@link provide} directly.
 *
 * The token is short-lived and memory-only (see docs/ARCHITECTURE.md security
 * notes): it is never persisted to the backing key-value store.
 */
export class AppCheckTokenProvider {
  private appCheck: AppCheck;
  private store: CredentialStore;

  constructor(appCheck: AppCheck, store: CredentialStore) {
    this.appCheck = appCheck;
    this.store = store;
  }

  /**
   * Returns the current exchange token. When `forceRefresh` is false and a
   * token is already cached it is returned without network traffic; otherwise a
   * fresh attestation exchange is performed.
   */
  async getToken(forceRefresh: boolean): Promise<string> {
    return this.appCheck.currentToken(forceRefresh);
  }

  /**
   * A cached token, or '' when none has been exchanged yet. Synchronous —
   * safe for header assembly when a cached value is acceptable.
   */
  cachedToken(): string {
    return this.store.loadAppCheckToken();
  }

  /**
   * Structural match for the SDK's `tokenProvider` type.
   */
  provide(): () => Promise<string> {
    return () => this.getToken(false);
  }
}