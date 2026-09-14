/**
 * Firebase configuration bundle passed to {@link FirebaseApp.initialize}.
 * Mirrors the web SDK's firebase config object.
 *
 * This file is intentionally free of platform-kit imports: option values are
 * plain strings/numbers/booleans. The appcheck module owns the mapping onto
 * HUKS enums, so configuration never leaks keystore-coupled types.
 */
export class FirebaseOptions {
  /** Firebase project id, e.g. "my-app-12345". */
  apiKey: string;
  /** Web API key (shielding value from Project Settings → General). */
  projectId: string;
  /** Realtime Database name / base URL without scheme, e.g. "my-app-default-rtdb". */
  databaseURL: string;
  /** eg "my-app.firebaseapp.com" (used for some OOB links). */
  authDomain: string;
  /** Optional app label used for persisted-store namespaces. */
  appName: string;
  /** Optional app files directory; enables durable persistence (store + sealed secrets). */
  filesDir: string;

  constructor(apiKey: string, projectId: string, databaseURL: string, authDomain: string, appName: string) {
    this.apiKey = apiKey;
    this.projectId = projectId;
    this.databaseURL = databaseURL;
    this.authDomain = authDomain;
    this.appName = appName.length > 0 ? appName : projectId;
    this.filesDir = '';
  }

  /** Sets the app files directory (e.g. `this.context.filesDir`). Chainable. */
  withFilesDir(dir: string): FirebaseOptions {
    this.filesDir = dir;
    return this;
  }
}

/**
 * FCM registration captured from the Firebase console (Project Settings → Cloud Messaging).
 */
export class FcmOptions {
  /** Legacy FCM server key (only needed for the /fcm/send upstream path). */
  serverKey: string;
  /** Downlink email used for the MCS X-OAUTH2 ber, e.g. "12345@fcm.googleapis.com". */
  senderId: string;
  /** MCS gateway host. */
  gatewayHost: string;
  /** MCS gateway port. */
  gatewayPort: number;

  constructor(serverKey: string, senderId: string, gatewayHost: string, gatewayPort: number) {
    this.serverKey = serverKey;
    this.senderId = senderId;
    this.gatewayHost = gatewayHost;
    this.gatewayPort = gatewayPort;
  }
}

/**
 * Remote Config options.
 */
export class RemoteConfigOptions {
  /** Namespace served by this client (default "firebase"). */
  namespace: string;
  /** Fetch computed values via the configs:get:compute pipe. */
  compute: boolean;
  /** Minimum interval (ms) between forced network fetches; 0 disables the guard. */
  minFetchIntervalMs: number;

  constructor(namespace: string, compute: boolean, minFetchIntervalMs: number) {
    this.namespace = namespace;
    this.compute = compute;
    this.minFetchIntervalMs = minFetchIntervalMs;
  }
}

/**
 * In-App Messaging campaign transport. Firebase App Messaging delivers campaigns through
 * your project; `campaignBaseUrl` lets you point at the Firebase-managed endpoint or a
 * custom backend that mints targeting lists for this device.
 */
export class MessagingOptions {
  /** Base URL of the campaign source. */
  campaignBaseUrl: string;
  /** Poll interval (ms) while in foreground. */
  pollIntervalMs: number;

  constructor(campaignBaseUrl: string, pollIntervalMs: number) {
    this.campaignBaseUrl = campaignBaseUrl;
    this.pollIntervalMs = pollIntervalMs;
  }
}

/**
 * TEE key-policy values understood by {@link AppCheckOptions}.
 */
export class AppCheckKeyPolicy {
  static readonly ALGORITHM_ECC: string = 'ECC';
  static readonly ALGORITHM_RSA: string = 'RSA';
  static readonly STORAGE_LEVEL_CE: string = 'CE';
  static readonly STORAGE_LEVEL_DE: string = 'DE';
  static readonly STORAGE_LEVEL_ECE: string = 'ECE';
}

/**
 * App Check TEE attestation-key policy.
 */
export class AppCheckKeyOptions {
  algorithm: string;
  keySizeBits: number;
  digest: string;
  storageLevel: string;
  generateType: number;
  recreateOnInvalidApi: boolean;
  attestationSecLevel: string;
  attestationVersion: string;

  constructor(algorithm: string, keySizeBits: number, digest: string, storageLevel: string,
    generateType: number, recreateOnInvalidApi: boolean, attestationSecLevel: string,
    attestationVersion: string) {
    this.algorithm = algorithm;
    this.keySizeBits = keySizeBits;
    this.digest = digest;
    this.storageLevel = storageLevel;
    this.generateType = generateType;
    this.recreateOnInvalidApi = recreateOnInvalidApi;
    this.attestationSecLevel = attestationSecLevel;
    this.attestationVersion = attestationVersion;
  }

  static ecc(): AppCheckKeyOptions {
    return new AppCheckKeyOptions(AppCheckKeyPolicy.ALGORITHM_ECC, 256, 'SHA256',
      AppCheckKeyPolicy.STORAGE_LEVEL_CE, 0, true, 'sec_level', '1.0.0');
  }

  static rsa(): AppCheckKeyOptions {
    return new AppCheckKeyOptions(AppCheckKeyPolicy.ALGORITHM_RSA, 2048, 'SHA256',
      AppCheckKeyPolicy.STORAGE_LEVEL_CE, 0, true, 'sec_level', '1.0.0');
  }

  static defaultOptions(): AppCheckKeyOptions {
    return AppCheckKeyOptions.ecc();
  }
}

/**
 * App Check custom proxy configuration.
 */
export class AppCheckOptions {
  /** Base URL of your attestation/validation server. */
  serverBaseUrl: string;
  /** Device/app identifier reported to the challenge endpoint. */
  deviceLabel: string;
  /** HUKS key alias holding the TEE attestation key. */
  keyAlias: string;
  /**
   * Use anonymous HUKS key attestation (`anonAttestKeyItem`), which requires no
   * system permission. Set false only for system apps holding
   * `ohos.permission.ATTEST_KEY` (non-anonymous / device-identifying chain).
   */
  useAnonymousAttestation: boolean;
  /** TEE key policy used for generation, session signing, and attestation. */
  keyOptions: AppCheckKeyOptions;

  constructor(serverBaseUrl: string, deviceLabel: string, keyAlias: string,
    useAnonymousAttestation: boolean = true, keyOptions?: AppCheckKeyOptions) {
    this.serverBaseUrl = serverBaseUrl;
    this.deviceLabel = deviceLabel;
    this.keyAlias = keyAlias;
    this.useAnonymousAttestation = useAnonymousAttestation;
    this.keyOptions = keyOptions === undefined ? AppCheckKeyOptions.defaultOptions() : keyOptions;
  }
}