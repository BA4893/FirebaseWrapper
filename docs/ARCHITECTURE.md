# FirebaseWrapper — OpenHarmony NEXT Firebase Client SDK — Architecture

A clean-architecture, publishable **OHPM package** (`@openharmony/firebase`) plus an
optional native **NAPI C++ bridge** (`firebase_native/`) that together re-implement the
Firebase client SDK surface for OpenHarmony NEXT (HarmonyOS, API >= 24) without relying on
Google Play Services, Google's native SDKs, or platform-native attestation hardware.

```
                       ┌──────────────────────────────────────────────────────────┐
                       │                      Your App (ArkTS / ArkUI)            │
                       │   Index.ets · FcmPage · RemoteConfigPage · AppCheckPage │
                       └───────────────┬─────────────────────────────────────────┘
                                       │ @openharmony/firebase
                       ┌───────────────▼──────────────────────────────────────────┐
                       │  FirebaseApp (facade / bootstrap, credential + token mgt)│
                       ├──────────┬───────────────┬───────────────┬───────────────┤
                       │  Auth    │  RemoteConfig │  Firestore    │  RTDB         │
                       │  (IdTok.)│  (ETag 3-tier │  (REST v1)    │  (REST + SSE) │
                       │          │   cache)      │               │               │
                       ├──────────┴───────────────┴───────────────┴───────────────┤
                       │  Analytics (GA4 MP REST, batched) · Crashlytics (ingest) │
                       ├──────────────────────────────┬──────────────────────────►│
                       │  In-App Messaging (REST poll │  App Check (HUKS attest.) │
                       │  → EventChannel → Overlay UI)│  → attestation chain →    │
                       │                              │  Custom Firebase Proxy    │
                       ├──────────────────────────────▼───────────────────────────┤
                       │  FCM — FirebaseMessaging (MCS downstream client)         │
                       │   ├─ FcmTransport (pluggable)                            │
                       │   │   ├─ NapiBridgeTransport  (native C++ TLS socket)    │
                       │   │   └─ TlsSocketTransport   (pure ArkTS TLSSocket)     │
                       │   ├─ McsWire · GcmPacket protobuf codec · X-OAUTH2 login │
                       │   └─ Heartbeat (4–10 min) · backoff · reconnect          │
                       └──────────────────────────────────────────────────────────┘
```

## Directory layout

```
firebase/                 # OHPM package: @openharmony/firebase (pure ArkTS, publishable)
  src/main/ets/
    common/               # FirebaseError, Codec (base64url/JSON), HttpTransport,
                          # CredentialStore (Preferences), EventChannel (pub/sub)
    auth/                 # FirebaseAuth — Identity Toolkit REST + token refresh
    firestore/            # Firestore REST v1 (documents + runQuery)
    database/             # RTDB REST + SSE long-poll watcher
    remoteconfig/         # Remote Config REST + Default/Active/Fetched cache + ETag
    messaging/            # In-App Messaging campaign poller + models
    analytics/            # GA4 Measurement Protocol client (batched, non-blocking)
    crashlytics/          # Crashlytics ingestion + global handler hook
    appcheck/             # HUKS attestation chain + custom proxy flow
    fcm/                  # FirebaseMessaging — MCS downstream client
      protobuf/           # self-contained protobuf wire encoder/decoder
      mcs/                # MCS frame codec + stream parser
      transport/          # FcmTransport IF · TlsSocketTransport · NapiBridgeTransport
    FirebaseApp.ets       # Facade
    index.ets             # Public exports
firebase_native/          # OPT-IN native NAPI C++ TLS-socket bridge (see README)
  src/                    # napi plugin host, TLS socket, protobuf decoder, mcs→JSON
  build/                  # GYP/`.gni` glue + hvigor wiring recipe (not in default build)
entry/                    # Demo HAP app consuming the SDK
  src/main/ets/pages/     # Dashboard, FCM, Remote Config, Messaging, App Check pages
docs/                     # This doc + PROTOCOLS.md + OHPM_PUBLISHING.md
```

