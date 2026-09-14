/**
 * Data models for the App Check / HUKS attestation flow.
 *
 * Pure domain types (no infrastructure imports) so the custom-proxy contract
 * (docs/PROTOCOLS.md §9) can be unit-tested without a device or a server.
 */

const NEVER_EXPIRES: number = 4102444800; // 2100-01-01T00:00:00Z (epoch seconds)

/**
 * One-time nonce issued by the custom attestation server.
 */
export class AppCheckChallenge {
  challenge: string;
  /** Unix epoch seconds at which the nonce expires. */
  expiresAt: number;

  constructor(challenge: string, expiresAt: number) {
    this.challenge = challenge;
    this.expiresAt = expiresAt;
  }

  isExpired(): boolean {
    return Date.now() / 1000 >= this.expiresAt;
  }

  /**
   * Parses the wire shape `{ challenge, expiresAt }` returned by
   * `POST {base}/v1/appcheck/challenge`.
   */
  static fromJson(parsed: Object): AppCheckChallenge | undefined {
    const challenge: Object | undefined = parsed['challenge'];
    if (challenge === undefined) {
      return undefined;
    }
    let expiry: number = NEVER_EXPIRES;
    const expiresAt: Object | undefined = parsed['expiresAt'];
    if (expiresAt !== undefined) {
      expiry = expiresAt as number;
    }
    return new AppCheckChallenge(challenge as string, expiry);
  }
}

/**
 * Device key attestation bundle posted to `POST {base}/v1/appcheck/attest`.
 * Carries the HUKS-issued X.509 chain rooted at the device root CA.
 */
export class AttestationBundle {
  deviceLabel: string;
  /** The nonce this attestation is bound to. */
  challenge: string;
  /** PEM-encoded X.509 certificate chain, root CA first, as returned by HUKS. */
  certChain: Array<string>;
  /** base64url-encoded attested public key (SPKI). */
  publicKey: string;
  /** Unix epoch milliseconds when the attestation was produced. */
  attestedAt: number;

  constructor(deviceLabel: string, challenge: string, certChain: Array<string>, publicKey: string, attestedAt: number) {
    this.deviceLabel = deviceLabel;
    this.challenge = challenge;
    this.certChain = certChain;
    this.publicKey = publicKey;
    this.attestedAt = attestedAt;
  }

  toJson(): string {
    const body: Object = {};
    body['deviceLabel'] = this.deviceLabel;
    body['challenge'] = this.challenge;
    body['certChain'] = this.certChain;
    body['publicKey'] = this.publicKey;
    body['attestedAt'] = this.attestedAt;
    return JSON.stringify(body);
  }
}

/**
 * Fire exchange token issued by `POST {base}/v1/appcheck/token` after the
 * server has validated the challenge signature produced by the device TEE.
 */
export class ExchangeTokenResult {
  /** Short-lived Firebase App Check token (`firebase_appcheck_token`). */
  token: string;
  /** Unix epoch seconds at which the token expires. */
  expiresAt: number;

  constructor(token: string, expiresAt: number) {
    this.token = token;
    this.expiresAt = expiresAt;
  }

  isExpired(): boolean {
    return Date.now() / 1000 >= this.expiresAt;
  }

  /**
   * Parses `{ firebase_appcheck_token, ... }`, tolerating `expiresAt`
   * (epoch seconds), `expiresAtMs` (epoch milliseconds), or `expiresIn`
   * (seconds from now). Missing expiry defaults to {@link NEVER_EXPIRES}.
   */
  static fromJson(parsed: Object): ExchangeTokenResult | undefined {
    const token: Object | undefined = parsed['firebase_appcheck_token'];
    if (token === undefined || (token as string).length === 0) {
      return undefined;
    }
    let expiry: number = NEVER_EXPIRES;
    const expiresAtMs: Object | undefined = parsed['expiresAtMs'];
    const expiresAt: Object | undefined = parsed['expiresAt'];
    const expiresIn: Object | undefined = parsed['expiresIn'];
    if (expiresAtMs !== undefined) {
      expiry = (expiresAtMs as number) / 1000;
    } else if (expiresAt !== undefined) {
      expiry = expiresAt as number;
    } else if (expiresIn !== undefined) {
      expiry = Date.now() / 1000 + (expiresIn as number);
    }
    return new ExchangeTokenResult(token as string, expiry);
  }
}

/**
 * Route suffixes of the custom App Check proxy (`serverBaseUrl`).
 * See docs/PROTOCOLS.md §9.
 */
export class AppCheckRoutes {
  static readonly CHALLENGE: string = '/v1/appcheck/challenge';
  static readonly ATTEST: string = '/v1/appcheck/attest';
  static readonly TOKEN: string = '/v1/appcheck/token';
}