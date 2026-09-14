import { HttpTransport, HttpEnvelope } from '../common/HttpTransport';
import { FirebaseException, FirebaseErrorCode } from '../common/FirebaseError';
import { Json } from '../common/Json';
import { AuthSession, CredentialStore } from '../common/CredentialStore';

const AUTH_BASE: string = 'https://identitytoolkit.googleapis.com/v1';
const SECURE_TOKEN_BASE: string = 'https://securetoken.googleapis.com/v1';

/**
 * Firebase Authentication via the Identity Toolkit REST API.
 *
 * Exposes the classic email/password + token-refresh surface. The returned ID token is
 * the bearer credential used by every other service in this SDK.
 */
export class FirebaseAuth {
  private transport: HttpTransport;
  private apiKey: string;
  private store: CredentialStore;
  private currentSession: AuthSession | undefined;
  private listeners: Array<authStateHandler>;

  constructor(transport: HttpTransport, apiKey: string, store: CredentialStore) {
    this.transport = transport;
    this.apiKey = apiKey;
    this.store = store;
    this.currentSession = store.loadSession();
    this.listeners = new Array<authStateHandler>();
  }

  /**
   * Creates a new account with email/password.
   */
  async signUpWithPassword(email: string, password: string): Promise<AuthSession> {
    const body: Object = {};
    body['email'] = email;
    body['password'] = password;
    body['returnSecureToken'] = true;
    const envelope = await this.transport.post(`${AUTH_BASE}/accounts:signUp?key=${this.apiKey}`,
      JSON.stringify(body), [], '');
    return this.consumeAuthEnvelope(envelope);
  }

  /**
   * Signs in an existing user with email/password.
   */
  async signInWithPassword(email: string, password: string): Promise<AuthSession> {
    const body: Object = {};
    body['email'] = email;
    body['password'] = password;
    body['returnSecureToken'] = true;
    const envelope = await this.transport.post(`${AUTH_BASE}/accounts:signInWithPassword?key=${this.apiKey}`,
      JSON.stringify(body), [], '');
    return this.consumeAuthEnvelope(envelope);
  }

  /**
   * Signs in anonymously (no credentials). Returns a session whose
   * provider id is `anonymous`.
   */
  async signInAnonymously(): Promise<AuthSession> {
    const body: Object = {};
    body['returnSecureToken'] = true;
    const envelope = await this.transport.post(`${AUTH_BASE}/accounts:signUp?key=${this.apiKey}`,
      JSON.stringify(body), [], '');
    return this.consumeAuthEnvelope(envelope);
  }

  /**
   * Starts a phone-number sign-in: sends the SMS code. Returns the
   * `sessionInfo` to pass to {@link confirmPhoneCode}.
   */
  async sendPhoneCode(phoneNumber: string, recaptchaToken: string): Promise<string> {
    const body: Object = {};
    body['phoneNumber'] = phoneNumber;
    body['recaptchaToken'] = recaptchaToken;
    const envelope = await this.transport.post(`${AUTH_BASE}/accounts:sendVerificationCode?key=${this.apiKey}`,
      JSON.stringify(body), [], '');
    if (!envelope.isOk()) {
      throw FirebaseException.api('auth.phone.send', Json.firebaseErrorMessage(envelope.text));
    }
    const parsed: Object | undefined = Json.tryParse(envelope.text);
    if (parsed === undefined) {
      throw FirebaseException.api('auth.phone.send', 'malformed response');
    }
    return Json.string(parsed, 'sessionInfo', '');
  }

  /**
   * Confirms a phone-number sign-in with the SMS code from
   * {@link sendPhoneCode}.
   */
  async confirmPhoneCode(sessionInfo: string, code: string): Promise<AuthSession> {
    const body: Object = {};
    body['sessionInfo'] = sessionInfo;
    body['code'] = code;
    const envelope = await this.transport.post(`${AUTH_BASE}/accounts:signInWithPhoneNumber?key=${this.apiKey}`,
      JSON.stringify(body), [], '');
    return this.consumeAuthEnvelope(envelope);
  }

  /**
   * Signs in with a custom token minted by your backend (Admin SDK).
   */
  async signInWithCustomToken(token: string): Promise<AuthSession> {
    const body: Object = {};
    body['token'] = token;
    body['returnSecureToken'] = true;
    const envelope = await this.transport.post(`${AUTH_BASE}/accounts:signInWithCustomToken?key=${this.apiKey}`,
      JSON.stringify(body), [], '');
    return this.consumeAuthEnvelope(envelope);
  }

