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

  // -----------------------------------------------------------------------
  // Reauthentication
  // -----------------------------------------------------------------------

  /**
   * Reauthenticates the current user with fresh credentials.
   *
   * Used before sensitive operations that require a recent login.
   *
   * TODO: confirm the exact server semantics once the Firebase Auth
   * documentation is available:
   *   - distinct reauth endpoint, or
   *   - fresh credential sign-in that rebinds the current session
   *
   * For email/password this implementation currently reuses the existing
   * sign-in path as a concrete placeholder until the confirmed semantics
   * are known.
   */
  async reauthenticateWithCredential(credential: AuthCredential): Promise<AuthSession> {
    if (credential instanceof EmailPasswordCredential) {
      return this.reauthWithEmailPassword(credential);
    }

    if (credential instanceof OAuthCredential) {
      return this.reauthWithOAuth(credential);
    }

    if (credential instanceof PhoneCredential) {
      return this.reauthWithPhone(credential);
    }

    throw FirebaseException.auth('unsupported credential for reauthentication');
  }

  /**
   * Reauth with email/password.
   *
   * TODO: confirm the exact server semantics and the accepted endpoint once
   * the Firebase Auth documentation is available. This placeholder reuses
   * the existing sign-in path until then.
   */
  private async reauthWithEmailPassword(
    credential: EmailPasswordCredential
  ): Promise<AuthSession> {
    if (this.currentSession === undefined) {
      throw FirebaseException.auth('no current session for reauthentication');
    }

    // TODO_CONFIRM_REAUTH_PATH: replace with the confirmed reauth endpoint or
    // confirm that reusing signInWithPassword is acceptable for the target
    // Firebase Auth semantics.
    const endpoint: string = `${AUTH_BASE}/accounts:signInWithPassword?key=${this.apiKey}`;

    const body: Object = {};
    body['email'] = credential.email;
    body['password'] = credential.password;
    body['returnSecureToken'] = true;

    const envelope = await this.transport.post(endpoint, JSON.stringify(body), [], '');
    const session: AuthSession = this.consumeAuthEnvelope(envelope);

    // TODO: confirm whether reauth should preserve the previous localId or
    // whether session replacement is the correct behavior here.
    return session;
  }

  /**
   * Reauth with OAuth/provider credential.
   *
   * TODO: confirm supported provider credential shape and server path once
   * the Firebase Auth documentation is available.
   */
  private async reauthWithOAuth(
    credential: OAuthCredential
  ): Promise<AuthSession> {
    // TODO_CONFIRM_REAUTH_PATH
    throw FirebaseException.auth('reauthentication with OAuth not implemented');
  }

  /**
   * Reauth with phone credential.
   *
   * TODO: confirm how the SMS code is bound and whether this reuses the
   * existing phone sign-in flow once the Firebase Auth documentation is
   * available.
   */
  private async reauthWithPhone(
    credential: PhoneCredential
  ): Promise<AuthSession> {
    // TODO_CONFIRM_REAUTH_PATH
    throw FirebaseException.auth('reauthentication with phone not implemented');
  }

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

  // -----------------------------------------------------------------------
  // Email-link sign-in
  // -----------------------------------------------------------------------

  /**
   * Sends a Firebase email sign-in link to the given email address.
   *
   * The returned {@link EmailLinkDeliveryInfo} describes what the client
   * must persist locally until the link is used.
   *
   * TODO: confirm the exact send endpoint and required fields once the
   * Firebase Auth documentation is available.
   */
  async sendSignInLinkToEmail(
    email: string,
    actionUrl: string
  ): Promise<EmailLinkDeliveryInfo> {
    if (email.length === 0) {
      throw FirebaseException.auth('email required for email-link sign-in');
    }
    if (actionUrl.length === 0) {
      throw FirebaseException.auth('action URL required for email-link sign-in');
    }

    // TODO_CONFIRM_EMAIL_LINK_SEND_ENDPOINT
    const endpoint: string = 'TODO_CONFIRM_EMAIL_LINK_SEND_ENDPOINT';

    const body: Object = {};
    body['email'] = email;
    body['actionUrl'] = actionUrl;

    const envelope = await this.transport.post(
      `${endpoint}?key=${this.apiKey}`,
      JSON.stringify(body),
      [],
      ''
    );

    if (!envelope.isOk()) {
      throw FirebaseException.api(
        'email-link send',
        Json.firebaseErrorMessage(envelope.text)
      );
    }

    // TODO: confirm the success response shape and whether it includes a
    // sessionInfo / oob code that the client must persist.
    const parsed: Object | undefined = Json.tryParse(envelope.text);
    if (parsed === undefined) {
      throw FirebaseException.api('email-link send', 'malformed response');
    }

    this.savePendingEmailLinkState({
      email: email,
      actionUrl: actionUrl,
      storedAt: Date.now()
    });

    return new EmailLinkDeliveryInfo(email, true, parsed);
  }

  /**
   * Completes email-link sign-in.
   *
   * {@code link} is the full sign-in link string received by the app.
   * {@code email} must be the email the link was sent to.
   *
   * TODO: confirm the exact confirm endpoint and whether the server expects
   * the full link, an extracted code/sessionInfo, or both once the Firebase
   * Auth documentation is available.
   */
  async signInWithEmailLink(
    link: string,
    email: string
  ): Promise<AuthSession> {
    if (link.length === 0) {
      throw FirebaseException.auth('sign-in link required');
    }
    if (email.length === 0) {
      throw FirebaseException.auth('email required for email-link sign-in');
    }

    const pendingEmail: string | undefined = this.getPendingEmailLinkEmail();
    if (pendingEmail !== undefined && pendingEmail !== email) {
      throw FirebaseException.auth('email does not match pending link');
    }

    // TODO_CONFIRM_EMAIL_LINK_CONFIRM_ENDPOINT
    const endpoint: string = 'TODO_CONFIRM_EMAIL_LINK_CONFIRM_ENDPOINT';

    const body: Object = {};
    body['link'] = link;
    body['email'] = email;

    const envelope = await this.transport.post(
      `${endpoint}?key=${this.apiKey}`,
      JSON.stringify(body),
      [],
      ''
    );

    if (!envelope.isOk()) {
      const detail: string = Json.firebaseErrorMessage(envelope.text);
      // TODO: distinguish expired/used link errors if the server returns them.
      throw FirebaseException.api('email-link confirm', detail);
    }

    // TODO: confirm the success response shape.
    // Expected to contain: idToken, refreshToken, expiresIn, localId, email, etc.
    return this.consumeAuthEnvelope(envelope);
  }

  /**
   * Returns the locally stored pending email for an email-link flow,
   * if one exists.
   */
  getPendingEmailLinkEmail(): string | undefined {
    const state: PendingEmailLinkState | undefined = this.takePendingEmailLinkState();
    if (state === undefined) {
      return undefined;
    }
    return state.email;
  }

  /**
   * Clears any locally stored pending email-link state.
   */
  clearPendingEmailLink(): void {
    this.clearPendingEmailLinkState();
  }

  /**
   * Stores pending email-link state locally.
   */
  private savePendingEmailLinkState(state: PendingEmailLinkState): void {
    // TODO: use the existing store/credentials path the SDK already has.
    // Keep this lightweight; do not leak sensitive data.
    (void)state;
  }

  /**
   * Takes the pending email-link state out of storage so it can be consumed
   * once by {@link signInWithEmailLink}.
   */
  private takePendingEmailLinkState(): PendingEmailLinkState | undefined {
    // TODO: read + remove the state under PENDING_EMAIL_LINK_KEY.
    return undefined;
  }

  /**
   * Clears pending email-link state without consuming it.
   */
  private clearPendingEmailLinkState(): void {
    // TODO: remove PENDING_EMAIL_LINK_KEY if present.
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
 * Email/password credential for reauthentication.
 */
export class EmailPasswordCredential {
  readonly email: string;
  readonly password: string;

  constructor(email: string, password: string) {
    this.email = email;
    this.password = password;
  }
}

/**
 * Phone credential for reauthentication.
 */
export class PhoneCredential {
  readonly sessionInfo: string;
  readonly code: string;

  constructor(sessionInfo: string, code: string) {
    this.sessionInfo = sessionInfo;
    this.code = code;
  }
}

/**
 * Credential union for reauthentication.
 *
 * New provider credential shapes should be added here as they are
 * supported.
 */
export type AuthCredential =
  | EmailPasswordCredential
  | OAuthCredential
  | PhoneCredential;

/**
 * Returned by {@link sendSignInLinkToEmail} so the app knows what to do next.
 */
export class EmailLinkDeliveryInfo {
  readonly email: string;
  readonly shouldOpenLink: boolean;
  readonly parsedResponse: Object | undefined;

  constructor(email: string, shouldOpenLink: boolean, parsedResponse: Object | undefined) {
    this.email = email;
    this.shouldOpenLink = shouldOpenLink;
    this.parsedResponse = parsedResponse;
  }
}

/**
 * Internal pending state for the email-link flow.
 */
interface PendingEmailLinkState {
  email: string;
  actionUrl: string;
  storedAt: number;
}

/**
 * Persisted email-link pending state key.
 */
const PENDING_EMAIL_LINK_KEY: string = 'auth.emailLink.pending';

/**
 * TTL for pending email-link state.
 *
 * TODO: confirm whether Firebase imposes a specific link lifetime that
 * should cap local pending state.
 */
const PENDING_EMAIL_LINK_TTL_MS: number = 1000 * 60 * 60 * 24;
