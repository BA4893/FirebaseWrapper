import { util } from '@kit.ArkTS';

/**
 * Pure-ArkTS codec helpers shared across the SDK.
 * Uses the platform Base64Helper under the hood, so the module is dependency-free.
 */
export class Codec {
  /**
   * Standard base64 (with padding).
   */
  static base64Encode(data: Uint8Array): string {
    return util.Base64Helper.encodeToStringSync(data);
  }

  /**
   * base64url (RFC 4648 §5, no padding) — used for Firebase id-token JWT segments
   * and App Check challenge signatures (arbitrary binary → all occurrences of
   * `+`/`/` must be mapped, not just the first).
   */
  static base64UrlEncode(data: Uint8Array): string {
    const b64: string = Codec.base64Encode(data);
    const urlSafe: string = b64.split('+').join('-').split('/').join('_');
    const pad: number = urlSafe.indexOf('=');
    if (pad === -1) {
      return urlSafe;
    }
    return urlSafe.substring(0, pad);
  }

  /**
   * RFC 4648 base64url decode tolerant of missing padding.
   */
  static base64UrlDecode(segment: string): Uint8Array {
    const urlSafe: string = segment.split('-').join('+').split('_').join('/');
    const rem: number = urlSafe.length % 4;
    let padded: string = urlSafe;
    if (rem > 0) {
      let pad: string = '';
      for (let i: number = 0; i < 4 - rem; i++) {
        pad = pad.concat('=');
      }
      padded = padded.concat(pad);
    }
    return util.Base64Helper.decodeSync(padded);
  }

  /**
   * Splits a JWT (header.payload.signature).
   */
  static splitJwt(token: string): Array<string> {
    return token.split('.');
  }

  static utf8(text: string): Uint8Array {
    const encoder: TextEncoder = new TextEncoder();
    return encoder.encode(text);
  }

  /**
   * Derives a stable hex digest for an input (used for hashing diagnostics /
   * local cache keys). Deterministic across runs, intended for non-security keys.
   */
  static hex(bytes: Uint8Array): string {
    const out: Array<string> = new Array<string>();
    for (let i: number = 0; i < bytes.length; i++) {
      const h: string = bytes[i].toString(16);
      if (bytes[i] < 16) {
        out.push(`0${h}`);
      } else {
        out.push(h);
      }
    }
    return out.join('');
  }
}