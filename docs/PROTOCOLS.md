# Wire protocol reference (community-documented)

This document records the exact binary/JSON contracts implemented by
`@openharmony/firebase`. All Google-service endpoints are public Firebase REST endpoints
except the FCM **downstream** channel, which follows the community-documented
reverse-engineered MCS framing that the Firebase/Google Android SDKs used over TLS.
Constants live in exactly one place per codec and are toggles — if Google's private
protocol drifts, patch the constant, not the client.

## 1. Firebase Auth (Identity Toolkit REST)

| Operation | Endpoint |
|---|---|
| Sign up w/ email+password | `POST https://identitytoolkit.googleapis.com/v1/accounts:signUp?key={API_KEY}` |
| Sign in w/ password | `POST https://identitytoolkit.googleapis.com/v1/accounts:signInWithPassword?key={API_KEY}` |
| Refresh token | `POST https://securetoken.googleapis.com/v1/token?key={API_KEY}` body `{grant_type:"refresh_token", refresh_token}` |
| Get account info | `POST https://identitytoolkit.googleapis.com/v1/accounts:lookup?key={API_KEY}` auth `Bearer idToken` |

Response shape (id-token flows): `{ idToken, email, refreshToken, expiresIn, localId, ... }`.

## 2. FCM upstream (send)

- Legacy: `POST https://fcm.googleapis.com/fcm/send` header `Authorization: key=<SERVER_KEY>`.
- v1: `POST https://fcm.googleapis.com/v1/projects/{projectId}/messages:send` with an
  OAuth2 bearer acquired from `https://oauth2.googleapis.com/token` using the
  service-account client credentials (server-side only).
- Recommended client path: your **custom Firebase proxy** (holds Admin keys) relays sends.

## 3. FCM downstream — MCS binary stream

### Connection
`TLS to fcm.googleapis.com:5228` (fallback `mtalk.google.com:5228`). TLS 1.2+,
server-auth via the system trust store (pure-ArkTS transport) or OpenSSL verify (native
bridge). After the TLS handshake the channel is a bare octet stream:

### Frame format
```
[uint32 BE payloadLen] [uint16 LE frameId] [payload]
```
`payloadLen` includes the 2 frame-id bytes. Max frame 64 KiB.

### Frame ids (`McsFrameIds`)
| id | name | direction | payload |
|----|------|-----------|---------|
| 3  | `WIRE_VERSION`     | C→S | `AndroidCheckin` protobuf (device type, app/version) |
| 5  | `LOGIN`            | C→S | `GcmPacket{message_type=LOGIN_REQUEST}`, `LoginRequest{ device_id, subtype: AUTH_ROUTE, auth_type: SASL, encoded_auth: ber }` |
| 6  | `CHANNEL_SELECT`   | C→S | channel-select payload |
| 7  | `STREAM_PING`      | ⇄   | keep-alive request / response |
| 8  | `STREAM_START`     | S→C | stream established |
| 11 | `MESSAGE_CLEARTEXT`| S→C | `GcmPacket{message_type=MCS_PACKET}`, `{ endpoint, sub_endpoint, data }`; `data` = `ClientMessage` protobuf (`cuid`, `app_id`, `goog_msg_type`, `goog_msg_subtype`, `payload`, `expiration`) |
| 12 | `HEARTBEAT_PING`   | C→S | TCP keep-alive guard frame |
| 13 | `PING_REQUEST`     | ⇄   | ping request (answered 14) |
| 14 | `PING_RESPONSE`    | ⇄   | ping response |

### Login credential (`ber`)
`LoginRequest.encoded_auth` = base64 of `user=<fcm-email>\0auth=Bearer <idToken>\0\0`
with `auth_type=SASL`. The FCM downlink email is `{project-number}@fcm.googleapis.com`
(from your Firebase project; configurable).

### `GcmPacket` protobuf field numbers
```
GcmPacket { message_type=1, android_checkin=2, login_request=3, login_response=4, mcs=5 }
AndroidCheckin { type=1, chrome_version=2, device_model=3, android_device=..., login_url=... }
LoginRequest { auto_retry=1, device_id=2, subtype=3, auth_type=4, encoded_auth=5, device_level=6 }
LoginResponse { status=1, retry_delay=2 }
MCS_Packet { endpoint=1, sub_endpoint=2, data=3 }
ClientMessage { cuid=1, app_id=2, goog_msg_type=3, goog_msg_subtype=4, payload=5, expiration=6 }
```
Protobuf wire codec (`fcm/protobuf/ProtobufWriter.ets` / `ProtobufReader.ets`) supports
varint + length-delimited fields — exactly the subset above — plus golden round-trip tests.

