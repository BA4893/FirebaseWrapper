import { HttpTransport } from '../common/HttpTransport';
import { FirebaseException } from '../common/FirebaseError';
import { Json } from '../common/Json';

/** Callable Cloud Functions (`cloudfunctions.net` HTTPS callable). */
export class FirebaseFunctions {
  private transport: HttpTransport;
  private projectId: string;
  private region: string;
  private idToken: functionsTokenProvider;

  constructor(transport: HttpTransport, projectId: string, region: string,
    idToken: functionsTokenProvider) {
    this.transport = transport;
    this.projectId = projectId;
    this.region = region.length > 0 ? region : 'us-central1';
    this.idToken = idToken;
  }

  async call(name: string, data: Object): Promise<Object | undefined> {
    const body: Object = {};
    body['data'] = data;
    const url: string = `https://${this.region}-${this.projectId}.cloudfunctions.net/${name}`;
    const e = await this.transport.post(url, JSON.stringify(body), [], await this.bearer());
    if (!e.isOk()) {
      throw FirebaseException.api('functions.call', Json.firebaseErrorMessage(e.text));
    }
    const p: Object | undefined = Json.tryParse(e.text);
    if (p === undefined) {
      return undefined;
    }
    const result: Object | undefined = p['result'];
    return result !== undefined ? result : p;
  }

  private async bearer(): Promise<string> {
    const t: string = await this.idToken();
    return t.length > 0 ? `Bearer ${t}` : '';
  }
}

export type functionsTokenProvider = () => Promise<string>;
