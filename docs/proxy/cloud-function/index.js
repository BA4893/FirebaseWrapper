'use strict';

/**
 * Firebase Cloud Function router — multi-OS push fan-out on one Firebase
 * project. The wire contract is docs/PROTOCOLS.md §12; the Huawei endpoints
 * and payload shape mirror firebase/src/main/ets/push/HwPushClient.ets
 * (lines 32–33) exactly:
 *
 *   token  https://oauth-login.cloud.huawei.com/oauth2/v3/token
 *   send   https://push-api.cloud.huawei.com/v1/{appId}/messages:send
 *
 * SECURITY (§12.4): HUAWEI_CLIENT_SECRET lives only here, in the function's
 * secret store. The SDK's in-app `HwPushClient(appSecret)` path is dev-only —
 * never ship it.
 *
 * Deploy:
 *   firebase functions:secrets:set HUAWEI_APP_ID
 *   firebase functions:secrets:set HUAWEI_CLIENT_SECRET
 *   firebase deploy --only functions:pushRouter
 * Deps: firebase-admin, firebase-functions, axios.
 *
 * Caller example (any client with a Firebase Auth identity):
 *   const send = httpsCallable(getFunctions(), 'pushRouter');
 *   await send({ uid, title: 'Hi', body: 'You have a new message',
 *                data: JSON.stringify({ deeplink: 'app://inbox' }) });
 */

const { onCall, HttpsError } = require('firebase-functions/v2/https');
const axios = require('axios');
const admin = require('firebase-admin');

admin.initializeApp();

// ---- Configuration (secrets/env) -----------------------------------------
// AGC console → Project Settings → General → App Information: APP_ID and
// Client secret. APP_ID is also the {appId} path segment in the send URL.
const HUAWEI_APP_ID = process.env.HUAWEI_APP_ID || '';
const HUAWEI_CLIENT_SECRET = process.env.HUAWEI_CLIENT_SECRET || '';
// Deep link opened by notification taps (click_action type 1). The app must
// register the scheme in module.json5 → abilities[].skills[].uris.
const DEFAULT_CLICK_INTENT = process.env.PUSH_CLICK_INTENT || 'scheme://test?data=test';

// ---- Endpoints — mirror HwPushClient.ets lines 32–33 ---------------------
const HW_TOKEN_URL = 'https://oauth-login.cloud.huawei.com/oauth2/v3/token';
const HW_SEND_BASE = 'https://push-api.cloud.huawei.com/v1';

// OAuth access-token cache — mirrors HwPushClient.accessToken(): cached,
// proactively refreshed 60 s before expiry, force-refresh on 401.
const tokenCache = { token: '', expiresAt: 0 };

/**
 * Routes on the SDK's `hw:` tag scheme — must stay in sync with
 * PushKitTokenProvider.tag()/untag(): `hw:<push kit token>` → HarmonyOS
 * (Push Kit REST); any other non-empty value → FCM (iOS/Android tokens).
 */
function parseRoute(devicePushToken) {
  const stored = (devicePushToken || '').trim();
  if (stored.startsWith('hw:')) {
    return { platform: 'harmonyos', pushToken: stored.slice('hw:'.length) };
  }
  if (stored.length === 0) {
    return null;
  }
  return { platform: 'fcm', pushToken: stored };
}

function errMessage(err) {
  const resp = err && err.response;
  if (resp) {
    const text = typeof resp.data === 'string' ? resp.data : JSON.stringify(resp.data || {});
    return `HTTP ${resp.status}: ${text}`;
  }
  return (err && err.message) || String(err);
}

async function huaweiAccessToken(forceRefresh = false) {
  if (!forceRefresh && tokenCache.token && Date.now() < tokenCache.expiresAt - 60000) {
    return tokenCache.token;
  }
  const form = new URLSearchParams({
    grant_type: 'client_credentials',
    client_id: HUAWEI_APP_ID,
    client_secret: HUAWEI_CLIENT_SECRET,
  }).toString();
  try {
    const res = await axios.post(HW_TOKEN_URL, form, {
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      timeout: 15000,
    });
    const accessToken = res.data && res.data.access_token;
    if (!accessToken) {
      throw new Error('no access_token in response');
    }
    const expiresIn = Number(res.data.expires_in) || 3600;
    tokenCache.token = accessToken;
    tokenCache.expiresAt = Date.now() + expiresIn * 1000;
    return tokenCache.token;
  } catch (err) {
    throw new HttpsError('internal', `hwpush oauth: ${errMessage(err)}`);
  }
}

