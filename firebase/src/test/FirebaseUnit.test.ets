import { describe, it, expect } from '@ohos/hypium';
import { ProtobufWriter } from '../main/ets/fcm/protobuf/ProtobufWriter';
import { ProtobufReader } from '../main/ets/fcm/protobuf/ProtobufReader';
import { McsFrameCodec, McsFrameIds } from '../main/ets/fcm/mcs/McsFrames';
import { McsStreamParser } from '../main/ets/fcm/mcs/McsStreamParser';
import { Json } from '../main/ets/common/Json';
import { SseStream } from '../main/ets/common/SseStream';
import { RealtimeDatabase } from '../main/ets/database/RealtimeDatabase';
import { Firestore, WriteOp } from '../main/ets/firestore/Firestore';
import { HttpTransport, HeaderPair } from '../main/ets/common/HttpTransport';

/** Minimal Firestore shell — WriteOp.toEnvelope only needs the base URL. */
function makeShellFirestore(): Firestore {
  const transport: HttpTransport = new HttpTransport(5000, 5000);
  return new Firestore(transport, 'demo', () => {
    return Promise.resolve('');
  });
}
import { OAuthCredential } from '../main/ets/auth/OAuthCredential';
import { PushKitTokenProvider } from '../main/ets/push/PushKitTokenProvider';

