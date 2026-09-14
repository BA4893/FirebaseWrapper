/**
 * Firebase error codes mirroring the semantics of the official Firebase SDKs.
 */
export enum FirebaseErrorCode {
  NONE = 0,
  /** Generic / unknown failure. */
  UNKNOWN = 1,
  /** Invalid or missing Firebase configuration. */
  INVALID_APP_CONFIG = 2,
  /** Network layer failure (DNS, connect, TLS, read/write). */
  NETWORK = 3,
  /** HTTP-level failure wrapped with status code. */
  HTTP = 4,
  /** Firebase REST error (server responded with an error payload). */
  API = 5,
  /** Authentication failure / expired or malformed credential. */
  AUTH = 6,
  /** App Check attestation unavailable or rejected. */
  APP_CHECK = 7,
  /** Remote Config cache miss (value absent in all cache layers). */
  CONFIG_NOT_FOUND = 8,
  /** Protobuf / MCS frame decode failure on the FCM downstream channel. */
  PROTOCOL = 9,
  /** FCM downlink stream not connected / not logged in. */
  FCM_NOT_CONNECTED = 10,
  /** Keep-alive ping timed out (reconnect scheduled). */
  FCM_PING_TIMEOUT = 11,
  /** In-App Messaging campaign payload malformed. */
  CAMPAIGN_PARSE = 12,
  /** Persistence layer failure (cache/credential write). */
  STORAGE = 13,
  /** HUKS wrapper failure (key generation, attestation, signing). */
  HUKS = 14,
  /** Internal invariant violation. */
  INTERNAL = 15
}

/**
 * A structured Firebase error. Extends the builtin Error so it can be thrown/caught,
 * and carries a machine-readable {@link FirebaseErrorCode} plus optional context.
 */
export class FirebaseException extends Error {
  readonly code: FirebaseErrorCode;
  readonly detail: string;
  readonly cause?: Error;

  constructor(code: FirebaseErrorCode, detail: string, cause?: Error) {
    super(detail);
    this.code = code;
    this.detail = detail;
    this.cause = cause;
  }

  static unknown(detail: string, cause?: Error): FirebaseException {
    return new FirebaseException(FirebaseErrorCode.UNKNOWN, detail, cause);
  }

  static network(detail: string, cause?: Error): FirebaseException {
    return new FirebaseException(FirebaseErrorCode.NETWORK, detail, cause);
  }

  static http(status: number, detail: string): FirebaseException {
    return new FirebaseException(FirebaseErrorCode.HTTP, `HTTP ${status}: ${detail}`);
  }

  static api(causeDetail: string, detail: string): FirebaseException {
    return new FirebaseException(FirebaseErrorCode.API, `${causeDetail}: ${detail}`);
  }

  static auth(detail: string, cause?: Error): FirebaseException {
    return new FirebaseException(FirebaseErrorCode.AUTH, detail, cause);
  }

  static huks(detail: string, cause?: Error): FirebaseException {
    return new FirebaseException(FirebaseErrorCode.HUKS, detail, cause);
  }
}