### Heartbeat
`HeartbeatPingScheduler` — min 240 s, max 600 s, default 300 s. Any inbound frame resets
the timer; ping-timeout 60 s → reconnect with exponential backoff (1, 2, 4, …, 60 s cap).

## 4. Remote Config REST

`POST https://firebaseremoteconfig.googleapis.com/v1/projects/{projectId}/namespaces/{namespace}/configs:get`
Bearer auth, body `{}` (GET form: same URL). Headers: `If-None-Match: <etag>`.
- `200` → `{ entries:[ {key, value, updateTime, etag} ], etag, ... }`
- `304` → no body; use fetched cache.
Compute pipe: `configs:get:compute` returns computed/resolved configs.

## 5. Analytics — GA4 Measurement Protocol

`POST https://firebaselogging-pa.googleapis.com/v1/measurement`
```
{
  "client_anonymous_id": "...",
  "events": [
    { "name": "my_event", "params": { ... }, "timestamp_micros": 1720000000000000 },
    ...
  ]
}
```
Batch flush at 750 events or 10 s idle, whichever comes first.

## 6. Crashlytics ingestion

`POST https://firebasecrashlytics-pa.googleapis.com` JSON body with
`{ name, message, stack_trace, platform, app_version, device_model, user, ... }`.

## 7. Firestore REST v1

`https://firestore.googleapis.com/v1/projects/{projectId}/databases/(default)/documents/{path}`
with `Authorization: Bearer <idToken>` and optional `X-Firebase-AppCheck`. Methods:
GET / POST (create) / PATCH (update) / DELETE; `:runQuery` for structured queries.

## 8. RTDB REST

`https://{database}.firebaseio.com/*.json?auth=<idToken>` — GET / PUT / POST / PATCH /
DELETE; realtime via a shallow long-poll SSE watcher (`accept: text/event-stream`,
`readTimeout` ≈ 55 s, re-arm loop).

## 9. Custom Firebase Proxy

All endpoints are defined by **your** backend; this SDK ships only the client half.
Every route below is `POST {base}<path>` with `content-type: application/json`.
Error contract: non-2xx bodies SHOULD be `{"error":{"message":"..."}}` —
`Json.firebaseErrorMessage()` (used by every module) parses that shape first.

| Route (default) | Purpose |
|---|---|
| `POST {base}/v1/appcheck/challenge`  | returns `{ challenge, expiresAt }` |
| `POST {base}/v1/appcheck/attest`     | body = attestation bundle → validates X.509 chain |
| `POST {base}/v1/appcheck/token`      | body = challenge signature → `{ firebase_appcheck_token }` |
| `POST {base}/v1/messages:send`       | FCM send relay (optional) |
| `POST {base}/v1/installations:register` | mints FCM registration tokens (below) |
| `POST {base}/v1/topics:batchAdd` / `:batchRemove` | topic ops relay (below) |
| `POST {base}/v1/rtdb:onDisconnect`   | holds RTDB disconnect writes (below) |

### 9.1 `POST /v1/installations:register` — FCM token minting

`FirebaseMessaging.registrationToken(fid)` calls this; with no proxy configured it
throws (`fcm-token`) instead of returning a fake token.

```
request  { "fid": "<Installations FID>" }
response { "token": "<fcm registration token>" }
```
Proxy side: hold the FCM **Admin** credential (service-account OAuth2 or legacy
server key). Create/refresh the token server-side keyed on `fid`, cache it so
repeat calls return the same token (tokens are stable per device).

### 9.2 `POST /v1/topics:batchAdd` / `topics:batchRemove` — topic ops

```
request  { "op": "batchAdd|batchRemove", "topic": "<name>", "token": "<reg token>" }
response 200, empty body
```
Proxy side: relay to `POST https://iid.googleapis.com/iid/v1/{token}/rel/topics/{topic}`
(Admin bearer). The client falls back to direct IID only when a legacy server key
is set; the proxy path is preferred (key never ships in-app).

### 9.3 `POST /v1/rtdb:onDisconnect` — server-held disconnect writes

`RealtimeDatabase.onDisconnectSet/Remove` call this **instead of** writing
immediately; the proxy must own a persistent RTDB connection (REST stream or
Admin SDK) and apply the op when the device's connection drops. Without a proxy
the client degrades to an immediate write (documented behaviour).

