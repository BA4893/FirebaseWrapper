import { FrameHeader } from '../mcs/McsFrames';
import { FcmTransport, McsEndpoint, frameConsumer, closeHandler, errorHandler } from './FcmTransport';

/**
 * Duck-typed handle into the optional native NAPI C++ bridge (`firebase_native/`).
 *
 * The pure-ArkTS SDK never imports the native plugin directly (it is compiled into the
 * HAP only when wanted). Apps that compiled the bridge pass an object conforming to
 * this interface into {@link NapiBridgeTransport}.
 */
export interface FcmNativeBridge {
  connect(host: string, port: number): Promise<void>;
  sendBytes(buffer: ArrayBuffer): Promise<void>;
  close(): Promise<void>;
  isOpen(): boolean;
  /** Registers a callback receiving JSON events from the C++ core. */
  setOnMessage(handler: nativeEventHandler): void;
}

/**
 * Event emitted by the native core. The C++ layer owns socket + TLS and can include a
 * base64 frame payload (`payloadB64`) and/or its own protobuf-decoded JSON view
 * (`decoded`). When `payloadB64` is absent on control frames, an empty payload is used.
 */
export class NativeFrameEvent {
  frameId: number;
  payloadB64: string;
  decoded: string;

  constructor(frameId: number, payloadB64: string, decoded: string) {
    this.frameId = frameId;
    this.payloadB64 = payloadB64;
    this.decoded = decoded;
  }
}

/**
 * Transport adapter that bridges native JSON events back into the SDK frame pipeline.
 * The ArkTS side re-uses the identical GcmPacket codec, so client behavior is
 * transport-independent.
 */
export class NapiBridgeTransport implements FcmTransport {
  private bridge: FcmNativeBridge;
  private open: boolean;
  private frameCallback: frameConsumer;
  private closeCallback: closeHandler;
  private errorCallback: errorHandler;

  constructor(bridge: FcmNativeBridge) {
    this.bridge = bridge;
    this.open = false;
    this.frameCallback = (header: FrameHeader, payload: Uint8Array) => {
    };
    this.closeCallback = () => {
    };
    this.errorCallback = (error: Error) => {
    };
  }

  onFrame(handler: frameConsumer): void {
    this.frameCallback = handler;
  }

  onClose(handler: closeHandler): void {
    this.closeCallback = handler;
  }

  onError(handler: errorHandler): void {
    this.errorCallback = handler;
  }

  isOpen(): boolean {
    return this.open;
  }

  async connect(endpoint: McsEndpoint): Promise<void> {
    // The native core emits frames/close/error through the single message callback.
    this.bridge.setOnMessage((text: string) => {
      this.inbound(text);
    });
    await this.bridge.connect(endpoint.host, endpoint.port);
    this.open = true;
  }

  async send(frame: Uint8Array): Promise<void> {
    if (!this.open) {
      throw new Error('FCM transport is not connected');
    }
    const buffer: ArrayBuffer = new ArrayBuffer(frame.length);
    const view: Uint8Array = new Uint8Array(buffer);
    for (let i: number = 0; i < frame.length; i++) {
      view[i] = frame[i];
    }
    await this.bridge.sendBytes(buffer);
  }

  async close(): Promise<void> {
    this.open = false;
    try {
      await this.bridge.close();
    } catch (err) {
      // already closed
    }
  }

  private inbound(text: string): void {
    let parsed: Object | undefined;
    try {
      parsed = JSON.parse(text);
    } catch (err) {
      this.errorCallback(new Error(`Native frame parse failed: ${text}`));
      return;
    }
    if (parsed === undefined) {
      return;
    }
    const kind: string = parsed['kind'] as string;
    if (kind === 'close') {
      this.open = false;
      this.closeCallback();
      return;
    }
    const frameId: number = parsed['id'] as number;
    const payloadB64: string = parsed['payload_b64'] as string;
    let payload: Uint8Array = new Uint8Array(0);
    if (payloadB64.length > 0) {
      payload = NapiBridgeTransport.base64Decode(payloadB64);
    }
    const header: FrameHeader = new FrameHeader(frameId, payload.length + 2);
    if (this.frameCallback !== undefined) {
      this.frameCallback(header, payload);
    }
  }

  private static base64Decode(text: string): Uint8Array {
    const fromB64 = new ConsumerBridge();
    return fromB64.decode(text);
  }
}

import { util } from '@kit.ArkTS';

class ConsumerBridge {
  decode(text: string): Uint8Array {
    return util.Base64Helper.decodeSync(text);
  }
}

export type nativeEventHandler = (text: string) => void;