## Pillar 1 — Cloud Messaging (FCM), client-side manual socket

No Google Play Services exists on this kernel, so the send/receive path is rebuilt:

- **Downstream (device ← Google):** a persistent TLS socket to Google's Mobile Cloud
  Messaging gateway (`fcm.googleapis.com:5228`). The channel is a length-prefixed binary
  frame stream (MCS framing). The `GcmPacket` envelope and inner messages
  (`AndroidCheckin`, `LoginRequest`/`LoginResponse`, `MCS_Packet`) are hand-rolled
  protobuf wire codecs in `firebase/src/main/ets/fcm/protobuf/` — zero external protobuf
  runtime. Wire details + provenance live in `docs/PROTOCOLS.md`.
- **Transport pluggability:** the `FcmTransport` interface decouples the client from the
  socket implementation:
  - `TlsSocketTransport` — pure ArkTS over `@ohos.net.socket.TLSSocket`
    (from `@kit.NetworkKit`); zero native code. This is what makes the publishable OHPM
    package self-contained on any NEXT device.
  - `NapiBridgeTransport` — speaks to the native C++ bridge in `firebase_native/`, which
    owns a low-level socket + OpenSSL TLS connection on the OpenHarmony network stack and
    streams decoded JSON frames back over the NAPI channel, exactly per the original
    design:
    ```
    [Google MCS] ──TLS── [Native C++ core] ──NAPI── [ArkTS layer] ──EventChannel── [App]
    ```
- **Heartbeat maintenance:** `HeartbeatPingScheduler` sends MCS `STREAM_PING` frames on
  an adaptive 4–10 minute interval (default 5 min) so network providers don't reap the
  idle connection; any inbound frame resets the timer. Unanswered pings trigger the
  reconnect path.
- **Protobuf → JSON:** `GcmPacket` frames are decoded by the native bridge into a JSON
  string, or by the ArkTS codec directly, then mapped to typed `FcmMessage` objects.
- **Upstream (device → Google):** legacy HTTP `/fcm/send` (server key), HTTP v1
  `/v1/projects/{pid}/messages:send` (OAuth2 via service-account creds), or a
  **custom-proxy relay** reusing your Firebase Admin private keys (recommended).

> The MCS gateway is Google's private protocol. This SDK follows the community-documented
> binary mapping (`docs/PROTOCOLS.md`) and treats every constant as a toggle. All
> deterministic client logic (lifecycle, keep-alive, backoff, routing) is
> transport-agnostic and unit-tested.

## Pillar 2 — In-App Messaging, manual UI rendering

Firebase In-App Messaging ships campaign configs server-side; platform-native UI
injection is impossible here, so:

1. **REST hook** — during foreground initialization, `InAppMessaging.refresh()`
   queries the configured transport (Firebase Remote Config `app-messaging` pipe, or a
   custom backend) for active campaigns targeting this device.
2. **Payload bubble** — campaign config (`body`, `backgroundColor`, `deepLink` URL, …)
   is normalized into `CampaignEntry` objects and pushed into the shared `EventChannel`
   as JSON events.
3. **Pure ArkTS injection** — the app's root window stack wraps a global
   `CampaignOverlay` widget; on a campaign event it renders a modal `OverlayEntry` dialog
   fully inside the ArkUI execution tree (no OS window layer).

This mirrors the Flutter `MethodChannel` bubble you'd use with a Dart view: the SDK only
mutates an event stream; the view layer decides rendering.

## Pillar 3 — Analytics & Crashlytics, REST mapping

- **Analytics:** `AnalyticsApi` implements the GA4 Measurement Protocol — every
  `logEvent(action, params)` enqueues a typed `MeasurementEvent` with `timestamp_micros`
  and flushes via asynchronous `POST https://firebaselogging-pa.googleapis.com/v1/measurement`
  (configurable base URL). Batching (≤ 750 events), retry-with-backpressure, and
  non-blocking fire-and-forget semantics mirror the official SDK's measuring queue.
