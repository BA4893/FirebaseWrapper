import { FrameHeader } from '../mcs/McsFrames';

/**
 * MCS gateway endpoint (host + port).
 */
export class McsEndpoint {
  host: string;
  port: number;

  constructor(host: string, port: number) {
    this.host = host;
    this.port = port;
  }
}

/**
 * A fully decoded downstream Firebase message.
 */
export class FcmMessage {
  endpoint: string;
  subEndpoint: string;
  appId: string;
  /** goog_msg_type (e.g. "com.google.android.gcm.msg.object"). */
  messageType: string;
  messageSubtype: string;
  /** Opaque payload from your app server. */
  payload: string;
  /** Raw ack id to echo back when acking a channel. */
  ackId: number;

  constructor(endpoint: string, subEndpoint: string, appId: string, messageType: string,
    messageSubtype: string, payload: string, ackId: number) {
    this.endpoint = endpoint;
    this.subEndpoint = subEndpoint;
    this.appId = appId;
    this.messageType = messageType;
    this.messageSubtype = messageSubtype;
    this.payload = payload;
    this.ackId = ackId;
  }

  channelName(): string {
    if (this.endpoint.indexOf('/') >= 0) {
      return this.endpoint.substring(0, this.endpoint.indexOf('/'));
    }
    return this.endpoint;
  }
}

/**
 * Low-level MCS frame transport contract.
 *
 * Implementations own the raw byte channel and deliver *complete frames* via
 * {@link onFrame}. Keep-alive and reconnect policy live in the client.
 */
export interface FcmTransport {
  /**
   * Opens the persistent socket and completes the TLS handshake.
   */
  connect(endpoint: McsEndpoint): Promise<void>;

  /**
   * Sends one serialized frame (see McsFrameCodec.build).
   */
  send(frame: Uint8Array): Promise<void>;

  /**
   * Registers handlers. Called once by the client before connect.
   */
  onFrame(handler: frameConsumer): void;
  onClose(handler: closeHandler): void;
  onError(handler: errorHandler): void;

  /**
   * True after a successful connect and before close/reconnect.
   */
  isOpen(): boolean;

  close(): Promise<void>;
}

export type frameConsumer = (header: FrameHeader, payload: Uint8Array) => void;
export type closeHandler = () => void;
export type errorHandler = (error: Error) => void;