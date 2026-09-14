import { FrameHeader } from './mcs/McsFrames';
import { McsFrameIds, McsFrameCodec } from './mcs/McsFrames';
import { FcmTransport, McsEndpoint, FcmMessage } from './transport/FcmTransport';
import { GcmPacket, GcmMessageType, AndroidCheckin, LoginRequest, LoginResponse, ChannelSelect,
  McsPacket, ClientMessage } from './protobuf/GcmMessages';
import { Codec } from '../common/Codec';
import { EventChannel } from '../common/EventChannel';
import { FirebaseException, FirebaseErrorCode } from '../common/FirebaseError';
import { HttpTransport } from '../common/HttpTransport';
import { Json } from '../common/Json';

export const FCM_EVENT_STATUS: string = 'fcm:status';
export const FCM_EVENT_MESSAGE: string = 'fcm:message';

export const FCM_GATEWAY_HOST: string = 'fcm.googleapis.com';
export const FCM_GATEWAY_PORT: number = 5228;

export enum FcmConnectionStatus {
  IDLE = 0,
  CONNECTING = 1,
  CONNECTED = 2,
  RECONNECTING = 3,
  DISCONNECTED = 4
}

/**
 * Options for the downstream MCS connection.
 */
export class FcmClientOptions {
  /** Downlink email `{project-number}@fcm.googleapis.com`. */
  senderId: string;
  gatewayHost: string;
  gatewayPort: number;
  deviceModel: string;
  /** Legacy server key (upstream only). */
  serverKey: string;
  /** Optional custom proxy for upstream sends. */
  proxyBaseUrl: string;
  /** Heartbeat interval bounds, in ms (4–10 minutes by design). */
  heartbeatMs: number;
  heartbeatMinMs: number;
  heartbeatMaxMs: number;

  constructor(senderId: string, gatewayHost: string, gatewayPort: number, deviceModel: string,
    serverKey: string, proxyBaseUrl: string) {
    this.senderId = senderId;
    this.gatewayHost = gatewayHost;
    this.gatewayPort = gatewayPort;
    this.deviceModel = deviceModel;
    this.serverKey = serverKey;
    this.proxyBaseUrl = proxyBaseUrl;
    this.heartbeatMs = 300000;   // 5 min
    this.heartbeatMinMs = 240000; // 4 min
    this.heartbeatMaxMs = 600000; // 10 min
  }
}

/**
 * Upstream (send) target selector.
 */
export enum UpstreamTarget {
  /** POST to a custom Firebase proxy (holds your Admin credentials). */
  PROXY = 0,
  /** Legacy HTTP /fcm/send with the server key. */
  LEGACY_HTTP = 1
}

/**
 * A message to send to one token or topic.
 */
export class UpstreamMessage {
  targetToken: string;
  title: string;
  body: string;
  /** Optional deep-link / click action URL. */
  clickAction: string;
  payload: string;

  constructor(targetToken: string, title: string, body: string, clickAction: string, payload: string) {
    this.targetToken = targetToken;
    this.title = title;
    this.body = body;
    this.clickAction = clickAction;
    this.payload = payload;
  }
}
/**
 * Firebase Messaging — manual MCS downstream client + HTTP upstream sender.
 *
 * Lifecycle is deterministic client-side:
 *   1. TLS connect (via the configured FcmTransport)
 *   2. WIRE_VERSION / AndroidCheckin
 *   3. LOGIN (SASL X-OAUTH2 ber) → wait LOGIN_RESPONSE
 *   4. CHANNEL_SELECT → wait STREAM_START
 *   5. pump frames; heartbeat 4–10 min; reconnect on ping timeout (backoff 1→60 s)
 */
export class FirebaseMessaging {
  private transport: FcmTransport;
  private http: HttpTransport;
  private options: FcmClientOptions;
  private tokenProvider: fcmTokenProvider;
  private channel: EventChannel;

