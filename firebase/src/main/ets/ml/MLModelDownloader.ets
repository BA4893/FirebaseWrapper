import { HttpTransport } from '../common/HttpTransport';
import { FirebaseException } from '../common/FirebaseError';
import { Json } from '../common/Json';
import { KeyValueStore } from '../common/KeyValueStore';

/** ML Model Downloader: fetch + cache custom-model metadata/artifacts. */
export class MLModelDownloader {
  private transport: HttpTransport;
  private projectId: string;
  private idToken: mlTokenProvider;
  private cache: KeyValueStore | undefined;

  constructor(transport: HttpTransport, projectId: string, idToken: mlTokenProvider,
    cache?: KeyValueStore) {
    this.transport = transport;
    this.projectId = projectId;
    this.idToken = idToken;
    this.cache = cache;
  }

  async modelInfo(modelName: string): Promise<Object> {
    const e = await this.transport.get(
      `https://firebaseml.googleapis.com/v1/projects/${this.projectId}/models/${modelName}`,
      [], await this.bearer());
    if (!e.isOk()) {
      throw FirebaseException.api('mlmodel', Json.firebaseErrorMessage(e.text));
    }
    const p: Object | undefined = Json.tryParse(e.text);
    if (p === undefined) {
      throw FirebaseException.api('mlmodel', 'malformed response');
    }
    if (this.cache !== undefined) {
      this.cache.set(`mlmodel.${modelName}`, JSON.stringify(p));
    }
    return p;
  }

  cachedInfo(modelName: string): Object | undefined {
    if (this.cache === undefined) {
      return undefined;
    }
    const raw: string = this.cache.get(`mlmodel.${modelName}`, '');
    return raw.length > 0 ? Json.tryParse(raw) : undefined;
  }

  private async bearer(): Promise<string> {
    const t: string = await this.idToken();
    return t.length > 0 ? `Bearer ${t}` : '';
  }
}

export type mlTokenProvider = () => Promise<string>;
