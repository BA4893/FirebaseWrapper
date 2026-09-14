/**
 * OAuth credential (Google / Apple / generic IdP).
 * One of idToken / accessToken must be non-empty.
 */
export class OAuthCredential {
  providerId: string;
  idToken: string;
  accessToken: string;

  constructor(providerId: string, idToken: string, accessToken: string) {
    this.providerId = providerId;
    this.idToken = idToken;
    this.accessToken = accessToken;
  }

  static google(idToken: string, accessToken: string): OAuthCredential {
    return new OAuthCredential('google.com', idToken, accessToken);
  }

  static apple(idToken: string): OAuthCredential {
    return new OAuthCredential('apple.com', idToken, '');
  }

  postBody(): string {
    let body: string = `providerId=${encodeURIComponent(this.providerId)}`;
    if (this.idToken.length > 0) {
      body += `&id_token=${encodeURIComponent(this.idToken)}`;
    }
    if (this.accessToken.length > 0) {
      body += `&access_token=${encodeURIComponent(this.accessToken)}`;
    }
    return body;
  }
}

export type authStateHandler = (session: AuthSession | undefined) => void;

/** Handle returned by onAuthStateChanged. */
export class AuthSubscription {
  private owner: FirebaseAuth;
  private handler: authStateHandler;

  constructor(owner: FirebaseAuth, handler: authStateHandler) {
    this.owner = owner;
    this.handler = handler;
  }

  asListener(): authStateHandler {
    return this.handler;
  }

  unsubscribe(): void {
    this.owner.removeListener(this.handler);
  }
}

export type authSubscription = AuthSubscription;