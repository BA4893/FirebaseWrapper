import { HttpTransport } from '../common/HttpTransport';
import { FirebaseException, FirebaseErrorCode } from '../common/FirebaseError';
import { Json } from '../common/Json';
import { EventChannel } from '../common/EventChannel';
import { MessagingOptions } from '../common/FirebaseConfig';

export const CHANNEL_CAMPAIGN: string = 'campaign';
export const CHANNEL_CAMPAIGN_EXPIRED: string = 'campaign:expired';
export const CHANNEL_CAMPAIGN_OPENED: string = 'campaign:opened';

/**
 * Normalized In-App Messaging campaign payload ("payload bubble").
 */
export class CampaignEntry {
  campaignId: string;
  name: string;
  title: string;
  body: string;
  /** Background hex color, e.g. "#1E3A5F". */
  backgroundColor: string;
  /** Deep-link URL opened when the user taps the campaign. */
  deepLinkUrl: string;
  imageUrl: string;
  /** Unix epoch ms window. */
  startAt: number;
  endAt: number;
  /** Opaque targeting metadata returned by the backend. */
  targeting: string;

  constructor(campaignId: string, name: string, title: string, body: string,
    backgroundColor: string, deepLinkUrl: string, imageUrl: string,
    startAt: number, endAt: number, targeting: string) {
    this.campaignId = campaignId;
    this.name = name;
    this.title = title;
    this.body = body;
    this.backgroundColor = backgroundColor;
    this.deepLinkUrl = deepLinkUrl;
    this.imageUrl = imageUrl;
    this.startAt = startAt;
    this.endAt = endAt;
    this.targeting = targeting;
  }

  isActive(now: number): boolean {
    return now >= this.startAt && now <= this.endAt;
  }

  toJson(): string {
    const body: Object = {};
    body['campaignId'] = this.campaignId;
    body['name'] = this.name;
    body['title'] = this.title;
    body['body'] = this.body;
    body['backgroundColor'] = this.backgroundColor;
    body['deepLinkUrl'] = this.deepLinkUrl;
    body['imageUrl'] = this.imageUrl;
    body['startAt'] = this.startAt;
    body['endAt'] = this.endAt;
    body['targeting'] = this.targeting;
    return JSON.stringify(body);
  }

  static fromJson(text: string): CampaignEntry | undefined {
    const parsed: Object | undefined = Json.tryParse(text);
    if (parsed === undefined) {
      return undefined;
    }
    return new CampaignEntry(
      Json.string(parsed, 'campaignId', ''),
      Json.string(parsed, 'name', ''),
      Json.string(parsed, 'title', ''),
      Json.string(parsed, 'body', ''),
      Json.string(parsed, 'backgroundColor', '#000000'),
      Json.string(parsed, 'deepLinkUrl', ''),
      Json.string(parsed, 'imageUrl', ''),
      Json.number(parsed, 'startAt', 0),
      Json.number(parsed, 'endAt', 0),
      Json.string(parsed, 'targeting', ''));
  }
}
/**
 * In-App Messaging client — CUSTOM-BACKEND ONLY in this SDK.
 *
 * Unlike the official iOS/Android SDKs (which fetch campaigns from the
 * Firebase console via Installations + analytics triggers), this client
 * polls `MessagingOptions.campaignBaseUrl` — your backend or a
 * Firebase-managed Remote Config app-messaging pipe — normalizes each entry
 * into {@link CampaignEntry}, and pushes them into the shared
 * {@link EventChannel}. Rendering (Overlay dialog) happens in the view
 * layer — never natively.
 */
export class InAppMessaging {
  private transport: HttpTransport;
  private projectId: string;
  private deviceId: string;
  private options: MessagingOptions;
  private channel: EventChannel;
  private tokenProvider: stringProvider;
  private timerId: number;
  private lastRefreshAt: number;

  constructor(transport: HttpTransport, projectId: string, deviceId: string,
    options: MessagingOptions, channel: EventChannel, tokenProvider: stringProvider) {
    this.transport = transport;
    this.projectId = projectId;
    this.deviceId = deviceId;
    this.options = options;
    this.channel = channel;
    this.tokenProvider = tokenProvider;
    this.timerId = 0;
    this.lastRefreshAt = 0;
  }

  /**
   * Fetches active campaigns once and emits `campaign:*` events.
   */
  async refresh(): Promise<Array<CampaignEntry>> {
    this.lastRefreshAt = Date.now();
    const url: string = `${this.options.campaignBaseUrl}?project=${this.projectId}&device=${this.deviceId}`;
    let token: string = '';
    try {
      token = await this.tokenProvider();
    } catch (err) {
      token = '';
    }
    const envelope = await this.transport.get(url, [], token.length > 0 ? `Bearer ${token}` : '');
    if (!envelope.isOk()) {
      throw FirebaseException.api('in-app-messaging', Json.firebaseErrorMessage(envelope.text));
    }
    return this.dispatch(Json.tryParse(envelope.text));
  }

  /**
   * Starts periodic foreground polling.
   */
  startPolling(): void {
    if (this.timerId !== 0) {
      return;
    }
    this.timerId = setInterval(() => {
      this.refresh().catch((err: Error) => {
        // Non-fatal: keep the existing campaign state.
      });
    }, this.options.pollIntervalMs);
  }

  stopPolling(): void {
    if (this.timerId !== 0) {
      clearInterval(this.timerId);
      this.timerId = 0;
    }
  }

  /**
   * Signals to the view layer that the user tapped the deep link.
   */
  open(campaign: CampaignEntry): void {
    this.channel.emit(CHANNEL_CAMPAIGN_OPENED, JSON.parse(campaign.toJson()));
  }

  private dispatch(raw: Object | undefined): Array<CampaignEntry> {
    const out: Array<CampaignEntry> = new Array<CampaignEntry>();
    if (raw === undefined) {
      return out;
    }
    const now: number = Date.now();
    // Tolerates { campaigns:[...] } from a custom proxy and { entries:[...] } from RC pipes.
    const campaigns: Array<Object> | undefined = raw['campaigns'] as Array<Object> | undefined;
    const entries: Array<Object> | undefined = raw['entries'] as Array<Object> | undefined;
    const source: Array<Object> = campaigns !== undefined ? campaigns :
      (entries !== undefined ? entries : new Array<Object>());
    for (let i: number = 0; i < source.length; i++) {
      const entry: Object = source[i];
      const campaign: CampaignEntry = CampaignEntry.fromJson(JSON.stringify(entry)) as CampaignEntry;
      if (campaign.campaignId === '') {
        continue;
      }
      const name: string = campaign.isActive(now) ? CHANNEL_CAMPAIGN : CHANNEL_CAMPAIGN_EXPIRED;
      this.channel.emit(name, JSON.parse(campaign.toJson()));
      out.push(campaign);
    }
    return out;
  }
}

export type stringProvider = () => Promise<string>;