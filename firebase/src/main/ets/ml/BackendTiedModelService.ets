import { HttpTransport } from '../common/HttpTransport';
import { KeyValueStore } from '../common/KeyValueStore';
import { FirebaseException } from '../common/FirebaseError';
import { Json } from '../common/Json';

/**
 * Backend-tied model/feature metadata service.
 *
 * This is the device side for backend-tied ML / AI features where the device
 * does not run the model locally. It fetches and caches model/feature metadata
 * from a server endpoint and exposes a stable shape for the rest of the app.
 *
 * This module does not assume a native runtime. If the server later supports
 * model download/artifact delivery, that is a separate concern and should be
 * added behind a separate interface rather than mixed into this metadata path.
 */
export class BackendTiedModelService {
  private transport: HttpTransport;
  private baseUrl: string;
  private idToken: mlTokenProvider;
  private cache: KeyValueStore | undefined;

  constructor(transport: HttpTransport, baseUrl: string, idToken: mlTokenProvider,
    cache?: KeyValueStore) {
    this.transport = transport;
    this.baseUrl = baseUrl.length > 0 ? baseUrl : 'TODO_CONFIRM_MODEL_SERVICE_BASE_URL';
    this.idToken = idToken;
    this.cache = cache;
  }

  /**
   * Returns cached model/feature metadata if present.
   */
  cachedInfo(modelName: string): Object | undefined {
    if (this.cache === undefined) {
      return undefined;
    }
    const raw: string = this.cache.get(`ml.${modelName}`, '');
    return raw.length > 0 ? Json.tryParse(raw) : undefined;
  }

  /**
   * Fetches model/feature metadata from the server and caches it locally.
   *
   * TODO: confirm the exact metadata endpoint and response shape once the
   * server contract is known. The current shape is a placeholder.
   */
  async modelInfo(modelName: string): Promise<Object> {
    const envelope = await this.transport.get(
      `${this.baseUrl}/models/${encodeURIComponent(modelName)}`,
      [],
      await this.bearer()
    );
    if (!envelope.isOk()) {
      throw FirebaseException.api('ml.metadata', Json.firebaseErrorMessage(envelope.text));
    }

    const parsed: Object | undefined = Json.tryParse(envelope.text);
    if (parsed === undefined) {
      throw FirebaseException.api('ml.metadata', 'malformed response');
    }

    if (this.cache !== undefined) {
      this.cache.set(`ml.${modelName}`, JSON.stringify(parsed));
    }
    return parsed;
  }

  /**
   * Convenience: returns a stable model id for the named feature.
   *
   * TODO: confirm whether the server uses model names, model ids, or both.
   */
  async modelId(modelName: string): Promise<string> {
    const info: Object = await this.modelInfo(modelName);
    return Json.string(info, 'modelId', modelName);
  }

  /**
   * Convenience: returns the server model version for the named feature.
   *
   * TODO: confirm the field name and semantics once the metadata contract
   * is known.
   */
  async modelVersion(modelName: string): Promise<string> {
    const info: Object = await this.modelInfo(modelName);
    return Json.string(info, 'modelVersion', '');
  }

  private async bearer(): Promise<string> {
    const t: string = await this.idToken();
    return t.length > 0 ? `Bearer ${t}` : '';
  }
}

export type mlTokenProvider = () => Promise<string>;