  /**
   * Signs in with a Google / Apple / generic OAuth credential via
   * `accounts:signInWithIdp` (idToken or accessToken + providerId).
   */
  async signInWithOAuth(credential: OAuthCredential): Promise<AuthSession> {
    const body: Object = {};
    body['requestUri'] = 'http://localhost';
    body['returnSecureToken'] = true;
    body['postBody'] = credential.postBody();
    const envelope = await this.transport.post(`${AUTH_BASE}/accounts:signInWithIdp?key=${this.apiKey}`,
      JSON.stringify(body), [], '');
    return this.consumeAuthEnvelope(envelope);
  }

  /**
   * Subscribes to auth-state changes. Invoked immediately with the current
   * session, then on every sign-in / sign-out / refresh.
   */
  onAuthStateChanged(handler: authStateHandler): authSubscription {
    const sub: AuthSubscription = new AuthSubscription(this, handler);
    this.listeners.push(sub.asListener());
    handler(this.currentSession);
    return sub;
  }

  /** Links an OAuth credential to the current user (verify + merge). */
  async linkWithOAuth(credential: OAuthCredential): Promise<AuthAccountInfo> {
    const token: string = await this.idToken(false);
    const body: Object = {};
    body['idToken'] = token;
    body['postBody'] = credential.postBody();
    body['requestUri'] = 'http://localhost';
    body['returnSecureToken'] = true;
    const envelope = await this.transport.post(`${AUTH_BASE}/accounts:update?key=${this.apiKey}`,
      JSON.stringify(body), [], '');
    if (!envelope.isOk()) {
      throw FirebaseException.api('auth.link', Json.firebaseErrorMessage(envelope.text));
    }
    return this.accountInfo();
  }

  /** Sends a password-reset email. */
  async sendPasswordReset(email: string): Promise<void> {
    const body: Object = {};
    body['requestType'] = 'PASSWORD_RESET';
    body['email'] = email;
    const envelope = await this.transport.post(`${AUTH_BASE}/accounts:sendOobConfirmationCode?key=${this.apiKey}`,
      JSON.stringify(body), [], '');
    if (!envelope.isOk()) {
      throw FirebaseException.api('auth.reset', Json.firebaseErrorMessage(envelope.text));
    }
  }

  /** Deletes the current account. */
  async deleteAccount(): Promise<void> {
    const token: string = await this.idToken(false);
    const body: Object = {};
    body['idToken'] = token;
    const envelope = await this.transport.post(`${AUTH_BASE}/accounts:delete?key=${this.apiKey}`,
      JSON.stringify(body), [], '');
    if (!envelope.isOk()) {
      throw FirebaseException.api('auth.delete', Json.firebaseErrorMessage(envelope.text));
    }
    this.signOut();
  }

  /**
   * Signs out locally, dropping the persisted session.
   */
  signOut(): void {
    this.currentSession = undefined;
    this.store.clearSession();
    this.store.clearAppCheckToken();
    this.emitState();
  }

  /**
   * Multi-factor authentication: enrols a phone second factor for the current
   * user. Step 1 sends the SMS; complete with {@link confirmMfaEnrollment}.
   */
  async startMfaEnrollment(phoneNumber: string, recaptchaToken: string): Promise<string> {
    const token: string = await this.idToken(false);
    const body: Object = {};
    body['idToken'] = token;
    body['phoneInfo'] = phoneNumber;
    const envelope = await this.transport.post(`${AUTH_BASE}/accounts:startMfaEnrollment?key=${this.apiKey}`,
      JSON.stringify(body), [], '');
    if (!envelope.isOk()) {
      throw FirebaseException.api('auth.mfa.enroll.start', Json.firebaseErrorMessage(envelope.text));
    }
    const parsed: Object | undefined = Json.tryParse(envelope.text);
    if (parsed === undefined) {
      throw FirebaseException.api('auth.mfa.enroll.start', 'malformed response');
    }
    return Json.string(parsed, 'phoneSessionInfo', Json.string(parsed, 'sessionInfo', ''));
  }

  /** Multi-factor: completes enrolment with the SMS code. */
  async confirmMfaEnrollment(sessionInfo: string, code: string): Promise<void> {
    const token: string = await this.idToken(false);
    const body: Object = {};
    body['idToken'] = token;
    body['phoneVerificationInfo'] = { sessionInfo: sessionInfo, code: code };
    const envelope = await this.transport.post(`${AUTH_BASE}/accounts:finalizeMfaEnrollment?key=${this.apiKey}`,
      JSON.stringify(body), [], '');
    if (!envelope.isOk()) {
      throw FirebaseException.api('auth.mfa.enroll.finalize', Json.firebaseErrorMessage(envelope.text));
    }
  }

