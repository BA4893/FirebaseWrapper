import { socket } from '@kit.NetworkKit';
import { FrameHeader } from '../mcs/McsFrames';
import { McsStreamParser } from '../mcs/McsStreamParser';
import { FcmTransport, McsEndpoint, frameConsumer, closeHandler, errorHandler } from './FcmTransport';

/**
 * Pure-ArkTS FCM transport over the platform TLSSocket (persistent TLS connection).
 *
 * This is the zero-native path: works on any NEXT device without the C++ bridge, which
 * makes the publishable OHPM package self-contained. The native NAPI bridge implements
 * the same {@link FcmTransport} contract when compiled into the HAP.
 */
export class TlsSocketTransport implements FcmTransport {
  private tls: socket.TLSSocket | undefined;
  private parser: McsStreamParser | undefined;
  private closeCallback: closeHandler;
  private errorCallback: errorHandler;
  private frameCallback: frameConsumer;
  private open: boolean;

  constructor() {
    this.tls = undefined;
    this.parser = undefined;
    this.closeCallback = () => {
    };
    this.errorCallback = (error: Error) => {
    };
    this.frameCallback = (header: FrameHeader, payload: Uint8Array) => {
    };
    this.open = false;
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
    await this.close();
    const tls: socket.TLSSocket = socket.constructTLSSocketInstance();
    this.tls = tls;
    this.parser = new McsStreamParser((header: FrameHeader, payload: Uint8Array) => {
      if (this.frameCallback !== undefined) {
        this.frameCallback(header, payload);
      }
    }, (reason: string) => {
      if (this.errorCallback !== undefined) {
        this.errorCallback(new Error(`MCS stream corrupt: ${reason}`));
      }
    });

    tls.on('message', (messageInfo) => {
      if (this.parser !== undefined) {
        this.parser.feed(new Uint8Array(messageInfo.message));
      }
    });
    tls.on('close', () => {
      this.open = false;
      if (this.closeCallback !== undefined) {
        this.closeCallback();
      }
    });
    tls.on('error', (err) => {
      if (this.errorCallback !== undefined) {
        this.errorCallback(err as Error);
      }
    });

    const address: socket.NetAddress = { address: endpoint.host, port: endpoint.port } as socket.NetAddress;
    const connectOptions: socket.TLSConnectOptions = {
      address: address,
      secureOptions: {} as socket.TLSSecureOptions
    } as socket.TLSConnectOptions;
    try {
      await tls.connect(connectOptions);
    } catch (err) {
      this.open = false;
      throw err;
    }
    this.open = true;
  }

  async send(frame: Uint8Array): Promise<void> {
    if (this.tls === undefined || !this.open) {
      throw new Error('FCM transport is not connected');
    }
    const buffer: ArrayBuffer = new ArrayBuffer(frame.length);
    const view: Uint8Array = new Uint8Array(buffer);
    for (let i: number = 0; i < frame.length; i++) {
      view[i] = frame[i];
    }
    await this.tls.send(buffer);
  }

  async close(): Promise<void> {
    this.open = false;
    if (this.parser !== undefined) {
      this.parser.reset();
    }
    if (this.tls !== undefined) {
      const current: socket.TLSSocket = this.tls;
      this.tls = undefined;
      try {
        await current.close();
      } catch (err) {
        // already closed
      }
    }
  }
}