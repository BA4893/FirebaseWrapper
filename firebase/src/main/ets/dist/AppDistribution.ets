import { HttpTransport } from '../common/HttpTransport';
import { FirebaseException } from '../common/FirebaseError';
import { Json } from '../common/Json';

/**
 * App Distribution — HarmonyOS AppTest equivalent of iOS TestFlight.
 *
 * Mapping (iOS `FirebaseAppDistribution` → HarmonyOS):
 * - TestFlight internal/external groups → AGC App Testing release tasks with
 *   tester allow-lists (`createRelease` in CI, `addTesters` here).
 * - TestFlight build upload → HAP bundle upload (`uploadRelease` returns an
 *   `uploadUrl`; CI PUTs the signed `.hap` there, then `commitRelease`).
 * - `checkForUpdate` (tester SDK) → polls `listReleases` and compares
 *   `versionCode` against the running build; `appTestUrl` opens the AGC
 *   AppTest install page when a newer build exists.
 * - Tester opt-in → `testerSignup` records the Installations FID against a
 *   release so the console shows uptake (mirrors iOS `testerSignIn`).
 *
 * Transport note: like iOS (which talks to
 * `firebaseappdistribution.googleapis.com` with an App Check-guarded token),
 * all calls here carry the Auth bearer and go to YOUR proxy by default — AGC
 * has no per-device open REST API for releases, so `endpoint` must point at
 * the proxy route that holds the AGC Connect server key. Pass '' to fail on
 * first call rather than silently leaking.
 */
export class AppDistribution {
  private transport: HttpTransport;
  private endpoint: string;
  private idToken: distTokenProvider;

  constructor(transport: HttpTransport, endpoint: string, idToken: distTokenProvider) {
    this.transport = transport;
    this.endpoint = AppDistribution.norm(endpoint);
    this.idToken = idToken;
  }

  /** Lists releases for an app (newest first). */
  async listReleases(appId: string): Promise<Array<DistRelease>> {
    const e = await this.transport.get(`${this.endpoint}/v1/apps/${appId}/releases`,
      [], await this.bearer());
    if (!e.isOk()) {
      throw FirebaseException.api('dist.list', Json.firebaseErrorMessage(e.text));
    }
    const p: Object | undefined = Json.tryParse(e.text);
    if (p === undefined) {
      throw FirebaseException.api('dist.list', 'malformed response');
    }
    const raw: Array<Object> | undefined = p['releases'] as Array<Object> | undefined;
    const out: Array<DistRelease> = new Array<DistRelease>();
    if (raw === undefined) {
      return out;
    }
    for (let i: number = 0; i < raw.length; i++) {
      const r: DistRelease | undefined = DistRelease.fromJson(raw[i]);
      if (r !== undefined) {
        out.push(r);
      }
    }
    return out;
  }

  /** Creates a release slot; returns the HAP upload URL for CI. */
  async uploadRelease(appId: string, versionName: string, versionCode: number,
    notes: string): Promise<DistUpload> {
    const body: Object = {};
    body['versionName'] = versionName;
    body['versionCode'] = versionCode;
    body['releaseNotes'] = notes;
    const e = await this.transport.post(`${this.endpoint}/v1/apps/${appId}/releases:upload`,
      JSON.stringify(body), [], await this.bearer());
    if (!e.isOk()) {
      throw FirebaseException.api('dist.upload', Json.firebaseErrorMessage(e.text));
    }
    const p: Object | undefined = Json.tryParse(e.text);
    if (p === undefined) {
      throw FirebaseException.api('dist.upload', 'malformed response');
    }
    return new DistUpload(Json.string(p, 'releaseId', ''), Json.string(p, 'uploadUrl', ''));
  }