  /** Multi-factor: removes an enrolled second factor. */
  async withdrawMfa(factorId: string): Promise<void> {
    const token: string = await this.idToken(false);
    const body: Object = {};
    body['idToken'] = token;
    body['mfaEnrollmentId'] = factorId;
    const envelope = await this.transport.post(`${AUTH_BASE}/accounts:withdrawMfa?key=${this.apiKey}`,
      JSON.stringify(body), [], '');
    if (!envelope.isOk()) {
      throw FirebaseException.api('auth.mfa.withdraw', Json.firebaseErrorMessage(envelope.text));
    }
  }

  /**
   * Signs in with email-link (iOS `sendSignInLinkToEmail` + `signInWithEmailLink`).
   * Sends the OOB code, then consumes the `oobCode` from the deep link.
   */
  async sendSignInLinkToEmail(email: string): Promise<void> {
    const body: Object = {};
    body['requestType'] = 'EMAIL_SIGNIN';
    body['email'] = email;
    const envelope = await this.transport.post(`${AUTH_BASE}/accounts:sendOobConfirmationCode?key=${this.apiKey}`,
      JSON.stringify(body), [], '');
    if (!envelope.isOk()) {
      throw FirebaseException.api('auth.emailLink.send', Json.firebaseErrorMessage(envelope.text));
    }
  }

  async signInWithEmailLink(email: string, oobCode: string): Promise<AuthSession> {
    const body: Object = {};
    body['email'] = email;
    body['oobCode'] = oobCode;
    const envelope = await this.transport.post(`${AUTH_BASE}/accounts:signInWithEmailLink?key=${this.apiKey}`,
      JSON.stringify(body), [], '');
    return this.consumeAuthEnvelope(envelope);
  }

  /**
   * Reauthentication (iOS `reauthWithPassword`): refreshes credentials for
   * sensitive operations without rotating the refresh token semantics.
   */
  async reauthWithPassword(email: string, password: string): Promise<AuthSession> {
    const body: Object = {};
    body['email'] = email;
    body['password'] = password;
    body['returnSecureToken'] = true;
    const envelope = await this.transport.post(`${AUTH_BASE}/accounts:signInWithPassword?key=${this.apiKey}`,
      JSON.stringify(body), [], '');
    return this.consumeAuthEnvelope(envelope);
  }

  /**
   * MFA sign-in step 2: after `signInWithPassword` returns `MFA_REQUIRED`,
   * resolve with the SMS code. Session was NOT consumed on the MFA challenge.
   */
  async resolveMfaSignIn(mfaPending: MfaPendingCredential, code: string): Promise<AuthSession> {
    const body: Object = {};
    body['mfaPendingCredential'] = mfaPending.pendingCredential;
    body['mfaEnrollmentId'] = mfaPending.enrollmentId;
    body['signInMethod'] = 'EMAIL_PASSWORD';
    const envelope = await this.transport.post(`${AUTH_BASE}/accounts:mfaSignInFinalize?key=${this.apiKey}`,
      JSON.stringify(body), [], '');
    const session: AuthSession = this.consumeAuthEnvelope(envelope);
    if (mfaPending.refreshToken.length > 0 && session.refreshToken.length === 0) {
      const upgraded: AuthSession = new AuthSession(session.idToken, mfaPending.refreshToken,
        session.expiresAt, session.localId, session.email);
      this.currentSession = upgraded;
      this.store.saveSession(upgraded);
      this.emitState();
      return upgraded;
    }
    return session;
  }

  get session(): AuthSession | undefined {
    return this.currentSession;
  }

