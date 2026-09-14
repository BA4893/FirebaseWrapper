import { HttpTransport } from '../common/HttpTransport';
import { FirebaseException } from '../common/FirebaseError';
import { Json } from '../common/Json';

/** A/B Testing via Remote Config experiment assignment (console-backed). */
export class ABTesting {
  private transport: HttpTransport;
  private projectId: string;
  private idToken: abTokenProvider;

  constructor(transport: HttpTransport, projectId: string, idToken: abTokenProvider) {
    this.transport = transport;
    this.projectId = projectId;
    this.idToken = idToken;
  }

  async experimentVariant(experimentId: string, fid: string): Promise<string> {
    const e = await this.transport.get(
      `https://firebaseremoteconfig.googleapis.com/v1/projects/${this.projectId}/experiments/${experimentId}/assignments/${fid}`,
      [], await this.bearer());
    if (!e.isOk()) {
      throw FirebaseException.api('abtesting', Json.firebaseErrorMessage(e.text));
    }
    const p: Object | undefined = Json.tryParse(e.text);
    if (p === undefined) {
      throw FirebaseException.api('abtesting', 'malformed response');
    }
    return Json.string(p, 'variant', 'control');
  }

  private async bearer(): Promise<string> {
    const t: string = await this.idToken();
    return t.length > 0 ? `Bearer ${t}` : '';
  }
}

export type abTokenProvider = () => Promise<string>;