```
request  { "op": "set|remove", "path": "<rtdb path>", "value": <any JSON> }
response 200, empty body
```
Proxy side: key ops by device (auth header when present), register
`onDisconnect` on its socket/REST session for `path`, apply `value`.

### 9.4 `POST /v1/messages:send` — FCM upstream relay

```
request  { "to": "<topic|token>", "data": {...}, "notification": {...} }
response { "message_id": "<...>" }  (or proxy-shaped; client only checks 2xx)
```
Proxy side: translate to v1 `projects/{pid}/messages:send` with the Admin OAuth2
bearer, or legacy `/fcm/send` with `Authorization: key=<SERVER_KEY>`.

## 10. AppTest beta distribution (`dist/AppDistribution.ets`)

HarmonyOS AppTest (AppGallery Connect **App Testing**) is the TestFlight
equivalent: upload a signed HAP, define tester allow-lists, testers install via
the console-generated install page (`appTestUrl`). AGC has **no per-device open
REST API** for releases/testers — the device-facing routes below are served by
**your proxy**, which calls the AGC OpenAPI with the server key. Client entry:
`app.appDistribution(distEndpoint)`.

### 10.1 `GET {base}/v1/apps/{appId}/releases` — list releases

Backs `AppDistribution.listReleases(appId)` and `checkForUpdate(appId, v)`.
```
response { "releases": [ { "releaseId": "...", "versionName": "1.2.3",
  "versionCode": 456, "releaseNotes": "...", "downloadUrl": "...",
  "appTestUrl": "<AGC AppTest install page>", "createdAt": 1720000000 }, ... ] }
```
**AGC OpenAPI (server-side, server-key auth):**
```
GET https://api.deveco.huawei.com/api/publish/{appId}/releases
Authorization: Bearer <AGC access token>
```
Map each AGC release object to the shape above; `appTestUrl` is the AGC AppTest
install page for the release. `checkForUpdate` compares `versionCode` locally and
returns the newest release newer than the running build, else `undefined`.

### 10.2 `POST {base}/v1/apps/{appId}/releases:upload` — create release slot

Backs `AppDistribution.uploadRelease(appId, versionName, versionCode, notes)`.
```
request  { "versionName": "...", "versionCode": 123, "releaseNotes": "..." }
response { "releaseId": "...", "uploadUrl": "..." }
```
Proxy side: allocate `releaseId` (or create the AGC upload task via OpenAPI) and
return a pre-signed `uploadUrl` where CI PUTs the signed `.hap`/`.app`.

### 10.3 `POST {base}/v1/apps/{appId}/releases:commit` — publish to testers

Backs `AppDistribution.commitRelease(appId, releaseId)`.
```
request  { "releaseId": "..." }
response full release object (§10.1 shape)
```
Proxy side: verify the upload completed, then create the AGC AppTest release
task with the uploaded HAP and expose it to the allow-listed testers.

### 10.4 `POST {base}/v1/apps/{appId}/testers:add` — allow-list testers

Backs `AppDistribution.addTesters(appId, releaseId, emails)`. This is the route
the SDK client calls; the proxy translates it into the AGC OpenAPI call.
```
request  { "releaseId": "...", "emails": ["a@x.com", "b@x.com"] }
response 200, empty body
```
**AGC OpenAPI translation (server-side, server-key auth):**
```
POST https://api.deveco.huawei.com/api/publish/{appId}/releases/{releaseId}/testers
Authorization: Bearer <AGC access token>
Content-Type: application/json

{ "testers": [ { "email": "a@x.com" }, { "email": "b@x.com" } ] }
```
Notes: the AGC route is scoped to a single release — batch across releases by
looping server-side. `Authorization` is the AGC OAuth2 access token obtained
with the server key (AGC Connect `token.php`, `grant_type=client_credentials`);
the device bearer only identifies the caller to the proxy.

### 10.5 `POST {base}/v1/apps/{appId}/testers:signup` — tester opt-in

Backs `AppDistribution.testerSignup(appId, releaseId, fid)` (mirrors iOS
`testerSignIn()`): records an Installations FID against a release so the console
shows uptake. Proxy-side persistence only — no AGC OpenAPI involved.
```
request  { "releaseId": "...", "fid": "<Installations FID>" }
response 200, empty body
```
Proxy side: upsert `(releaseId, fid)` keyed by the caller's auth subject; expose
uptake counts to your own console.