  private status: FcmConnectionStatus;
  private lastInboundAt: number;
  private heartbeatTimer: number;
  private reconnectTimer: number;
  private backoffMs: number;
  private closing: boolean;
  private messageHandler: fcmMessageHandler;
  private frameWaiter: FrameWaiter | undefined;

  constructor(transport: FcmTransport, http: HttpTransport, options: FcmClientOptions,
    tokenProvider: fcmTokenProvider, channel: EventChannel) {
    this.transport = transport;
    this.http = http;
    this.options = options;
    this.tokenProvider = tokenProvider;
    this.channel = channel;
    this.status = FcmConnectionStatus.IDLE;
    this.lastInboundAt = 0;
    this.heartbeatTimer = 0;
    this.reconnectTimer = 0;
    this.backoffMs = 1000;
    this.closing = false;
    this.messageHandler = (message: FcmMessage) => {
    };
    this.frameWaiter = undefined;

    this.transport.onFrame((header: FrameHeader, payload: Uint8Array) => {
      this.inbound(header, payload);
    });
    this.transport.onClose(() => {
      if (this.status === FcmConnectionStatus.CONNECTED ||
        this.status === FcmConnectionStatus.CONNECTING) {
        this.scheduleReconnect('transport closed');
      }
    });
    this.transport.onError((error: Error) => {
      this.emitStatus(FcmConnectionStatus.DISCONNECTED, error.message);
    });
  }

  get connectionStatus(): FcmConnectionStatus {
    return this.status;
  }

  /**
   * Registers the consumer for decoded downstream messages.
   */
  onMessage(handler: fcmMessageHandler): void {
    this.messageHandler = handler;
  }

  /**
   * Connects (or reconnects) and completes the MCS handshake.
   */
  async connect(): Promise<void> {
    this.closing = false;
    this.status = FcmConnectionStatus.CONNECTING;
    this.emitStatus(this.status, '');
    try {
      const token: string = await this.tokenProvider();
      const ber: string = Codec.base64Encode(
        Codec.utf8(`user=${this.options.senderId}\u0000auth=Bearer ${token}\u0000\u0000`));

      await this.transport.connect(new McsEndpoint(this.options.gatewayHost, this.options.gatewayPort));

      const checkin: GcmPacket = new GcmPacket(GcmMessageType.ANDROID_CHECKIN,
        new AndroidCheckin(2, 'com.openharmony.firebase.1', this.options.deviceModel, this.options.senderId),
        undefined, undefined, undefined);
      await this.sendFrame(McsFrameIds.WIRE_VERSION, checkin.toBytes());

      await this.sendFrame(McsFrameIds.LOGIN, new GcmPacket(GcmMessageType.LOGIN_REQUEST, undefined,
        new LoginRequest(true, this.options.senderId, 0, 2, ber, 1), undefined, undefined).toBytes());

      const login = await this.waitForFrame(McsFrameIds.LOGIN, 10000);
      if (login !== undefined) {
        const packet: GcmPacket = GcmPacket.fromBytes(login);
        if (packet.loginResponse !== undefined && !packet.loginResponse.ok()) {
          throw FirebaseException.api('fcm-login', `login_status=${packet.loginResponse.status}`);
        }
      }

      await this.sendFrame(McsFrameIds.CHANNEL_SELECT,
        new ChannelSelect(true, this.options.senderId, 0, 2, ber).toBytes());
      await this.waitForFrame(McsFrameIds.STREAM_START, 10000);

      this.status = FcmConnectionStatus.CONNECTED;
      this.backoffMs = 1000;
      this.lastInboundAt = Date.now();
      this.emitStatus(this.status, '');
      this.armHeartbeat();
    } catch (err) {
      this.status = FcmConnectionStatus.DISCONNECTED;
      this.emitStatus(this.status, `${err}`);
      throw err;
    }
  }
  private sendFrame(frameId: number, payload: Uint8Array): Promise<void> {
    return this.transport.send(McsFrameCodec.build(frameId, payload));
  }

