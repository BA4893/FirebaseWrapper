import { FirebaseOptions, FcmOptions, RemoteConfigOptions, MessagingOptions, AppCheckOptions } from './common/FirebaseConfig';
import { FirebaseException, FirebaseErrorCode } from './common/FirebaseError';
import { HttpTransport } from './common/HttpTransport';
import { KeyValueStore } from './common/KeyValueStore';
import { CredentialStore } from './common/CredentialStore';
import { EventChannel } from './common/EventChannel';
import { common } from '@kit.AbilityKit';
import { FirebaseAuth } from './auth/FirebaseAuth';
import { Firestore } from './firestore/Firestore';
import { FirestoreCache } from './firestore/FirestoreCache';
import { RealtimeDatabase } from './database/RealtimeDatabase';
import { FirebaseStorage } from './storage/FirebaseStorage';
import { FirebaseFunctions } from './functions/FirebaseFunctions';
import { Installations } from './installations/Installations';
import { Performance, perfErrorSink } from './perf/Performance';
import { AppDistribution, distTokenProvider } from './dist/AppDistribution';
import { ABTesting } from './abtesting/ABTesting';
import { AILogic } from './ai/AILogic';
import { DataConnect } from './dataconnect/DataConnect';
import { Sessions } from './sessions/Sessions';
import { MLModelDownloader } from './ml/MLModelDownloader';
import { RemoteConfig } from './remoteconfig/RemoteConfig';
import { AnalyticsApi, analyticsErrorSink } from './analytics/AnalyticsApi';
import { Crashlytics, CrashContext, crashErrorSink } from './crashlytics/Crashlytics';
import { NativeCrashBridge } from './crashlytics/NativeCrashBridge';
import { InAppMessaging } from './messaging/InAppMessaging';
import { AppCheck } from './appcheck/AppCheck';
import { AppCheckTokenProvider } from './appcheck/AppCheckTokenProvider';
import { FirebaseMessaging, FcmClientOptions } from './fcm/FcmClient';
import { TlsSocketTransport } from './fcm/transport/TlsSocketTransport';
import { FcmTransport } from './fcm/transport/FcmTransport';
import { HwPushClient } from './push/HwPushClient';
import { LocalNotifier } from './push/LocalNotifier';

/** Bootstrap facade: credential + token management, service factories. */
export class FirebaseApp {
  private static cache: Map<string, FirebaseApp> = new Map<string, FirebaseApp>();

  readonly name: string;
  readonly options: FirebaseOptions;
  readonly http: HttpTransport;
  readonly store: KeyValueStore;
  readonly credentials: CredentialStore;
  readonly events: EventChannel;
  readonly auth: FirebaseAuth;
  readonly appCheck: AppCheck;
  readonly appCheckTokens: AppCheckTokenProvider;
  readonly installs: Installations;

  private constructor(name: string, options: FirebaseOptions, checkOpts?: AppCheckOptions) {
    this.name = name;
    this.options = options;
    this.http = new HttpTransport(15000, 55000);
    const dir: string = options.filesDir.length > 0 ? `${options.filesDir}/` : '';
    this.store = new KeyValueStore(`${dir}firebase.${options.appName}.${name}.json`);
    this.credentials = new CredentialStore(this.store);
    this.events = new EventChannel(128);
    this.auth = new FirebaseAuth(this.http, options.apiKey, this.credentials);
    this.installs = new Installations(this.http, options.projectId, options.apiKey, this.store);
    const resolved: AppCheckOptions = checkOpts !== undefined ? checkOpts :
      new AppCheckOptions('', options.appName, `firebase.${name}`, true);
    this.appCheck = new AppCheck(this.http, this.credentials, resolved);
    this.appCheckTokens = new AppCheckTokenProvider(this.appCheck, this.credentials);
  }

  static initialize(options: FirebaseOptions, name: string = '[DEFAULT]',
    checkOpts?: AppCheckOptions): FirebaseApp {
    if (options.projectId.length === 0 || options.apiKey.length === 0) {
      throw new FirebaseException(FirebaseErrorCode.INVALID_APP_CONFIG, 'apiKey/projectId required');
    }
    if (FirebaseApp.cache.has(name)) {
      return FirebaseApp.cache.get(name) as FirebaseApp;
    }
    const app: FirebaseApp = new FirebaseApp(name, options, checkOpts);
    FirebaseApp.cache.set(name, app);
    return app;
  }

  static named(name: string): FirebaseApp {
    if (!FirebaseApp.cache.has(name)) {
      throw new FirebaseException(FirebaseErrorCode.INVALID_APP_CONFIG, `no app: ${name}`);
    }
    return FirebaseApp.cache.get(name) as FirebaseApp;
  }

