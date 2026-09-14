import { HttpTransport } from '../common/HttpTransport';
import { FirebaseException } from '../common/FirebaseError';
import { Json } from '../common/Json';

/** Firebase Sessions: app-session lifecycle events (Crashlytics/Perf input). */
export class Sessions {
  private transport: HttpTransport;
  private appId: string;
  private sessionId: string;

  constructor(transport: HttpTransport, appId: string) {
    this.transport = transport;
    this.appId = appId;
    this.sessionId = `${Date.now()}-${Math.round(Math.random() * 0xffffff)}`;
  }

  currentId(): string {
    return this.sessionId;
  }

  rotate(): string {
    this.sessionId = `${Date.now()}-${Math.round(Math.random() * 0xffffff)}`;
    return this.sessionId;
  }

  async reportStart(): Promise<void> {
    const body: Object = {};
    body['app_id'] = this.appId;
    body['session_id'] = this.sessionId;
    body['event'] = 'SESSION_START';
    try {
      await this.transport.post('https://firebaselogging-pa.googleapis.com/v1/sessions',
        JSON.stringify(body), [], '');
    } catch (err) {
      void err;
    }
  }
}