  /**
   * Routes one complete inbound frame.
   */
  private inbound(header: FrameHeader, payload: Uint8Array): void {
    this.lastInboundAt = Date.now();
    const waiter: FrameWaiter | undefined = this.frameWaiter;
    if (waiter !== undefined && waiter.matches(header.frameId)) {
      this.frameWaiter = undefined;
      waiter.resolve(payload);
    }
    if (header.frameId === McsFrameIds.STREAM_PING) {
      // Echo the ping so the gateway keeps the stream alive both ways.
      this.sendFrame(McsFrameIds.STREAM_PING, new Uint8Array(0)).catch((err: Error) => {
      });
      return;
    }
    if (header.frameId === McsFrameIds.PING_REQUEST) {
      this.sendFrame(McsFrameIds.PING_RESPONSE, new Uint8Array(0)).catch((err: Error) => {
      });
      return;
    }
    if (header.frameId === McsFrameIds.PING_RESPONSE ||
      header.frameId === McsFrameIds.HEARTBEAT_PING) {
      return;
    }
    if (header.frameId === McsFrameIds.MESSAGE_CLEARTEXT) {
      try {
        this.deliverMessage(payload);
      } catch (err) {
        // A corrupt message must not kill the stream.
        this.emitStatus(FcmConnectionStatus.CONNECTED, `message parse: ${err}`);
      }
    }
  }

  private deliverMessage(payload: Uint8Array): void {
    const packet: GcmPacket = GcmPacket.fromBytes(payload);
    if (packet.mcs === undefined) {
      return;
    }
    const mcs: McsPacket = packet.mcs;
    const client: ClientMessage = ClientMessage.fromBytes(mcs.data);
    const message: FcmMessage = new FcmMessage(
      mcs.endpoint,
      mcs.subEndpoint,
      client.appId,
      client.googMsgType,
      client.googMsgSubtype,
      client.payload,
      client.cuid);
    if (this.messageHandler !== undefined) {
      this.messageHandler(message);
    }
    const body: Object = {};
    body['endpoint'] = message.endpoint;
    body['subEndpoint'] = message.subEndpoint;
    body['appId'] = message.appId;
    body['messageType'] = message.messageType;
    body['messageSubtype'] = message.messageSubtype;
    body['payload'] = message.payload;
    this.channel.emit(FCM_EVENT_MESSAGE, body);
  }

  /**
   * Heartbeat: pings every heartbeatMs (adaptive 4–10 min). Any inbound frame
   * resets the schedule; a ping with no traffic for 60 s triggers reconnect.
   */
  private armHeartbeat(): void {
    this.disarmHeartbeat();
    this.heartbeatTimer = setInterval(() => {
      const silentFor: number = Date.now() - this.lastInboundAt;
      if (silentFor > 60000) {
        this.scheduleReconnect('ping timeout');
        return;
      }
      this.sendFrame(McsFrameIds.STREAM_PING, new Uint8Array(0)).catch((err: Error) => {
        this.scheduleReconnect('ping send failed');
      });
    }, this.options.heartbeatMs);
  }

  private disarmHeartbeat(): void {
    if (this.heartbeatTimer !== 0) {
      clearInterval(this.heartbeatTimer);
      this.heartbeatTimer = 0;
    }
  }

  /**
   * Reconnects with exponential backoff (1 s → 60 s cap).
   */
  private scheduleReconnect(reason: string): void {
    if (this.closing) {
      return;
    }
    if (this.reconnectTimer !== 0) {
      return;
    }
    this.disarmHeartbeat();
    this.status = FcmConnectionStatus.RECONNECTING;
    this.emitStatus(this.status, reason);
    this.reconnectTimer = setTimeout(() => {
      this.reconnectTimer = 0;
      this.connect().catch((err: Error) => {
        this.backoffMs = Math.min(this.backoffMs * 2, 60000);
        this.scheduleReconnect(`retry: ${err}`);
      });
    }, this.backoffMs);
  }

