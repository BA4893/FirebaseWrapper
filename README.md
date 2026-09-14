# FirebaseWrapper

A **custom, open-source Firebase client for HarmonyOS/OpenHarmony-Oniro** — a publishable
OHPM SDK package (`@openharmony/firebase`) plus an optional native **NAPI C++**
bridge (`firebase_native/`). It mirrors the public API surface of the official
[Firebase iOS SDK](https://github.com/firebase/firebase-ios-sdk) and
[Firebase Android SDK](https://github.com/firebase/firebase-android-sdk) —
**20 of 22 product modules on each platform** — in pure ArkTS, without any
Google Android native GMS framework on the device. Where a capability depends on platform
machinery OpenHarmony does not have (APNs, gRPC bidi-streams, PLCrashReporter,
Keychain), the SDK substitutes the platform equivalent (HUKS-sealed storage,
SSE long-poll, AGC AppTest) and documents the delta explicitly — see
[Parity & transparency](#parity--transparency). API-name parity is ~91%
(20/22 product modules on both reference SDKs); behavioural parity is
foreground-first and stated per module below — nothing fakes success.

## Repo layout

```
firebase/            # the SDK package (pure ArkTS, OHPM-publishable)
firebase_native/     # optional native NAPI C++ TLS-socket bridge (opt-in build)
entry/               # demo OpenHarmony app (HAP) consuming the SDK
docs/                # ARCHITECTURE.md · PROTOCOLS.md · OHPM_PUBLISHING.md
```

## Quick start (demo app)

1. Copy your Firebase web config (`apiKey`, project id, auth domain) into
   `entry/src/main/ets/Config.ets`.
2. Build & run the demo app; the dashboard surfaces all services.

```bash
# from repo root (DevEco-bundled toolchain)
ohpm install
hvigorw build --project-dir entry         # or use DevEco Studio: build the project
```

## SDK highlights

| Pillar | Module | Docs |
|---|---|---|
| FCM (manual socket) | `firebase/.../fcm/` | `docs/PROTOCOLS.md` §2–3 |
| In-App Messaging (manual UI) | `firebase/.../messaging/` | `docs/ARCHITECTURE.md` Pillar 2 |
| Analytics / Crashlytics REST | `firebase/.../analytics/`, `crashlytics/` | `docs/PROTOCOLS.md` §5–6 |
| Remote Config + ETag cache | `firebase/.../remoteconfig/` | `docs/PROTOCOLS.md` §4 |
| App Check via HUKS | `firebase/.../appcheck/` | `docs/ARCHITECTURE.md` Pillar 5 |
| Auth · Firestore · RTDB | `firebase/.../{auth,firestore,database}/` | `docs/PROTOCOLS.md` §1,7,8 |
| AppTest beta distribution | `firebase/.../dist/` | `docs/PROTOCOLS.md` §10 |

See `docs/ARCHITECTURE.md` for the full design and `docs/OHPM_PUBLISHING.md` for
publishing the package to the OHPM registry.

## Parity & transparency

### Product coverage vs. iOS / Android SDKs

| Firebase product | iOS module | Android module | Here | State in this SDK |
|---|---|---|---|---|
| Auth | `FirebaseAuth` | `firebase-auth` | `auth/` | email/password, anonymous, phone (code+confirm), custom token, OAuth (Google/Apple) + link, password reset, delete, `onAuthStateChanged`; refresh token HUKS-sealed, MFA (enroll + sign-in challenge). No email-link sign-in / reauthenticate yet |
| Firestore | `FirebaseFirestore` | `firebase-firestore` | `firestore/` | CRUD, structured `runQuery`, `listen()` (SSE long-poll), `cachedGet` offline fallback, `WriteBatch` / `runTransaction` as **read-modify-write helpers, not atomic** (proxy commit for atomicity) |
| Realtime Database | `FirebaseDatabase` | `firebase-database` | `database/` | REST CRUD, `onValue()` SSE watcher, `transaction()` helper, `onDisconnect` via proxy (falls back to immediate write) |
| Cloud Messaging | `FirebaseMessaging` | `firebase-messaging` | `fcm/` | registration tokens **only via proxy** (`/v1/installations:register` — no local stubs), topics, upstream relay; downstream = community-documented MCS TLS socket (native bridge optional). No APNs on this platform |
| Push router (multi-OS) | — | — | `push/` + `docs/proxy/cloud-function/` | Cloud Function callable fans a mixed fleet out on one Firebase project: `hw:`-tagged Push Kit tokens → Huawei Push Kit REST, others → FCM v1. Token registry via `PushKitTokenProvider` (`devicePushToken` in `users/{uid}`); notification-type payloads for killed-app banner delivery. Contract: `docs/PROTOCOLS.md` §12 |
| In-App Messaging | `FirebaseInAppMessaging` | `firebase-inappmessaging` | `messaging/` | trigger/campaign fetch against **your backend** (Firebase IAM delivery doesn't serve OHOS clients) |
| Analytics | `FirebaseAnalytics` | `firebase-analytics` | `analytics/` | GA4 Measurement Protocol, batched (750 events / 10 s) |
| Crashlytics | `FirebaseCrashlytics` | `firebase-crashlytics` | `crashlytics/` | JS-level capture (`uncaughtException`/`unhandledRejection` hook), breadcrumbs, persisted unsent queue + flush. No native signal/mach capture, no dSYM processing |
| Remote Config | `FirebaseRemoteConfig` | `firebase-config` | `remoteconfig/` | fetch + ETag/304 cache, defaults, typed getters |
| App Check | `FirebaseAppCheck` | `firebase-appcheck` | `appcheck/` | HUKS attestation → challenge/signature exchanged at **your proxy** for a Firebase AppCheck token |
| Storage | `FirebaseStorage` | `firebase-storage` | `storage/` | upload / download / metadata / list + resumable chunked uploads (`resumableSession` / `uploadChunk` / `cancelSession`, GCS session URI) |
| Functions | `FirebaseFunctions` | `firebase-functions` | `functions/` | callables with region support |
| Installations | `FirebaseInstallations` | `firebase-installations` | `installations/` | FID + auth token, delete |
| Performance | `FirebasePerformance` | `firebase-perf` | `perf/` | traces with custom attributes/metrics, REST ingest |
| A/B Testing | `FirebaseABTesting` | `firebase-abt` | `abtesting/` | experiment variant lookup |
| AI (Gemini) | `FirebaseAI` | `firebase-ai` | `ai/` | `generateContent` |
| Data Connect | `FirebaseDataConnect` | `firebase-dataconnect` | `dataconnect/` | `executeQuery` |
| Sessions | `FirebaseSessions` | `firebase-sessions` | `sessions/` | session id + rotate + start events |
| ML Model Downloader | `FirebaseMLModelDownloader` | `firebase-ml-modeldownloader` | `ml/` | model info / cached info |
| App Distribution | `FirebaseAppDistribution` | `firebase-appdistribution` | `dist/` | **AGC AppTest** (TestFlight equivalent): releases, upload/commit slots, tester allow-list, `checkForUpdate`, FID signup |
| Core | `FirebaseCore` | `firebase-common` | `FirebaseApp.ets` | multi-app cache, options, fail-loud token policy (`idTokenLoud`, typed `APP_CHECK` errors) |
| Dynamic Links | `FirebaseDynamicLinks` | `firebase-dynamic-links` | — | **not ported** — service deprecated/shut down (2025) on both reference platforms |
| Combine / KTX adapters | `FirebaseCombineSwift` | kotlin extensions | — | language-bound reactive adapters; N/A in ArkTS |

**Coverage: 20/22 product modules on both reference SDKs (~91% name parity).**
Platform-only infra (gradle plugins, `firebase-crashlytics-ndk`, datatransport,
component framework) has no OpenHarmony equivalent and is intentionally absent.

### Honest behavioural deltas

Deeper API-name parity should not be read as behavioural parity. The following
are deliberate, documented downgrades — each throws or labels itself rather
than faking success:

1. **Firestore/RTDB transactions are not server-atomic.** A single REST client
   cannot run compare-and-set; they are read-modify-write helpers. Route
   commits through your proxy for true atomicity.
2. **FCM registration tokens require the proxy** (`docs/PROTOCOLS.md` §9.1).
   Without it the call throws — no `fid:` pseudo-tokens.
3. **RTDB `onDisconnect` needs the proxy** (§9.3) to hold the op server-side;
   without it the write executes immediately.
4. **Firestore `listen()` is SSE long-poll**, not the binary gRPC Listen
   protocol; snapshot latency and ordering guarantees differ.
5. **Crashlytics captures JS-level crashes only** — no native signal/mach
   handlers, no symbolication.
6. **In-App Messaging fetches from your backend**, not Firebase's IAM servers.
7. **Push fan-out runs in your Cloud Function** (`docs/PROTOCOLS.md` §12) —
   the SDK registers the `hw:`-tagged Push Kit token into the user's
   Firestore profile; the router dispatches to Push Kit/FCM. HarmonyOS data
   (silent) pushes require the app process, so user-facing alerts ride
   notification-type messages (banner delivery while killed is equivalent).

### Platform substitutions (iOS → OpenHarmony)

| iOS mechanism | This SDK on OpenHarmony |
|---|---|
| Keychain | `SecureStore` — HUKS AES-256-GCM TEE key, CSPRNG IVs (`@ohos.security.cryptoFramework`), fail-closed; ciphertext files under the app files dir |
| DeviceCheck / App Attest | HUKS attestation bundle → your proxy → Firebase AppCheck token |
| TestFlight | AGC AppTest via `app.appDistribution()` (proxy contract: `docs/PROTOCOLS.md` §10) |
| APNs push | AGC Push Kit is the platform channel; FCM downstream uses the MCS socket or your relay; multi-OS fan-out via the §12 Cloud Function router (`PushKitTokenProvider` + `docs/proxy/cloud-function/`) |
| gRPC streams | SSE long-poll with 1 s→30 s backoff (`SseStream`) |
| CocoaPods/SPM | OHPM package (`docs/OHPM_PUBLISHING.md`) |

### Build & test status

- Pure ArkTS: 48 source files, 67 public exports, 21 service factories on
  `FirebaseApp`.
- Unit tests: `firebase/src/test/FirebaseUnit.test.ets` covers the deterministic
  core (protobuf codec round-trips, MCS framing + stream split, SSE
  parsing/dispatch, Firestore path math, OAuth POST body, error-message
  parsing). Run via DevEco's test runner.
- Compile verification is pending CI: `hvigor`/`ohpm` ship with DevEco Studio
  and are not on this repo's PATH — run `ohpm install && hvigorw build` in
  DevEco before publishing.
- Sealed storage is complete: `SecureStore` encrypts with a HUKS AES-256-GCM
  TEE key, derives IVs from `@ohos.security.cryptoFramework` (CSPRNG), and
  persists ciphertext files under the app files dir. Apps opt in with
  `new FirebaseOptions(...).withFilesDir(this.context.filesDir)` — without it
  (and in unit-test sandboxes) the store stays memory-only. Remaining platform
  deltas are the behavioural ones listed above — none are silent.

See `docs/PROTOCOLS.md` for every wire contract (§9–10 = the proxy routes FCM,
AppCheck, `onDisconnect`, and AppTest depend on; §11–12 = Push Kit REST and
the multi-OS push router, with the reference Cloud Function in
`docs/proxy/cloud-function/index.js`).

## License

Apache-2.0. This is an independent, clean-room client implementation of publicly
documented Firebase REST endpoints. The FCM downstream channel is built on the
community-documented MCS protocol described in `docs/PROTOCOLS.md`; Google's private
protocol may change without notice. Firebase is a trademark of Google LLC;
HarmonyOS, OpenHarmony, and AppGallery Connect are trademarks of their respective
owners. This project is not affiliated with, endorsed by, or derived from Google
or Huawei code.