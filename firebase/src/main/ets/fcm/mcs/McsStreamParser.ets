import { McsFrameCodec, FrameHeader } from './McsFrames';

/**
 * Reassembles a continuous byte stream (as delivered by a TLS socket) into
 * complete MCS frames. Transport-independent: both the ArkTS TLSSocket transport
 * and the native bridge feed raw chunks here.
 */
export class McsStreamParser {
  private buffer: Array<number>;
  private onFrame: frameHandler;
  private onCorrupt: corruptHandler;

  constructor(onFrame: frameHandler, onCorrupt: corruptHandler) {
    this.buffer = new Array<number>();
    this.onFrame = onFrame;
    this.onCorrupt = onCorrupt;
  }

  /**
   * Feeds a chunk of raw bytes (e.g. from a socket 'message' event).
   */
  feed(chunk: Uint8Array): void {
    for (let i: number = 0; i < chunk.length; i++) {
      this.buffer.push(chunk[i]);
    }
    this.drain();
  }

  reset(): void {
    this.buffer.splice(0, this.buffer.length);
  }

  private drain(): void {
    while (true) {
      if (this.buffer.length < 4) {
        return;
      }
      const view: Uint8Array = McsStreamParser.toBytes(this.buffer);
      const header: FrameHeader | undefined = McsFrameCodec.tryHeader(view);
      if (header === undefined) {
        // Incomplete header or corrupt length — wait for more bytes.
        return;
      }
      const total: number = 4 + header.payloadLength;
      if (this.buffer.length < total) {
        return;
      }
      const frame: Uint8Array = new Uint8Array(header.payloadLength + 4);
      for (let i: number = 0; i < total; i++) {
        frame[i] = this.buffer[i];
      }
      this.buffer.splice(0, total);
      this.onFrame(header, McsFrameCodec.payload(frame, header));
    }
  }

  private static toBytes(src: Array<number>): Uint8Array {
    const out: Uint8Array = new Uint8Array(src.length);
    for (let i: number = 0; i < src.length; i++) {
      out[i] = src[i];
    }
    return out;
  }
}

export type frameHandler = (header: FrameHeader, payload: Uint8Array) => void;
export type corruptHandler = (reason: string) => void;