  /**
   * Waits for a specific frame id with a timeout; resolves undefined on timeout.
   */
  async waitForFrame(frameId: number, timeoutMs: number): Promise<Uint8Array | undefined> {
    const waiter: FrameWaiter = new FrameWaiter(frameId, timeoutMs);
    this.frameWaiter = waiter;
    return waiter.promise();
  }

  /**
   * Graceful shutdown.
   */
  async disconnect(): Promise<void> {
    this.closing = true;
    this.disarmHeartbeat();
    if (this.reconnectTimer !== 0) {
      clearTimeout(this.reconnectTimer);
      this.reconnectTimer = 0;
    }
    this.status = FcmConnectionStatus.DISCONNECTED;
    this.emitStatus(this.status, '');
    if (this.transport.isOpen()) {
      await this.transport.close();
    }
  }
  /**
   * Sends an upstream message. Defaults to the legacy HTTP endpoint when a
   * server key is configured, otherwise to your custom proxy relay.
   *
   * Background limits (OpenHarmony): the MCS socket is a foreground
   * connection. When the ability moves to background the OS may suspend
   * sockets and timers; expect disconnect + backoff reconnect on return.
   * Use `subscribe()` for topics and persist tokens via Installations FID.
   */
  async sendUpstream(message: UpstreamMessage, target: UpstreamTarget): Promise<void> {
    if (target === UpstreamTarget.PROXY) {
      if (this.options.proxyBaseUrl.length === 0) {
        throw FirebaseException.api('fcm-upstream', 'proxyBaseUrl is not configured');
      }
      const body: Object = {};
      body['to'] = message.targetToken;
      body['title'] = message.title;
      body['body'] = message.body;
      body['click_action'] = message.clickAction;
      if (message.payload.length > 0) {
        body['data'] = JSON.parse(message.payload);
      }
      const envelope = await this.http.post(`${this.options.proxyBaseUrl}/v1/messages:send`,
        JSON.stringify(body), [], '');
      if (!envelope.isOk()) {
        throw FirebaseException.api('fcm-upstream', Json.firebaseErrorMessage(envelope.text));
      }
      return;
    }
    if (this.options.serverKey.length === 0) {
      throw FirebaseException.api('fcm-upstream', 'serverKey is not configured');
    }
    const v1: Object = {};
    const messageObj: Object = {};
    const notification: Object = {};
    notification['title'] = message.title;
    notification['body'] = message.body;
    if (message.clickAction.length > 0) {
      notification['click_action'] = message.clickAction;
    }
    messageObj['notification'] = notification;
    const tokenMap: Object = {};
    tokenMap[message.targetToken] = {};
    messageObj['token'] = tokenMap;
    if (message.payload.length > 0) {
      messageObj['data'] = JSON.parse(message.payload);
    }
    v1['message'] = messageObj;
    const envelope2 = await this.http.post('https://fcm.googleapis.com/fcm/send',
      JSON.stringify(v1), [], `key=${this.options.serverKey}`);
    if (!envelope2.isOk()) {
      throw FirebaseException.api('fcm-upstream', Json.firebaseErrorMessage(envelope2.text));
    }
  }

  private emitStatus(status: FcmConnectionStatus, message: string): void {
    const body: Object = {};
    body['status'] = status as number;
    body['message'] = message;
    this.channel.emit(FCM_EVENT_STATUS, body);
  }

