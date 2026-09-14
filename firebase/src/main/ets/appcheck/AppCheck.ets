import { HttpTransport } from '../common/HttpTransport';
import { FirebaseException } from '../common/FirebaseError';
import { Json } from '../common/Json';
import { CredentialStore } from '../common/CredentialStore';
import { AppCheckOptions } from '../common/FirebaseConfig';
import { HuksAttestation, AttestationData } from './HuksAttestation';
import { AppCheckChallenge, AttestationBundle, ExchangeTokenResult, AppCheckRoutes } from './AppCheckModels';

/**
 * App Check via the custom Device Key Attestation Chain (see
 * docs/ARCHITECTURE.md Pillar 5 and docs/PROTOCOLS.md §9).
 *
 * Flow:
 *   1. {@link requestChallenge} — one-time nonce from your server.
 *   2. {@link attest}           — HUKS generates/attests the device key in the
 *      TEE, binds it to the nonce, and posts the X.509 chain for validation.
 *   3. {@link exchangeToken}    — the TEE-signed nonce proves possession of the
 *      private key; the server returns a short-lived Firebase App Check token.
 *   4. {@link currentToken}     — token accessor used by the other SDK services
 *      to attach `X-Firebase-AppCheck`; silently re-attests when empty.
 *
 * The returned token is held in memory only ({@link CredentialStore}).
 */
export class AppCheck {
  private transport: HttpTransport;
  private store: CredentialStore;
  private options: AppCheckOptions;
  private attestation: HuksAttestation;

  constructor(transport: HttpTransport, store: CredentialStore, options: AppCheckOptions) {
    this.transport = transport;
    this.store = store;
    this.options = options;
    this.attestation = new HuksAttestation(options.useAnonymousAttestation);
  }

  /**
   * Requests a one-time challenge nonce from the custom attestation server.
   */
  async requestChallenge(): Promise<AppCheckChallenge> {
    const body: Object = {};
    body['deviceLabel'] = this.options.deviceLabel;
    const envelope = await this.transport.post(this.url(AppCheckRoutes.CHALLENGE), JSON.stringify(body), [], '');
    if (!envelope.isOk()) {
      throw FirebaseException.api('appcheck.challenge', Json.firebaseErrorMessage(envelope.text));
    }
    const parsed: Object | undefined = Json.tryParse(envelope.text);
    if (parsed === undefined) {
      throw FirebaseException.api('appcheck.challenge', 'malformed response');
    }
    const challenge: AppCheckChallenge | undefined = AppCheckChallenge.fromJson(parsed);
    if (challenge === undefined) {
      throw FirebaseException.api('appcheck.challenge', 'missing challenge field');
    }
    return challenge;
  }

  /**
   * Attests the device key inside the TEE and posts the X.509 chain to the
   * server for validation. Returns the attested key material for later signing.
   */
  async attest(challenge: AppCheckChallenge): Promise<AttestationData> {
    await this.attestation.ensureAttestKey(this.options.keyAlias);
    const data: AttestationData = await this.attestation.attestKey(this.options.keyAlias, challenge.challenge);
    const bundle: AttestationBundle = new AttestationBundle(
      this.options.deviceLabel, challenge.challenge, data.certChain, data.publicKey, Date.now());
    const envelope = await this.transport.post(this.url(AppCheckRoutes.ATTEST), bundle.toJson(), [], '');
    if (!envelope.isOk()) {
      throw FirebaseException.api('appcheck.attest', Json.firebaseErrorMessage(envelope.text));
    }
    return data;
  }

  /**
   * Exchanges the TEE-signed challenge for a Firebase App Check token and
   * stores it (in-memory only).
   */
  async exchangeToken(challenge: AppCheckChallenge, signature: string): Promise<ExchangeTokenResult> {
    const body: Object = {};
    body['challenge'] = challenge.challenge;
    body['signature'] = signature;
    const envelope = await this.transport.post(this.url(AppCheckRoutes.TOKEN), JSON.stringify(body), [], '');
    if (!envelope.isOk()) {
      throw FirebaseException.api('appcheck.token', Json.firebaseErrorMessage(envelope.text));
    }
    const parsed: Object | undefined = Json.tryParse(envelope.text);
    if (parsed === undefined) {
      throw FirebaseException.api('appcheck.token', 'malformed response');
    }
    const result: ExchangeTokenResult | undefined = ExchangeTokenResult.fromJson(parsed);
    if (result === undefined) {
      throw FirebaseException.api('appcheck.token', 'missing firebase_appcheck_token');
    }
    this.store.saveAppCheckToken(result.token);
    return result;
  }

  /**
   * Runs the complete flow: challenge → TEE attestation + session-flow signing
   * → exchange token. Blocks on the server round-trips; prefer caching the
   * result through {@link currentToken} in steady state.
   */
  async attestForToken(): Promise<ExchangeTokenResult> {
    const challenge: AppCheckChallenge = await this.requestChallenge();
    await this.attest(challenge);
    const signature: string = await this.attestation.signChallenge(this.options.keyAlias, challenge.challenge);
    return this.exchangeToken(challenge, signature);
  }

  /**
   * Returns a valid exchange token, silently re-attesting when none is cached.
   */
  async currentToken(forceRefresh: boolean): Promise<string> {
    if (!forceRefresh) {
      const cached: string = this.store.loadAppCheckToken();
      if (cached.length > 0) {
        return cached;
      }
    }
    const result: ExchangeTokenResult = await this.attestForToken();
    return result.token;
  }

  private url(route: string): string {
    let base: string = this.options.serverBaseUrl;
    while (base.endsWith('/')) {
      base = base.substring(0, base.length - 1);
    }
    return `${base}${route}`;
  }
}