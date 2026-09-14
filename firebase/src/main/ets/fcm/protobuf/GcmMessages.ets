import { ProtobufWriter } from './ProtobufWriter';
import { ProtobufReader, ProtobufField } from './ProtobufReader';

// Field numbers follow the community-documented FCM downstream schema (see
// docs/PROTOCOLS.md §3); every number is a toggle in one place.

/**
 * GcmPacket message_type values carried inside our outbound frames.
 */
export enum GcmMessageType {
  ANDROID_CHECKIN = 2,
  LOGIN_REQUEST = 4,
  LOGIN_RESPONSE = 5,
  MCS_PACKET = 6,
  CHANNEL_SELECT = 7
}

/**
 * AndroidCheckin — the C2DM-era device registration blurb bundled into the
 * WIRE_VERSION frame (field numbers from the public proto).
 */
export class AndroidCheckin {
  type: number;
  chromeVersion: string;
  deviceModel: string;
  deviceId: string;

  constructor(type: number, chromeVersion: string, deviceModel: string, deviceId: string) {
    this.type = type;
    this.chromeVersion = chromeVersion;
    this.deviceModel = deviceModel;
    this.deviceId = deviceId;
  }

  toBytes(): Uint8Array {
    const w: ProtobufWriter = new ProtobufWriter();
    if (this.type !== 0) {
      w.fieldVarint(1, this.type);
    }
    if (this.chromeVersion.length > 0) {
      w.fieldString(2, this.chromeVersion);
    }
    if (this.deviceModel.length > 0) {
      w.fieldString(3, this.deviceModel);
    }
    if (this.deviceId.length > 0) {
      w.fieldString(7, this.deviceId);
    }
    return w.toUint8Array();
  }

  static fromBytes(data: Uint8Array): AndroidCheckin {
    const fields: Array<ProtobufField> = ProtobufReader.decode(data);
    return new AndroidCheckin(
      GcmMessages.fieldVarint(fields, 1, 0),
      GcmMessages.fieldString(fields, 2),
      GcmMessages.fieldString(fields, 3),
      GcmMessages.fieldString(fields, 7));
  }
}

/**
 * LoginRequest payload for the LOGIN frame; embedded in GcmPacket.login_request.
 */
export class LoginRequest {
  autoRetry: boolean;
  /** Downlink email `{project-number}@fcm.googleapis.com`. */
  deviceId: string;
  subtype: number;
  authType: number;
  /** base64(`user=...\0auth=Bearer <idToken>\0\0`). */
  encodedAuth: string;
  deviceLevel: number;

  constructor(autoRetry: boolean, deviceId: string, subtype: number, authType: number,
    encodedAuth: string, deviceLevel: number) {
    this.autoRetry = autoRetry;
    this.deviceId = deviceId;
    this.subtype = subtype;
    this.authType = authType;
    this.encodedAuth = encodedAuth;
    this.deviceLevel = deviceLevel;
  }

  toBytes(): Uint8Array {
    const w: ProtobufWriter = new ProtobufWriter();
    w.fieldBoolean(1, this.autoRetry);
    w.fieldString(2, this.deviceId);
    w.fieldVarint(3, this.subtype);
    w.fieldVarint(4, this.authType);
    w.fieldString(5, this.encodedAuth);
    w.fieldVarint(6, this.deviceLevel);
    return w.toUint8Array();
  }

  static fromBytes(data: Uint8Array): LoginRequest {
    const fields: Array<ProtobufField> = ProtobufReader.decode(data);
    return new LoginRequest(
      GcmMessages.fieldBoolean(fields, 1),
      GcmMessages.fieldString(fields, 2),
      GcmMessages.fieldVarint(fields, 3, 0),
      GcmMessages.fieldVarint(fields, 4, 0),
      GcmMessages.fieldString(fields, 5),
      GcmMessages.fieldVarint(fields, 6, 0));
  }
}

/**
 * Server verdict for the LOGIN frame.
 */
export class LoginResponse {
  status: number;
  retryDelay: number;

  constructor(status: number, retryDelay: number) {
    this.status = status;
    this.retryDelay = retryDelay;
  }

  ok(): boolean {
    return this.status === 0;
  }

  static fromBytes(data: Uint8Array): LoginResponse {
    const fields: Array<ProtobufField> = ProtobufReader.decode(data);
    return new LoginResponse(
      GcmMessages.fieldVarint(fields, 1, 0),
      GcmMessages.fieldVarint(fields, 2, 0));
  }
}

/**
 * Envelope for downstream pushes (`MCS_PACKET` in the data frame).
 */
export class McsPacket {
  endpoint: string;
  subEndpoint: string;
  data: Uint8Array;
  ack: number;

  constructor(endpoint: string, subEndpoint: string, data: Uint8Array, ack: number) {
    this.endpoint = endpoint;
    this.subEndpoint = subEndpoint;
    this.data = data;
    this.ack = ack;
  }

  toBytesRaw(): Uint8Array {
    const w: ProtobufWriter = new ProtobufWriter();
    if (this.endpoint.length > 0) {
      w.fieldString(1, this.endpoint);
    }
    if (this.subEndpoint.length > 0) {
      w.fieldString(2, this.subEndpoint);
    }
    w.fieldBytes(3, this.data);
    if (this.ack !== 0) {
      w.fieldVarint(4, this.ack);
    }
    return w.toUint8Array();
  }

  static fromBytes(data: Uint8Array): McsPacket {
    const fields: Array<ProtobufField> = ProtobufReader.decode(data);
    return new McsPacket(
      GcmMessages.fieldString(fields, 1),
      GcmMessages.fieldString(fields, 2),
      GcmMessages.fieldBytes(fields, 3),
      GcmMessages.fieldVarint(fields, 4, 0));
  }
}