  /** Fail-loud id token: surfaces AUTH errors, never silent ''. */
  private idTokenLoud(): () => Promise<string> {
    return () => this.auth.idToken(false);
  }

  /** Best-effort AppCheck token: '' only when no proxy configured. */
  private appCheckSoft(): () => Promise<string> {
    return () => this.appCheckTokens.getToken(false).catch((err: Error) => {
      throw new FirebaseException(FirebaseErrorCode.APP_CHECK,
        `appcheck unavailable: ${err.message}`);
    });
  }

  firestore(): Firestore {
    return new Firestore(this.http, this.options.projectId,
      this.idTokenLoud(), this.appCheckSoft());
  }

  database(): RealtimeDatabase {
    return new RealtimeDatabase(this.http, this.options.databaseURL, this.idTokenLoud());
  }

  remoteConfig(opts: RemoteConfigOptions): RemoteConfig {
    return new RemoteConfig(this.http, this.options.projectId, opts, this.store, this.idTokenLoud());
  }

  analytics(endpoint: string, anonId: string, sink: analyticsErrorSink): AnalyticsApi {
    return new AnalyticsApi(this.http, endpoint, anonId, sink);
  }

  crashlytics(ctx: CrashContext, sink: crashErrorSink): Crashlytics {
    return new Crashlytics(this.http, '', ctx, sink);
  }

  messaging(opts: MessagingOptions, deviceId: string): InAppMessaging {
    return new InAppMessaging(this.http, this.options.projectId, deviceId,
      opts, this.events, this.idTokenLoud());
  }

  storage(bucket: string): FirebaseStorage {
    return new FirebaseStorage(this.http, bucket, this.idTokenLoud());
  }

  functions(region: string): FirebaseFunctions {
    return new FirebaseFunctions(this.http, this.options.projectId, region, this.idTokenLoud());
  }

  installations(): Installations {
    return this.installs;
  }

  perf(appId: string, sink: perfErrorSink): Performance {
    return new Performance(this.http, '', appId, sink);
  }

  /**
   * AppTest beta distribution (TestFlight equivalent).
   * `distEndpoint` must be your proxy holding the AGC Connect server key —
   * AGC has no per-device open API for releases.
   */
  appDistribution(distEndpoint: string): AppDistribution {
    const p: distTokenProvider = async (): Promise<string> => {
      const t: string = await this.auth.idToken(false);
      return t;
    };
    return new AppDistribution(this.http, distEndpoint, p);
  }

  abTesting(): ABTesting {
    return new ABTesting(this.http, this.options.projectId, this.idTokenLoud());
  }

  aiLogic(location: string): AILogic {
    return new AILogic(this.http, this.options.projectId, location, this.idTokenLoud());
  }

  dataConnect(location: string, service: string): DataConnect {
    return new DataConnect(this.http, this.options.projectId, location, service, this.idTokenLoud());
  }

  sessions(appId: string): Sessions {
    return new Sessions(this.http, appId);
  }

  mlModels(): MLModelDownloader {
    return new MLModelDownloader(this.http, this.options.projectId, this.idTokenLoud(), this.store);
  }

  fcm(opts: FcmOptions, proxyBaseUrl: string, transport?: FcmTransport): FirebaseMessaging {
    const t: FcmTransport = transport !== undefined ? transport : new TlsSocketTransport();
    const o: FcmClientOptions = new FcmClientOptions(opts.senderId,
      opts.gatewayHost, opts.gatewayPort, 'OpenHarmony', opts.serverKey, proxyBaseUrl);
    return new FirebaseMessaging(t, this.http, o, () => this.auth.idToken(false), this.events);
  }

  /**
   * HarmonyOS Push Kit sender (APNs/FCM-downstream equivalent).
   * `appSecret` stays in app config / your proxy — see PROTOCOLS §11.
   */
  hwPush(appId: string, appSecret: string): HwPushClient {
    return new HwPushClient(this.http, appId, appSecret);
  }

  /**
   * ArkData-backed Firestore offline cache (iOS local-persistence equivalent).
   * Pass the UIAbility context; attach with `firestore().attachCache(...)`.
   */
  firestoreCache(context: common.Context, dbName: string = `firebase_${this.name}_firestore`): FirestoreCache {
    return new FirestoreCache(context, dbName);
  }

  /** Drain for native crash reports captured by the `firebase_native/` NAPI bridge. */
  nativeCrashBridge(): NativeCrashBridge {
    return new NativeCrashBridge();
  }

  /**
   * Local OS notifications via **Notification Kit** — surface silent/data
   * pushes (or any in-app event) in the notification center.
   */
  localNotifier(): LocalNotifier {
    return new LocalNotifier();
  }
}
