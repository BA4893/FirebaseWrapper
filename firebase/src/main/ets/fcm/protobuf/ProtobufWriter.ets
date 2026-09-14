/**
 * Minimal protobuf wire encoder (varint + length-delimited fields).
 *
 * Implements exactly the encoding subset required by the FCM downstream protocol:
 *   wire type 0 — varint
 *   wire type 2 — length-delimited bytes / strings / nested messages
 *
 * Field keys are `(fieldNumber << 3) | wireType`, encoded as base-128 varints.
 */
export class ProtobufWriter {
  private bytes: Array<number>;

  constructor() {
    this.bytes = new Array<number>();
  }

  size(): number {
    return this.bytes.length;
  }

  /** Appends a raw varint (without a field key). */
  varint(value: number): void {
    let v: number = value;
    while (v >= 0x80) {
      this.bytes.push((v & 0x7f) | 0x80);
      v = v >> 7;
    }
    this.bytes.push(v);
  }

  fieldVarint(field: number, value: number): void {
    this.varint((field << 3) | 0);
    this.varint(value);
  }

  fieldBoolean(field: number, value: boolean): void {
    this.fieldVarint(field, value ? 1 : 0);
  }

  fieldBytes(field: number, data: Uint8Array): void {
    this.varint((field << 3) | 2);
    this.varint(data.length);
    for (let i: number = 0; i < data.length; i++) {
      this.bytes.push(data[i]);
    }
  }

  fieldString(field: number, text: string): void {
    const encoder: TextEncoder = new TextEncoder();
    this.fieldBytes(field, encoder.encode(text));
  }

  fieldMessage(field: number, nested: Uint8Array): void {
    this.fieldBytes(field, nested);
  }

  /**
   * Materializes the accumulated bytes. Note: returns a copy so the writer can
   * be reused; the copy cost is bounded by the 64 KiB MCS frame limit.
   */
  toUint8Array(): Uint8Array {
    const out: Uint8Array = new Uint8Array(this.bytes.length);
    for (let i: number = 0; i < this.bytes.length; i++) {
      out[i] = this.bytes[i];
    }
    return out;
  }
}