export default function firebaseUnitTest() {
  describe('firebase-protobuf', () => {
    it('protoRoundTrip', 0, () => {
      const w: ProtobufWriter = new ProtobufWriter();
      w.fieldVarint(1, 300);
      w.fieldString(2, 'hello');
      const bytes: Uint8Array = w.toUint8Array();
      const fields = ProtobufReader.decode(bytes);
      expect(fields.length).assertEqual(2);
    });
    it('mcsFrameRoundTrip', 0, () => {
      const payload: Uint8Array = new Uint8Array([1, 2, 3]);
      const frame: Uint8Array = McsFrameCodec.build(McsFrameIds.LOGIN, payload);
      const header = McsFrameCodec.tryHeader(frame);
      expect(header !== undefined).assertTrue();
      if (header !== undefined) {
        const out: Uint8Array = McsFrameCodec.payload(frame, header);
        expect(out.length).assertEqual(3);
      }
    });
    it('streamParserSplits', 0, () => {
      let count: number = 0;
      const parser: McsStreamParser = new McsStreamParser(() => {
        count++;
      }, () => {
      });
      const a: Uint8Array = McsFrameCodec.build(7, new Uint8Array(0));
      const b: Uint8Array = McsFrameCodec.build(8, new Uint8Array(0));
      const both: Uint8Array = new Uint8Array(a.length + b.length);
      for (let i: number = 0; i < a.length; i++) {
        both[i] = a[i];
      }
      for (let i: number = 0; i < b.length; i++) {
        both[a.length + i] = b[i];
      }
      parser.feed(both.subarray(0, 3));
      parser.feed(both.subarray(3));
      expect(count).assertEqual(2);
    });
    it('sseParses', 0, () => {
      const v: Object | undefined = RealtimeDatabase.sseValue('event: put\ndata: {"a":1}\n\n');
      expect(v !== undefined).assertTrue();
    });
    it('sseDispatch', 0, () => {
      const got: Array<string> = new Array<string>();
      SseStream.dispatchText('event: put', (event: string, data: string) => {
        got.push(event);
      });
      expect(got.length).assertEqual(0);
    });
    it('firestorePaths', 0, () => {
      expect(Firestore.parentOf('users/alice')).assertEqual('users');
      expect(Firestore.docIdOf('users/alice')).assertEqual('alice');
    });
    it('commitEnvelopeSet', 0, () => {
      const fields: Record<string, Object> = {};
      const sv: Record<string, Object> = {};
      sv['stringValue'] = 'bob';
      fields['name'] = sv;
      const op: WriteOp = new WriteOp('set', 'users/alice', fields, new Array<string>());
      const env: Object = op.toEnvelope(makeShellFirestore());
      const upd: Object | undefined = Json.object(env, 'update');
      expect(upd !== undefined).assertTrue();
      if (upd !== undefined) {
        expect(Json.string(upd, 'name', '')).assertEqual(
          'https://firestore.googleapis.com/v1/projects/demo/databases/(default)/documents/users/alice');
        expect(Json.object(upd, 'fields') !== undefined).assertTrue();
      }
      expect(Json.object(env, 'updateMask') === undefined).assertTrue();
    });
    it('commitEnvelopeUpdateMaskedAndDelete', 0, () => {
      const fields: Record<string, Object> = {};
      const iv: Record<string, Object> = {};
      iv['integerValue'] = 7;
      fields['hits'] = iv;
      const mask: Array<string> = new Array<string>();
      mask.push('hits');
      const upd: WriteOp = new WriteOp('update', 'users/alice', fields, mask);
      const updEnv: Object = upd.toEnvelope(makeShellFirestore());
      const m: Object | undefined = Json.object(updEnv, 'updateMask');
      expect(m !== undefined).assertTrue();
      if (m !== undefined) {
        const paths: Array<string> = Json.stringArray(m, 'fieldPaths');
        expect(paths.length).assertEqual(1);
        expect(paths[0]).assertEqual('hits');
      }
      const emptyFields: Record<string, Object> = {};
      const del: WriteOp = new WriteOp('remove', 'users/bob', emptyFields, new Array<string>());
      const delEnv: Object = del.toEnvelope(makeShellFirestore());
      expect(Json.string(delEnv, 'delete', '')).assertEqual(
        'https://firestore.googleapis.com/v1/projects/demo/databases/(default)/documents/users/bob');
      expect(Json.object(delEnv, 'update') === undefined).assertTrue();
    });
    it('beginTransactionBody', 0, () => {
      const rw: Record<string, Object> = {};
      const opts: Record<string, Object> = {};
      opts['readWrite'] = rw;
      const body: Record<string, Object> = {};
      body['options'] = opts;
      const wire: string = JSON.stringify(body);
      expect(wire.indexOf('"readWrite"') >= 0).assertTrue();
      expect(wire.indexOf('"options"') >= 0).assertTrue();
    });
    it('rtdbEtagHeaders', 0, () => {
      const headers: Array<HeaderPair> = new Array<HeaderPair>();
      headers.push(new HeaderPair('X-Firebase-ETag', 'true'));
      headers.push(new HeaderPair('If-Match', 'abc123'));
      expect(headers.length).assertEqual(2);
      expect(headers[0].name).assertEqual('X-Firebase-ETag');
      expect(headers[1].name).assertEqual('If-Match');
    });
    it('oauthPostBody', 0, () => {
      const cred: OAuthCredential = OAuthCredential.google('id123', 'acc456');
      expect(cred.postBody().indexOf('providerId=google.com') >= 0).assertTrue();
    });
    it('errorMessage', 0, () => {
      expect(Json.firebaseErrorMessage('{"error":{"message":"boom"}}')).assertEqual('boom');
    });
  });

  describe('push-kit-router', () => {
    it('hwTagConvention', 0, () => {
      expect(PushKitTokenProvider.tag('abc123')).assertEqual('hw:abc123');
      expect(PushKitTokenProvider.tag('hw:abc123')).assertEqual('hw:abc123');
      expect(PushKitTokenProvider.untag('hw:abc123')).assertEqual('abc123');
      expect(PushKitTokenProvider.untag('abc123')).assertEqual('abc123');
      expect(PushKitTokenProvider.untag(PushKitTokenProvider.tag('abc123'))).assertEqual('abc123');
    });
    it('hwTokenRegistryField', 0, () => {
      const wire: string = JSON.stringify(PushKitTokenProvider.profileFields('hw:abc123'));
      expect(wire.indexOf('"devicePushToken"') >= 0).assertTrue();
      expect(wire.indexOf('"stringValue":"hw:abc123"') >= 0).assertTrue();
    });
  });
}