/**
 * The inner Firebase message carried by {@link McsPacket} data.
 */
export class ClientMessage {
  cuid: number;
  appId: string;
  googMsgType: string;
  googMsgSubtype: string;
  /** Usually a JSON/URL-encoded opaque payload from your app server. */
  payload: string;
  expiration: string;

  constructor(cuid: number, appId: string, googMsgType: string, googMsgSubtype: string,
    payload: string, expiration: string) {
    this.cuid = cuid;
    this.appId = appId;
    this.googMsgType = googMsgType;
    this.googMsgSubtype = googMsgSubtype;
    this.payload = payload;
    this.expiration = expiration;
  }

  static fromBytes(data: Uint8Array): ClientMessage {
    const fields: Array<ProtobufField> = ProtobufReader.decode(data);
    return new ClientMessage(
      GcmMessages.fieldVarint(fields, 1, 0),
      GcmMessages.fieldString(fields, 2),
      GcmMessages.fieldString(fields, 3),
      GcmMessages.fieldString(fields, 4),
      GcmMessages.fieldString(fields, 5),
      GcmMessages.fieldString(fields, 6));
  }
}
/**
 * Channel-select handshake frame payload.
 */
export class ChannelSelect {
  autoRetry: boolean;
  deviceId: string;
  subtype: number;
  authType: number;
  encodedAuth: string;

  constructor(autoRetry: boolean, deviceId: string, subtype: number, authType: number, encodedAuth: string) {
    this.autoRetry = autoRetry;
    this.deviceId = deviceId;
    this.subtype = subtype;
    this.authType = authType;
    this.encodedAuth = encodedAuth;
  }

  toBytes(): Uint8Array {
    const w: ProtobufWriter = new ProtobufWriter();
    w.fieldBoolean(1, this.autoRetry);
    w.fieldString(2, this.deviceId);
    w.fieldVarint(3, this.subtype);
    w.fieldVarint(4, this.authType);
    w.fieldString(5, this.encodedAuth);
    return w.toUint8Array();
  }
}

/**
 * The overall GcmPacket envelope wrapping every message we serialize/parse.
 */
export class GcmPacket {
  messageType: number;
  androidCheckin: AndroidCheckin | undefined;
  loginRequest: LoginRequest | undefined;
  loginResponse: LoginResponse | undefined;
  mcs: McsPacket | undefined;

  constructor(messageType: number, androidCheckin: AndroidCheckin | undefined,
    loginRequest: LoginRequest | undefined, loginResponse: LoginResponse | undefined,
    mcs: McsPacket | undefined) {
    this.messageType = messageType;
    this.androidCheckin = androidCheckin;
    this.loginRequest = loginRequest;
    this.loginResponse = loginResponse;
    this.mcs = mcs;
  }

  toBytes(): Uint8Array {
    const w: ProtobufWriter = new ProtobufWriter();
    w.fieldVarint(1, this.messageType);
    if (this.androidCheckin !== undefined) {
      w.fieldMessage(2, this.androidCheckin.toBytes());
    }
    if (this.loginRequest !== undefined) {
      w.fieldMessage(3, this.loginRequest.toBytes());
    }
    if (this.loginResponse !== undefined) {
      w.fieldMessage(4, this.loginResponse.toBytes());
    }
    if (this.mcs !== undefined) {
      w.fieldMessage(5, this.mcs.toBytesRaw());
    }
    return w.toUint8Array();
  }

  static fromBytes(data: Uint8Array): GcmPacket {
    const fields: Array<ProtobufField> = ProtobufReader.decode(data);
    let messageType: number = 0;
    let checkin: AndroidCheckin | undefined = undefined;
    let login: LoginRequest | undefined = undefined;
    let loginResponse: LoginResponse | undefined = undefined;
    let mcs: McsPacket | undefined = undefined;
    for (let i: number = 0; i < fields.length; i++) {
      const field: ProtobufField = fields[i];
      if (field.field === 1) {
        messageType = field.varintValue;
      } else if (field.field === 2) {
        checkin = AndroidCheckin.fromBytes(field.bytesValue);
      } else if (field.field === 3) {
        login = LoginRequest.fromBytes(field.bytesValue);
      } else if (field.field === 4) {
        loginResponse = LoginResponse.fromBytes(field.bytesValue);
      } else if (field.field === 5) {
        mcs = McsPacket.fromBytes(field.bytesValue);
      }
    }
    return new GcmPacket(messageType, checkin, login, loginResponse, mcs);
  }
}

/**
 * Internal shared field helper (kept private to this module).
 */
class GcmMessages {
  static fieldVarint(fields: Array<ProtobufField>, field: number, fallback: number): number {
    for (let i: number = 0; i < fields.length; i++) {
      if (fields[i].field === field) {
        return fields[i].varintValue;
      }
    }
    return fallback;
  }

  static fieldBoolean(fields: Array<ProtobufField>, field: number): boolean {
    return GcmMessages.fieldVarint(fields, field, 0) !== 0;
  }

  static fieldString(fields: Array<ProtobufField>, field: number): string {
    for (let i: number = 0; i < fields.length; i++) {
      if (fields[i].field === field && fields[i].wireType === ProtobufReader.WIRE_LEN) {
        return fields[i].stringValue();
      }
    }
    return '';
  }

  static fieldBytes(fields: Array<ProtobufField>, field: number): Uint8Array {
    for (let i: number = 0; i < fields.length; i++) {
      if (fields[i].field === field && fields[i].wireType === ProtobufReader.WIRE_LEN) {
        return fields[i].bytesValue;
      }
    }
    return new Uint8Array(0);
  }
}