import { HttpTransport } from '../common/HttpTransport';
import { FirebaseException } from '../common/FirebaseError';
import { Json } from '../common/Json';
import { KeyValueStore } from '../common/KeyValueStore';

/**
 * Firebase Installations: FID + auth token. Other products key off this.
 * REST: `https://firebaseinstallations.googleapis.com/v1/projects/{pid}/installations`.
 */
export class Installations {
  private transport: HttpTransport;
  private projectId: string;
  private apiKey: string;
  private store: KeyValueStore;
  private fid: string;

  constructor(transport: HttpTransport, projectId: string, apiKey: string, store: KeyValueStore) {
    this.transport = transport;
    this.projectId = projectId;
    this.apiKey = apiKey;
    this.store = store;
    this.fid = store.get('installations.fid', '');
    if (this.fid.length === 0) {
      this.fid = Installations.newFid();
      store.set('installations.fid', this.fid);
    }
  }

  getFid(): string {
    return this.fid;
  }

  async authToken(forceRefresh: boolean): Promise<string> {
    const cached: string = this.store.get('installations.token', '');
    if (!forceRefresh && cached.length > 0) {
      return cached;
    }
    const url: string = `https://firebaseinstallations.googleapis.com/v1/projects/${this.projectId}/installations/${this.fid}/authTokens:generate?key=${this.apiKey}`;
    const e = await this.transport.post(url, '{}', [], '');
    if (!e.isOk()) {
      throw FirebaseException.api('installations.token', Json.firebaseErrorMessage(e.text));
    }
    const p: Object | undefined = Json.tryParse(e.text);
    if (p === undefined) {
      throw FirebaseException.api('installations.token', 'malformed response');
    }
    const token: string = Json.string(p, 'authToken', '');
    this.store.set('installations.token', token);
    return token;
  }

  async deleteInstallation(): Promise<void> {
    const url: string = `https://firebaseinstallations.googleapis.com/v1/projects/${this.projectId}/installations/${this.fid}?key=${this.apiKey}`;
    await this.transport.delete(url, [], '');
    this.store.remove('installations.fid');
    this.store.remove('installations.token');
    this.fid = Installations.newFid();
    this.store.set('installations.fid', this.fid);
  }

  private static newFid(): string {
    const chars: string = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_';
    let out: string = 'd';
    for (let i: number = 1; i < 22; i++) {
      out += chars.charAt(Math.floor(Math.random() * chars.length));
    }
    return out;
  }
}
