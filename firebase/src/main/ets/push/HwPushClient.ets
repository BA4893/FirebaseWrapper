import { HttpTransport, HeaderPair } from '../common/HttpTransport';
import { FirebaseException, FirebaseErrorCode } from '../common/FirebaseError';
import { Json } from '../common/Json';

/**
 * HarmonyOS **Push Kit** REST sender — the downstream replacement for FCM's
 * MCS socket on HarmonyOS devices.
 *
 * Platform role mapping:
 * - APNs (iOS)  → Push Kit (HarmonyOS)
 * - FCM v1 HTTP → Push Kit REST `messages:send`
 * - FCM OAuth service account → Push Kit **OAuth 2.0 access token** obtained
 *   from `oauth-login.cloud.huawei.com/oauth2/v3/token` with
 *   `grant_type=client_credentials&client_id=<appId>&client_secret=<clientSecret>`
 *   (the client secret never leaves the app config in this SDK; in production
 *   route sends through your server/proxy instead — see PROTOCOLS §11.3).
 *
 * "Silent"/data-only delivery: HarmonyOS Push Kit models data messages as a
 * push payload without a notification block (`pushType` DATA); the payload is
 * handed to the app, which may surface it with Notification Kit locally.
 */
export class HwPushClient {
  private http: HttpTransport;
  private appId: string;
  private appSecret: string;
  private sendBase: string;
  private tokenUrl: string;
  private token: string;
  private tokenExpiresAt: number;

  constructor(http: HttpTransport, appId: string, appSecret: string,
    sendBase: string = 'https://push-api.cloud.huawei.com/v1',
    tokenUrl: string = 'https://oauth-login.cloud.huawei.com/oauth2/v3/token') {
    this.http = http;
    this.appId = appId;
    this.appSecret = appSecret;
    this.sendBase = sendBase;
    this.tokenUrl = tokenUrl;
    this.token = '';
    this.tokenExpiresAt = 0;
  }

  /**
   * Sends a notification message to one device token (Push Kit token —
   * the device identifier obtained via `pushService.getToken()`).
   */
  async sendNotification(pushToken: string, title: string, body: string,
    extraData: string = ''): Promise<string> {
    const msg: Object = {};
    const data: Object = {};
    if (extraData.length > 0) {
      data['payload'] = extraData;
    }
    const android: Object = {};
    const notification: Object = {};
    notification['title'] = title;
    notification['body'] = body;
    android['notification'] = notification;
    android['urgency'] = 'HIGH';
    msg['data'] = data;
    msg['android'] = android;
    msg['token'] = [pushToken];
    return this.send(msg, 'hwpush.send');
  }

  /**
   * Sends a data (silent) message — no notification block; the app process
   * receives the payload and can raise a local Notification Kit notification.
   */
  async sendDataMessage(pushToken: string, payload: string): Promise<string> {
    const msg: Object = {};
    const data: Object = {};
    data['payload'] = payload;
    msg['data'] = data;
    msg['token'] = [pushToken];
    return this.send(msg, 'hwpush.data');
  }

  /** Raw v1 message body sender (`{ "message": {...} }`); returns requestId. */
  async sendRaw(message: Object): Promise<string> {
    return this.send(message, 'hwpush.raw');
  }

  /**
   * OAuth 2.0 access token with client-credential caching and proactive
   * refresh 60 s before expiry. Fail-loud: invalid appSecret throws AUTH.
   */
  async accessToken(forceRefresh: boolean = false): Promise<string> {
    if (!forceRefresh && this.token.length > 0 && Date.now() < this.tokenExpiresAt - 60000) {
      return this.token;
    }
    const form: string = `grant_type=client_credentials&client_id=${encodeURIComponent(this.appId)}` +
      `&client_secret=${encodeURIComponent(this.appSecret)}`;
    const headers: Array<HeaderPair> = [new HeaderPair('Content-Type', 'application/x-www-form-urlencoded')];
    const envelope = await this.http.post(this.tokenUrl, form, headers, '');
    if (!envelope.isOk()) {
      throw new FirebaseException(FirebaseErrorCode.AUTH,
        `hwpush oauth: ${Json.firebaseErrorMessage(envelope.text)}`);
    }
    const parsed: Object | undefined = Json.tryParse(envelope.text);
    if (parsed === undefined) {
      throw new FirebaseException(FirebaseErrorCode.AUTH, 'hwpush oauth: malformed response');
    }
    const t: string = Json.string(parsed, 'access_token', '');
    if (t.length === 0) {
      throw new FirebaseException(FirebaseErrorCode.AUTH, 'hwpush oauth: no access_token');
    }
    const expiresIn: number = Json.number(parsed, 'expires_in', 3600);
    this.token = t;
    this.tokenExpiresAt = Date.now() + expiresIn * 1000;
    return this.token;
  }

  private async send(message: Object, op: string): Promise<string> {
    const at: string = await this.accessToken();
    const body: Object = {};
    body['message'] = message;
    const headers: Array<HeaderPair> = [new HeaderPair('Content-Type', 'application/json')];
    const url: string = `${this.sendBase}/${this.appId}/messages:send`;
    const envelope = await this.http.post(url, JSON.stringify(body), headers, `Bearer ${at}`);
    if (!envelope.isOk()) {
      throw FirebaseException.api(op, Json.firebaseErrorMessage(envelope.text));
    }
    const parsed: Object | undefined = Json.tryParse(envelope.text);
    if (parsed === undefined) {
      throw FirebaseException.api(op, 'malformed response');
    }
    return Json.string(parsed, 'requestId', '');
  }
}