/**
 * Notification-type message (§12.2) — mirrors HwPushClient.sendNotification's
 * body and adds the click action: `type: 1` (open the app) with the NEXT
 * deep-link `intent` the app registers in module.json5 skills.
 */
function buildHwNotification(pushToken, title, body, payload, clickIntent) {
  const data = payload ? { payload: payload } : {};
  return {
    data: data,
    android: {
      urgency: 'HIGH',
      notification: {
        title: title,
        body: body,
        click_action: {
          type: 1,
          intent: clickIntent || DEFAULT_CLICK_INTENT,
        },
      },
    },
    token: [pushToken],
  };
}

/** FCM v1 branch — same surface for iOS/Android tokens (non-`hw:` values). */
function buildFcmMessage(pushToken, title, body, payload, extraData) {
  const msg = {
    token: pushToken,
    notification: { title: title, body: body },
    android: { priority: 'HIGH' },
  };
  if (payload && payload.length > 0) {
    msg.data = { payload: payload };
  } else if (extraData && Object.keys(extraData).length > 0) {
    msg.data = extraData;
  }
  return msg;
}

async function sendHw(pushToken, message, forceRefresh = false) {
  const at = await huaweiAccessToken(forceRefresh);
  return axios.post(`${HW_SEND_BASE}/${HUAWEI_APP_ID}/messages:send`,
    { message: message },
    {
      headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${at}` },
      timeout: 15000,
    });
}

/**
 * pushRouter — the §12 send contract. One entry point for a mixed fleet:
 * callers never learn which transport a device uses; the stored
 * `devicePushToken` decides.
 */
const pushRouter = onCall({ secrets: ['HUAWEI_CLIENT_SECRET'] }, async (request) => {
  if (!request.auth) {
    throw new HttpsError('unauthenticated', 'sign in before sending');
  }
  if (!HUAWEI_APP_ID || !HUAWEI_CLIENT_SECRET) {
    throw new HttpsError('failed-precondition',
      'set the HUAWEI_APP_ID / HUAWEI_CLIENT_SECRET function secrets first');
  }

  const input = request.data || {};
  if (!input.uid || !input.title || !input.body) {
    throw new HttpsError('invalid-argument', 'required: uid, title, body');
  }
  const payload = input.payload === undefined || input.payload === null
    ? '' : String(input.payload);
  const data = input.data && typeof input.data === 'object' ? input.data : {};
  const clickIntent = input.clickIntent || '';

  // §12.1 token registry — the field the device app wrote at registration.
  const snap = await admin.firestore().doc(`users/${input.uid}`).get();
  if (!snap.exists) {
    throw new HttpsError('not-found',
      `no profile document users/${input.uid} — device registration never ran`);
  }
  const profile = snap.data() || {};
  const route = parseRoute(profile.devicePushToken);
  if (!route) {
    throw new HttpsError('not-found',
      `users/${input.uid} has no devicePushToken — call the SDK's registerDeviceToken() first`);
  }

  if (route.platform === 'harmonyos') {
    try {
      // §12.2: notification-type so the banner delivers while the app is killed.
      const res = await sendHw(route.pushToken,
        buildHwNotification(route.pushToken, input.title, input.body, payload, clickIntent));
      return { routed: route.platform, requestId: res.data && res.data.requestId };
    } catch (err) {
      const status = err && err.response && err.response.status;
      if (status === 401 || status === 403) {
        // Expired Huawei OAuth token — force refresh once, retry once.
        const res = await sendHw(route.pushToken,
          buildHwNotification(route.pushToken, input.title, input.body, payload, clickIntent),
          true);
        return { routed: route.platform, requestId: res.data && res.data.requestId, retried: true };
      }
      throw new HttpsError('internal', `hwpush send failed: ${errMessage(err)}`);
    }
  }

  try {
    const id = await admin.messaging().send(
      buildFcmMessage(route.pushToken, input.title, input.body, payload, data));
    return { routed: route.platform, messageId: id };
  } catch (err) {
    throw new HttpsError('internal', `fcm send failed: ${errMessage(err)}`);
  }
});

module.exports = { pushRouter, parseRoute, buildHwNotification, buildFcmMessage, huaweiAccessToken };