  /** Commits an uploaded HAP so it becomes visible to testers. */
  async commitRelease(appId: string, releaseId: string): Promise<DistRelease> {
    const body: Object = {};
    body['releaseId'] = releaseId;
    const e = await this.transport.post(`${this.endpoint}/v1/apps/${appId}/releases:commit`,
      JSON.stringify(body), [], await this.bearer());
    if (!e.isOk()) {
      throw FirebaseException.api('dist.commit', Json.firebaseErrorMessage(e.text));
    }
    const p: Object | undefined = Json.tryParse(e.text);
    if (p === undefined) {
      throw FirebaseException.api('dist.commit', 'malformed response');
    }
    const r: DistRelease | undefined = DistRelease.fromJson(p);
    if (r === undefined) {
      throw FirebaseException.api('dist.commit', 'malformed release');
    }
    return r;
  }

  /** Adds tester emails to a release allow-list (TestFlight group). */
  async addTesters(appId: string, releaseId: string, emails: Array<string>): Promise<void> {
    const body: Object = {};
    body['releaseId'] = releaseId;
    body['emails'] = emails;
    const e = await this.transport.post(`${this.endpoint}/v1/apps/${appId}/testers:add`,
      JSON.stringify(body), [], await this.bearer());
    if (!e.isOk()) {
      throw FirebaseException.api('dist.testers', Json.firebaseErrorMessage(e.text));
    }
  }

  /**
   * Tester-side: returns the newest release newer than `currentVersionCode`,
   * or undefined when up to date (mirrors iOS `checkForUpdate`).
   */
  async checkForUpdate(appId: string, currentVersionCode: number): Promise<DistRelease | undefined> {
    const all: Array<DistRelease> = await this.listReleases(appId);
    let best: DistRelease | undefined = undefined;
    for (let i: number = 0; i < all.length; i++) {
      if (all[i].versionCode > currentVersionCode) {
        if (best === undefined || all[i].versionCode > best.versionCode) {
          best = all[i];
        }
      }
    }
    return best;
  }

  /** Records this device (FID) as a tester device of a release (uptake). */
  async testerSignup(appId: string, releaseId: string, fid: string): Promise<void> {
    const body: Object = {};
    body['releaseId'] = releaseId;
    body['fid'] = fid;
    const e = await this.transport.post(`${this.endpoint}/v1/apps/${appId}/testers:signup`,
      JSON.stringify(body), [], await this.bearer());
    if (!e.isOk()) {
      throw FirebaseException.api('dist.signup', Json.firebaseErrorMessage(e.text));
    }
  }

  private async bearer(): Promise<string> {
    const t: string = await this.idToken();
    return t.length > 0 ? `Bearer ${t}` : '';
  }

  private static norm(endpoint: string): string {
    let o: string = endpoint;
    while (o.endsWith('/')) {
      o = o.substring(0, o.length - 1);
    }
    return o;
  }
}

/** One test release (HAP build slot). */
export class DistRelease {
  releaseId: string;
  versionName: string;
  versionCode: number;
  notes: string;
  downloadUrl: string;
  /** Console AppTest install page; testers open this to get the build. */
  appTestUrl: string;
  createdAt: number;

  constructor(releaseId: string, versionName: string, versionCode: number,
    notes: string, downloadUrl: string, appTestUrl: string, createdAt: number) {
    this.releaseId = releaseId;
    this.versionName = versionName;
    this.versionCode = versionCode;
    this.notes = notes;
    this.downloadUrl = downloadUrl;
    this.appTestUrl = appTestUrl;
    this.createdAt = createdAt;
  }

  static fromJson(p: Object): DistRelease | undefined {
    const id: Object | undefined = p['releaseId'];
    if (id === undefined) {
      return undefined;
    }
    return new DistRelease(
      id as string,
      Json.string(p, 'versionName', ''),
      Json.number(p, 'versionCode', 0),
      Json.string(p, 'releaseNotes', ''),
      Json.string(p, 'downloadUrl', ''),
      Json.string(p, 'appTestUrl', ''),
      Json.number(p, 'createdAt', 0));
  }
}

/** Upload slot returned by `uploadRelease` for the CI HAP push. */
export class DistUpload {
  releaseId: string;
  uploadUrl: string;

  constructor(releaseId: string, uploadUrl: string) {
    this.releaseId = releaseId;
    this.uploadUrl = uploadUrl;
  }
}

export type distTokenProvider = () => Promise<string>;