  /**
   * Registration token minted by YOUR PROXY SERVER (holds the FCM Admin key).
   * No `fid:` fake: throws APP_CHECK/AUTH-flavoured API error when no proxy
   * is configured, so callers can never mistake a local stub for a token.
   */
  async registrationToken(fid: string): Promise<string> {
    if (fid.length === 0) {
      throw FirebaseException.api('fcm-token', 'FID is empty; init Installations first');
    }
    if (this.options.proxyBaseUrl.length === 0) {
      throw FirebaseException.api('fcm-token',
        'no proxy configured: FCM registration tokens must be minted by your proxy ' +
        '(Admin SDK); refusing to return a local fid: stub');
    }
    const body: Object = {};
    body['fid'] = fid;
    const envelope = await this.http.post(`${this.options.proxyBaseUrl}/v1/installations:register`,
      JSON.stringify(body), [], '');
    if (!envelope.isOk()) {
      throw FirebaseException.api('fcm-token', Json.firebaseErrorMessage(envelope.text));
    }
    const parsed: Object | undefined = Json.tryParse(envelope.text);
    if (parsed === undefined) {
      throw FirebaseException.api('fcm-token', 'malformed response');
    }
    const token: string = Json.string(parsed, 'token', '');
    if (token.length === 0) {
      throw FirebaseException.api('fcm-token', 'proxy returned no token');
    }
    return token;
  }

  /**
   * Topic subscribe/unsubscribe via the IID endpoint (server key) or the
   * custom proxy relay. Persists nothing locally; callers store topics.
   */
  async subscribe(topic: string, token: string): Promise<void> {
    await this.topicOp('batchAdd', topic, token);
  }

  async unsubscribe(topic: string, token: string): Promise<void> {
    await this.topicOp('batchRemove', topic, token);
  }

  private async topicOp(op: string, topic: string, token: string): Promise<void> {
    if (topic.length === 0 || token.length === 0) {
      throw FirebaseException.api('fcm-topics', 'topic and token required');
    }
    if (this.options.proxyBaseUrl.length > 0) {
      const body: Object = {};
      body['op'] = op;
      body['topic'] = topic;
      body['token'] = token;
      const envelope = await this.http.post(`${this.options.proxyBaseUrl}/v1/topics:${op}`,
        JSON.stringify(body), [], '');
      if (!envelope.isOk()) {
        throw FirebaseException.api('fcm-topics', Json.firebaseErrorMessage(envelope.text));
      }
      return;
    }
    if (this.options.serverKey.length === 0) {
      throw FirebaseException.api('fcm-topics', 'proxyBaseUrl or serverKey required');
    }
    const v1: Object = {};
    v1['to'] = `/topics/${topic}`;
    v1['registration_tokens'] = [token];
    const envelope2 = await this.http.post('https://iid.googleapis.com/iid/v1:batchAdd',
      JSON.stringify(v1), [], `key=${this.options.serverKey}`);
    if (!envelope2.isOk()) {
      throw FirebaseException.api('fcm-topics', Json.firebaseErrorMessage(envelope2.text));
    }
  }
}

/**
 * One-shot awaitable for a specific inbound frame id.
 */
class FrameWaiter {
  private frameId: number;
  private resolved: boolean;
  private value: Uint8Array | undefined;
  private callback: waiterCallback;
  private timer: number;

  constructor(frameId: number, timeoutMs: number) {
    this.frameId = frameId;
    this.resolved = false;
    this.value = undefined;
    this.callback = (data: Uint8Array | undefined) => {
    };
    this.timer = setTimeout(() => {
      this.finish(undefined);
    }, timeoutMs);
  }

  matches(frameId: number): boolean {
    return !this.resolved && frameId === this.frameId;
  }

  resolve(data: Uint8Array): void {
    this.finish(data);
  }

  promise(): Promise<Uint8Array | undefined> {
    return new Promise<Uint8Array | undefined>((resolve: (value: Uint8Array | undefined) => void) => {
      this.callback = resolve;
      if (this.resolved) {
        resolve(this.value);
      }
    });
  }

  private finish(data: Uint8Array | undefined): void {
    if (this.resolved) {
      return;
    }
    this.resolved = true;
    this.value = data;
    if (this.timer !== 0) {
      clearTimeout(this.timer);
      this.timer = 0;
    }
    this.callback(data);
  }
}

export type fcmTokenProvider = () => Promise<string>;
export type fcmMessageHandler = (message: FcmMessage) => void;
export type waiterCallback = (data: Uint8Array | undefined) => void;