/**
 * One decoded protobuf field.
 */
export class ProtobufField {
  field: number;
  wireType: number;
  /** Populated for wireType 0 (and 1/5 which we treat as integers). */
  varintValue: number;
  /** Populated for wireType 2. */
  bytesValue: Uint8Array;

  constructor(field: number, wireType: number, varintValue: number, bytesValue: Uint8Array) {
    this.field = field;
    this.wireType = wireType;
    this.varintValue = varintValue;
    this.bytesValue = bytesValue;
  }

  stringValue(): string {
    const decoder: TextDecoder = new TextDecoder();
    return decoder.decode(this.bytesValue);
  }
}

/**
 * Minimal protobuf wire decoder (varint + length-delimited fields),
 * the inverse of {@link ProtobufWriter}.
 */
export class ProtobufReader {
  static readonly WIRE_VARINT: number = 0;
  static readonly WIRE_64BIT: number = 1;
  static readonly WIRE_LEN: number = 2;
  static readonly WIRE_32BIT: number = 5;

  /**
   * Decodes every field of a message.
   */
  static decode(data: Uint8Array): Array<ProtobufField> {
    const out: Array<ProtobufField> = new Array<ProtobufField>();
    let pos: number = 0;
    while (pos < data.length) {
      const key: DecodeResult = ProtobufReader.varint(data, pos);
      if (key.overflow) {
        break;
      }
      pos = key.next;
      const field: number = key.value >> 3;
      const wire: number = key.value & 0x07;
      if (wire === ProtobufReader.WIRE_VARINT || wire === ProtobufReader.WIRE_64BIT ||
        wire === ProtobufReader.WIRE_32BIT) {
        const v: DecodeResult = ProtobufReader.varint(data, pos);
        pos = v.next;
        out.push(new ProtobufField(field, wire, v.value, new Uint8Array(0)));
      } else if (wire === ProtobufReader.WIRE_LEN) {
        const len: DecodeResult = ProtobufReader.varint(data, pos);
        pos = len.next;
        const end: number = pos + len.value;
        if (end > data.length || end < pos) {
          break;
        }
        const slice: Uint8Array = new Uint8Array(len.value);
        for (let i: number = 0; i < len.value; i++) {
          slice[i] = data[pos + i];
        }
        pos = end;
        out.push(new ProtobufField(field, wire, 0, slice));
      } else {
        // Unknown wire types (groups) — stop rather than misalign the stream.
        break;
      }
    }
    return out;
  }

  private static varint(data: Uint8Array, start: number): DecodeResult {
    let value: number = 0;
    let shift: number = 0;
    let pos: number = start;
    while (pos < data.length && shift < 64) {
      const chunk: number = data[pos];
      value |= (chunk & 0x7f) << shift;
      pos = pos + 1;
      if ((chunk & 0x80) === 0) {
        return new DecodeResult(value, pos, false);
      }
      shift = shift + 7;
    }
    return new DecodeResult(value, pos, true);
  }
}

class DecodeResult {
  value: number;
  next: number;
  overflow: boolean;

  constructor(value: number, next: number, overflow: boolean) {
    this.value = value;
    this.next = next;
    this.overflow = overflow;
  }
}