- **Crashlytics:** no native crash daemon — `Crashlytics.installGlobalHandler()` is
  invoked from `EntryAbility`. The Dart/Flutter `FlutterError.onError` maps to ArkTS as:
  serialize exception candidate + stack, `POST` to the Crashlytics ingestion endpoint
  (default `https://firebasecrashlytics-pa.googleapis.com`). Bundles session context
  (device model, app version, user when logged in).

## Pillar 4 — Remote Config, custom network fetch + real caching

`RemoteConfig` implements the three-layer cache **in memory + `Preferences`**:

| Layer        | Backing                          |
|--------------|----------------------------------|
| DefaultCache | constants passed at create       |
| ActiveCache  | in-memory merged values (defaults overridden by active) |
| FetchedCache | last server payload persisted via `Preferences` |

- **Network query:** `POST configs:get` (or `configs:get:compute`) to
  `https://firebaseremoteconfig.googleapis.com/v1/projects/{pid}/namespaces/{ns}/configs`
  with `If-None-Match: <etag>`.
- **Local sync:** on `304` reuse the fetched cache; on `200` parse `entries`, store the
  server `etag`, and commit into ActiveCache. `get`/`getNumber`/`getString`/`getBoolean`
  read ActiveCache → DefaultCache.

## Pillar 5 — App Check / attestation workaround via HUKS

Apple App Attest / Google Play Integrity do not exist on this hardware, so App Check
attestation is replaced with a **custom Device Key Attestation Chain** using the
Universal Keystore Kit (HUKS):

```
[App / HUKS Kit] ─(1. Challenge request)──▶ [Your Custom App Server]
     ▲                                            │
     │ (2. signs key in device TEE,               │
     │     exports X.509 chain)                   │ (3. validates chain)
     │                                            ▼
     └───────────────── (4. issues Firebase exchange token) ──▶ [Firebase Proxy]
[App Client] ◀──(5. attaches exchange token)── Custom Firebase Proxy
```

1. `AppCheck.requestChallenge()` → one-time nonce from your server.
2. `HuksAttestation.ensureAttestKey()` generates an ECC key pair **inside the device
   TEE** (`huks.generateKeyItem`), then `huks.attestKeyItem` returns the signed
   attestation + X.509 `certChains` rooted at the device's physical root certificate.
3. `AppCheck.submitAttestation()` posts the chain + challenge to your server.
4. Your server (which holds Firebase Admin credentials) validates the chain and returns a
   Firebase exchange token.
5. `AppCheckTokenProvider` supplies it as `X-Firebase-AppCheck` on Firestore / RTDB /
   Remote Config calls, so Firebase sees a genuinely attested app.

## Cross-cutting

- **Auth** (`auth/FirebaseAuth`), **Firestore** (`firestore/Firestore`), and **RTDB**
  (`database/RealtimeDatabase`) REST mappings complete the SDK's "on par" surface for
  CRUD + realtime paths; all calls carry `Authorization: Bearer <idToken>` plus an App
  Check header whenever an attestation token is available.
- **Error model:** every failure surfaces as a typed `FirebaseException` with a stable
  `FirebaseErrorCode` (mirroring the official `FirebaseException`/`code` semantics).
- **Layering** follows the project Clean-Architecture guide: domain DTOs and use-cases are
  pure ArkTS; only `common/HttpTransport`, `common/CredentialStore`, and the FCM
  transports touch infrastructure APIs.

## Security notes

- Firebase API keys are write-only shielding values; the ID token is what grants access.
- Service-account private keys must **never** ship in this client package — the
  `firebase_native` / proxy path keeps them server-side.
- App Check exchange tokens are short-lived and stored only in memory.