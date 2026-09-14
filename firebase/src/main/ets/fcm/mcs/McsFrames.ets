/**
 * MCS wire frame constants and codec.
 *
 * Wire format (documented in docs/PROTOCOLS.md §3.3):
 *   [uint32 BE payloadLen] [uint16 LE frameId] [payload]
 * `payloadLen` includes the 2-byte frame id. Max frame is 64 KiB.
 */
export class McsFrameIds {
  static readonly WIRE_VERSION: number = 3;
  static readonly LOGIN: number = 5;
  static readonly CHANNEL_SELECT: number = 6;
  static readonly STREAM_PING: number = 7;
  static readonly STREAM_START: number = 8;
  static readonly MESSAGE_CLEARTEXT: number = 11;
  static readonly HEARTBEAT_PING: number = 12;
  static readonly PING_REQUEST: number = 13;
  static readonly PING_RESPONSE: number = 14;
}

export const MCS_MAX_FRAME: number = 65536;
export const MCS_HEADER_BYTES: number = 6;

/**
 * Parsed frame header. `payloadLength` includes the 2-byte frame id.
 */
export class FrameHeader {
  frameId: number;
  /** 0..65536 — total payload bytes on the wire (including frame id). */
  payloadLength: number;

  constructor(frameId: number, payloadLength: number) {
    this.frameId = frameId;
    this.payloadLength = payloadLength;
  }

  /** Bytes of frame payload (frame id stripped). */
  payloadBytes(): number {
    return this.payloadLength - 2;
  }
}

/**
 * Builds/parses complete MCS frames.
 */
export class McsFrameCodec {
  /**
   * Serializes a frame: [payloadLen BE][frameId LE][payload].
   */
  static build(frameId: number, payload: Uint8Array): Uint8Array {
    const total: number = payload.length + 2;
    const out: Uint8Array = new Uint8Array(total + 4);
    out[0] = (total >> 24) & 0xff;
    out[1] = (total >> 16) & 0xff;
    out[2] = (total >> 8) & 0xff;
    out[3] = total & 0xff;
    out[4] = frameId & 0xff;
    out[5] = (frameId >> 8) & 0xff;
    for (let i: number = 0; i < payload.length; i++) {
      out[6 + i] = payload[i];
    }
    return out;
  }

  /**
   * Reads a header if a complete one is buffered; null otherwise.
   */
  static tryHeader(buf: Uint8Array): FrameHeader | undefined {
    if (buf.length < 4) {
      return undefined;
    }
    const payloadLength: number = ((buf[0] & 0xff) << 24) | ((buf[1] & 0xff) << 16) |
      ((buf[2] & 0xff) << 8) | (buf[3] & 0xff);
    if (payloadLength > MCS_MAX_FRAME) {
      return undefined;
    }
    if (buf.length < 4 + payloadLength) {
      return undefined;
    }
    const frameId: number = ((buf[5] & 0xff) << 8) | (buf[4] & 0xff);
    return new FrameHeader(frameId, payloadLength);
  }

  /**
   * Extracts the payload (frame id stripped) from a buffer holding a full frame.
   */
  static payload(buf: Uint8Array, header: FrameHeader): Uint8Array {
    const total: number = 4 + header.payloadLength;
    const payloadBytes: number = header.payloadLength - 2;
    const out: Uint8Array = new Uint8Array(payloadBytes);
    for (let i: number = 0; i < payloadBytes; i++) {
      out[i] = buf[6 + i];
    }
    return out;
  }
}