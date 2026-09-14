import { KeyValueStore } from './KeyValueStore';
import { SecureStore } from './SecureStore';

/**
 * Signed-in session credentials.
 */
export class AuthSession {
  idToken: string;
  refreshToken: string;
  /** Unix epoch seconds when idToken expires. */
  expiresAt: number;
  localId: string;
  email: string;

  constructor(idToken: string, refreshToken: string, expiresAt: number, localId: string, email: string) {
    this.idToken = idToken;
    this.refreshToken = refreshToken;
    this.expiresAt = expiresAt;
    this.localId = localId;
    this.email = email;
  }

  isExpired(): boolean {
    return Date.now() / 1000 >= this.expiresAt;
  }

  toJson(publicOnly: boolean = false): string {
    const body: Object = {};
    body['idToken'] = this.idToken;
    body['refreshToken'] = publicOnly ? '' : this.refreshToken;
    body['expiresAt'] = this.expiresAt;
    body['localId'] = this.localId;
    body['email'] = this.email;
    body['savedAt'] = Date.now();
    return JSON.stringify(body);
  }

  static fromJson(text: string): AuthSession | undefined {
    try {
      const parsed: Object = JSON.parse(text);
      const idToken: Object | undefined = parsed['idToken'];
      const refreshToken: Object | undefined = parsed['refreshToken'];
      const expiresAt: Object | undefined = parsed['expiresAt'];
      const localId: Object | undefined = parsed['localId'];
      const email: Object | undefined = parsed['email'];
      if (idToken === undefined || refreshToken === undefined || expiresAt === undefined) {
        return undefined;
      }
      return new AuthSession(
        idToken as string,
        refreshToken as string,
        expiresAt as number,
        localId === undefined ? '' : localId as string,
        email === undefined ? '' : email as string);
    } catch (err) {
      return undefined;
    }
  }
}

/**
 * Persists the current auth session (id token, refresh token).
 * Sensitive by nature: keep the backing store in a private app directory.
 */
export class CredentialStore {
  private store: KeyValueStore;
  private memory: Map<string, string>;
  private secrets: SecureStore;

  constructor(store: KeyValueStore) {
    this.store = store;
    this.memory = new Map<string, string>();
    this.secrets = new SecureStore('firebase.auth', CredentialStore.dirOf(store.filePath));
  }

  /** Parent directory of the backing JSON file, '' when the path has none. */
  private static dirOf(path: string): string {
    const slash: number = Math.max(path.lastIndexOf('/'), path.lastIndexOf('\\'));
    return slash > 0 ? path.substring(0, slash) : '';
  }

  saveSession(session: AuthSession): void {
    this.memory.set('auth.session', session.toJson());
    this.store.set('auth.session.public', session.toJson(true));
    this.secrets.setSecret('auth.refresh', session.refreshToken).catch(() => {
    });
  }

  /** Async variant that guarantees the refreshToken is sealed first. */
  async saveSessionSealed(session: AuthSession): Promise<void> {
    await this.secrets.setSecret('auth.refresh', session.refreshToken);
    this.memory.set('auth.session', session.toJson());
    this.store.set('auth.session.public', session.toJson(true));
  }

  loadSession(): AuthSession | undefined {
    let raw: string = '';
    if (this.memory.hasKey('auth.session')) {
      raw = this.memory.get('auth.session') as string;
    } else if (this.store.has('auth.session')) {
      raw = this.store.get('auth.session', '');
      this.memory.set('auth.session', raw);
    } else if (this.store.has('auth.session.public')) {
      raw = this.store.get('auth.session.public', '');
    }
    if (raw.length === 0) {
      return undefined;
    }
    return AuthSession.fromJson(raw);
  }

  async loadRefreshToken(): Promise<string> {
    const sealed: string = await this.secrets.getSecret('auth.refresh');
    if (sealed.length > 0) {
      return sealed;
    }
    const s: AuthSession | undefined = this.loadSession();
    return s !== undefined ? s.refreshToken : '';
  }

  clearSession(): void {
    this.memory.delete('auth.session');
    this.store.remove('auth.session');
    this.store.remove('auth.session.public');
    this.secrets.removeSecret('auth.refresh').catch(() => {
    });
  }

  /** Short-lived App Check exchange token — intentionally memory-only. */
  saveAppCheckToken(token: string): void {
    this.memory.set('appcheck.token', token);
  }

  loadAppCheckToken(): string {
    if (this.memory.hasKey('appcheck.token')) {
      return this.memory.get('appcheck.token') as string;
    }
    return '';
  }

  clearAppCheckToken(): void {
    this.memory.delete('appcheck.token');
  }
}