  /**
   * Returns a valid ID token, transparently refreshing when expired.
   */
  async idToken(forceRefresh: boolean): Promise<string> {
    if (this.currentSession === undefined) {
      throw FirebaseException.auth('Not signed in. Call signInWithPassword first.');
    }
    if (!forceRefresh && !this.currentSession.isExpired()) {
      return this.currentSession.idToken;
    }
    if (this.currentSession.refreshToken.length === 0) {
      throw FirebaseException.auth('Session has no refresh token.');
    }
    await this.refreshTokens();
    if (this.currentSession === undefined) {
      throw FirebaseException.auth('Token refresh failed.');
    }
    return this.currentSession.idToken;
  }
  /**
   * Exchange a refresh token for a new id token (https://securetoken.googleapis.com).
   */
  async refreshTokens(): Promise<AuthSession> {
    if (this.currentSession === undefined) {
      throw FirebaseException.auth('Not signed in.');
    }
    const body: Object = {};
    body['grant_type'] = 'refresh_token';
    body['refresh_token'] = this.currentSession.refreshToken;
    const envelope = await this.transport.post(`${SECURE_TOKEN_BASE}/token?key=${this.apiKey}`,
      JSON.stringify(body), [], '');
    if (!envelope.isOk()) {
      throw FirebaseException.api('refresh_tokens', Json.firebaseErrorMessage(envelope.text));
    }
    const parsed: Object | undefined = Json.tryParse(envelope.text);
    if (parsed === undefined) {
      throw FirebaseException.api('refresh_tokens', 'malformed response');
    }
    const idToken: string = Json.string(parsed, 'id_token', '');
    const refreshToken: string = Json.string(parsed, 'refresh_token', '');
    const expiresInSeconds: number = Json.number(parsed, 'expires_in', 3600);
    const session: AuthSession = new AuthSession(
      idToken,
      refreshToken.length > 0 ? refreshToken : this.currentSession.refreshToken,
      Date.now() / 1000 + expiresInSeconds,
      this.currentSession.localId,
      this.currentSession.email);
    this.currentSession = session;
    this.store.saveSession(session);
    return session;
  }

  /**
   * Reads the account profile for the current token.
   */
  async accountInfo(): Promise<AuthAccountInfo> {
    const token: string = await this.idToken(false);
    const envelope = await this.transport.post(`${AUTH_BASE}/accounts:lookup?key=${this.apiKey}`,
      '{}', [], `Bearer ${token}`);
    if (!envelope.isOk()) {
      throw FirebaseException.api('accounts:lookup', Json.firebaseErrorMessage(envelope.text));
    }
    const parsed: Object | undefined = Json.tryParse(envelope.text);
    if (parsed === undefined) {
      throw FirebaseException.api('accounts:lookup', 'malformed response');
    }
    const users: Array<Object> = parsed['users'] as Array<Object>;
    if (users.length === 0) {
      throw FirebaseException.api('accounts:lookup', 'no user returned');
    }
    const user: Object = users[0];
    return new AuthAccountInfo(
      Json.string(user, 'localId', ''),
      Json.string(user, 'email', ''),
      Json.boolean(user, 'emailVerified', false));
  }

  private consumeAuthEnvelope(envelope: HttpEnvelope): AuthSession {
    if (!envelope.isOk()) {
      throw FirebaseException.api('auth', Json.firebaseErrorMessage(envelope.text));
    }
    const parsed: Object | undefined = Json.tryParse(envelope.text);
    if (parsed === undefined) {
      throw FirebaseException.api('auth', 'malformed response');
    }
    const localId: string = Json.string(parsed, 'localId', '');
    const email: string = Json.string(parsed, 'email', '');
    const idToken: string = Json.string(parsed, 'idToken', '');
    const refreshToken: string = Json.string(parsed, 'refreshToken', '');
    const expiresInSeconds: number = Json.number(parsed, 'expiresIn', 3600);
    const session: AuthSession = new AuthSession(idToken, refreshToken,
      Date.now() / 1000 + expiresInSeconds, localId, email);
    this.currentSession = session;
    this.store.saveSession(session);
    this.emitState();
    return session;
  }

  private emitState(): void {
    for (let i: number = 0; i < this.listeners.length; i++) {
      this.listeners[i](this.currentSession);
    }
  }

  removeListener(handler: authStateHandler): void {
    for (let i: number = 0; i < this.listeners.length; i++) {
      if (this.listeners[i] === handler) {
        this.listeners.splice(i, 1);
        return;
      }
    }
  }
}

/**
 * Basic-account summary (localId / email / verification state).
 */
export class AuthAccountInfo {
  localId: string;
  email: string;
  emailVerified: boolean;

  constructor(localId: string, email: string, emailVerified: boolean) {
    this.localId = localId;
    this.email = email;
    this.emailVerified = emailVerified;
  }
}

/**
 * Pending MFA challenge returned by Identity Toolkit (`MFA_REQUIRED`).
 * Pass to {@link FirebaseAuth.resolveMfaSignIn} with the SMS code.
 */
export class MfaPendingCredential {
  pendingCredential: string;
  enrollmentId: string;
  /** Refresh token captured before the challenge, so the session survives finalize. */
  refreshToken: string;

  constructor(pendingCredential: string, enrollmentId: string, refreshToken: string) {
    this.pendingCredential = pendingCredential;
    this.enrollmentId = enrollmentId;
    this.refreshToken = refreshToken;
  }
}