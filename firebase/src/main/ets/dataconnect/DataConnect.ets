import { HttpTransport } from '../common/HttpTransport';
import { FirebaseException } from '../common/FirebaseError';
import { Json } from '../common/Json';

/** Firebase Data Connect: executes GraphQL operations over HTTPS. */
export class DataConnect {
  private transport: HttpTransport;
  private projectId: string;
  private location: string;
  private service: string;
  private idToken: dcTokenProvider;

  constructor(transport: HttpTransport, projectId: string, location: string,
    service: string, idToken: dcTokenProvider) {
    this.transport = transport;
    this.projectId = projectId;
    this.location = location.length > 0 ? location : 'us-central1';
    this.service = service;
    this.idToken = idToken;
  }

  async query(operation: string, variables: Object): Promise<Object> {
    const body: Object = {};
    body['query'] = operation;
    body['variables'] = variables;
    const e = await this.transport.post(
      `https://${this.location}-firebasedataconnect.googleapis.com/v1/projects/${this.projectId}/locations/${this.location}/services/${this.service}:executeQuery`,
      JSON.stringify(body), [], await this.bearer());
    if (!e.isOk()) {
      throw FirebaseException.api('dataconnect', Json.firebaseErrorMessage(e.text));
    }
    const p: Object | undefined = Json.tryParse(e.text);
    if (p === undefined) {
      throw FirebaseException.api('dataconnect', 'malformed response');
    }
    return p;
  }

  private async bearer(): Promise<string> {
    const t: string = await this.idToken();
    return t.length > 0 ? `Bearer ${t}` : '';
  }
}

export type dcTokenProvider = () => Promise<string>;
