import { HttpTransport } from '../common/HttpTransport';
import { FirebaseException } from '../common/FirebaseError';
import { Json } from '../common/Json';
import { BackendTiedModelService, mlTokenProvider } from '../ml/BackendTiedModelService';

/**
 * Backend-tied AI feature facade.
 *
 * This is the device side for AI features that are really backend services:
 * the device sends a request to a server endpoint and receives either an
 * inference result or a precomputed result.
 *
 * This module is intentionally backend-neutral at the device level. It does
 * not decide which server runs the model; it only owns the device request
 * shape, auth, and error handling. The exact server endpoint and payload
 * must be confirmed from the server contract before shipping real behavior.
 */
export class BackendTiedAiFeature {
  private modelService: BackendTiedModelService;
  private endpoint: string;
  private idToken: aiTokenProvider;

  constructor(modelService: BackendTiedModelService, endpoint: string, idToken: aiTokenProvider) {
    this.modelService = modelService;
    this.endpoint = endpoint.length > 0 ? endpoint : 'TODO_CONFIRM_AI_FEATURE_ENDPOINT';
    this.idToken = idToken;
  }

  /**
   * Returns the name of the backend model used by this feature.
   *
   * TODO: confirm whether the server expects a model name, model id, or
   * something else.
   */
  async modelName(featureName: string): Promise<string> {
    const versionedModel: string = await this.modelService.modelId(featureName);
    return versionedModel.length > 0 ? versionedModel : featureName;
  }

  /**
   * Calls the backend AI feature endpoint for a single request.
   *
   * The request and response shapes are placeholders until the server contract
   * is confirmed. Do not assume the server accepts exactly this body or returns
   * exactly this shape.
   */
  async runRequest(featureName: string, payload: Object): Promise<Object> {
    const modelName: string = await this.modelName(featureName);
    const body: Object = {};
    body['model'] = modelName;
    body['request'] = payload;

    const envelope = await this.transport.post(
      `${this.endpoint}/features/${encodeURIComponent(featureName)}:run`,
      JSON.stringify(body),
      [],
      await this.bearer()
    );
    if (!envelope.isOk()) {
      throw FirebaseException.api('ai.feature', Json.firebaseErrorMessage(envelope.text));
    }

    const parsed: Object | undefined = Json.tryParse(envelope.text);
    if (parsed === undefined) {
      throw FirebaseException.api('ai.feature', 'malformed response');
    }
    return parsed;
  }

  /**
   * Convenience: calls the backend feature endpoint and returns a string
   * result if the server returns one.
   *
   * TODO: confirm the real response shape and the field that carries the
   * result text/value.
   */
  async runString(featureName: string, payload: Object): Promise<string> {
    const result: Object = await this.runRequest(featureName, payload);
    return Json.string(result, 'result', JSON.stringify(result));
  }

  /**
   * Convenience: returns the cached model metadata for the feature, falling
   * back to the fresh fetch if needed.
   */
  async modelMetadata(featureName: string): Promise<Object> {
    const cached: Object | undefined = this.modelService.cachedInfo(featureName);
    if (cached !== undefined) {
      return cached;
    }
    return this.modelService.modelInfo(featureName);
  }

  private async bearer(): Promise<string> {
    const t: string = await this.idToken();
    return t.length > 0 ? `Bearer ${t}` : '';
  }
}

export type aiTokenProvider = () => Promise<string>;
