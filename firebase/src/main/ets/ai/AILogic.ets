import { HttpTransport } from '../common/HttpTransport';
import { FirebaseException } from '../common/FirebaseError';
import { Json } from '../common/Json';

/**
 * Firebase AI Logic (Gemini) client: calls the Vertex AI gateway with an
 * ID token + App Check token. Model access is enforced server-side.
 */
export class AILogic {
  private transport: HttpTransport;
  private projectId: string;
  private location: string;
  private idToken: aiTokenProvider;

  constructor(transport: HttpTransport, projectId: string, location: string,
    idToken: aiTokenProvider) {
    this.transport = transport;
    this.projectId = projectId;
    this.location = location.length > 0 ? location : 'us-central1';
    this.idToken = idToken;
  }

  async generateContent(model: string, prompt: string): Promise<string> {
    const body: Object = {};
    const contents: Array<Object> = new Array<Object>();
    const part: Object = {};
    part['text'] = prompt;
    const content: Object = {};
    content['parts'] = [part];
    contents.push(content);
    body['contents'] = contents;
    const e = await this.transport.post(
      `https://${this.location}-aiplatform.googleapis.com/v1/projects/${this.projectId}/locations/${this.location}/publishers/google/models/${model}:generateContent`,
      JSON.stringify(body), [], await this.bearer());
    if (!e.isOk()) {
      throw FirebaseException.api('ailogic', Json.firebaseErrorMessage(e.text));
    }
    const p: Object | undefined = Json.tryParse(e.text);
    if (p === undefined) {
      throw FirebaseException.api('ailogic', 'malformed response');
    }
    const cands: Array<Object> | undefined = p['candidates'] as Array<Object> | undefined;
    if (cands === undefined || cands.length === 0) {
      return '';
    }
    return JSON.stringify(cands[0]);
  }

  private async bearer(): Promise<string> {
    const t: string = await this.idToken();
    return t.length > 0 ? `Bearer ${t}` : '';
  }
}

export type aiTokenProvider = () => Promise<string>;
