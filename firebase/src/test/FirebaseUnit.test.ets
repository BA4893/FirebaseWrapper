import { describe, it, expect } from '@ohos/hypium';
import { ProtobufWriter } from '../main/ets/fcm/protobuf/ProtobufWriter';
import { ProtobufReader } from '../main/ets/fcm/protobuf/ProtobufReader';
import { McsFrameCodec, McsFrameIds } from '../main/ets/fcm/mcs/McsFrames';
import { McsStreamParser } from '../main/ets/fcm/mcs/McsStreamParser';
import { Json } from '../main/ets/common/Json';
import { SseStream } from '../main/ets/common/SseStream';
import { RealtimeDatabase } from '../main/ets/database/RealtimeDatabase';
import { Firestore } from '../main/ets/firestore/Firestore';
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
