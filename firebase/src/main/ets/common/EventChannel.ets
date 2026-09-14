/**
 * A generic typed pub/sub event channel.
 *
 * Used as the "payload bubble" between SDK services and view layers:
 *  - In-App Messaging pushes CampaignEntry events here,
 *  - FCM pushes decoded downstream messages here,
 *  - views subscribe and render (pure ArkTS, no native UI injection).
 */
export class EventChannel {
  private listeners: Array<ChannelListener>;
  private buffer: Array<ChannelEvent>;
  private maxBuffer: number;

  constructor(maxBuffer: number) {
    this.listeners = new Array<ChannelListener>();
    this.buffer = new Array<ChannelEvent>();
    this.maxBuffer = maxBuffer;
  }

  /**
   * Subscribes to events with a name prefix. Returns a handle to unsubscribe.
   */
  subscribe(prefix: string, handler: channelHandler): ChannelSubscription {
    const listener: ChannelListener = new ChannelListener(prefix, handler);
    this.listeners.push(listener);
    return new ChannelSubscription(this, listener);
  }

  /**
   * Fires an event with the given name and JSON-serializable payload.
   */
  emit(name: string, payload: Object): void {
    const event: ChannelEvent = new ChannelEvent(name, payload);
    for (let i: number = 0; i < this.listeners.length; i++) {
      const listener: ChannelListener = this.listeners[i];
      if (name.startsWith(listener.prefix)) {
        listener.handler(event);
      }
    }
    this.buffer.push(event);
    if (this.buffer.length > this.maxBuffer) {
      this.buffer.splice(0, this.buffer.length - this.maxBuffer);
    }
  }

  unsubscribe(subscription: ChannelSubscription): void {
    const target: ChannelListener = subscription.listener;
    for (let i: number = 0; i < this.listeners.length; i++) {
      if (this.listeners[i] === target) {
        this.listeners.splice(i, 1);
        return;
      }
    }
  }

  replay(prefix: string, handler: channelHandler): void {
    for (let i: number = 0; i < this.buffer.length; i++) {
      const event: ChannelEvent = this.buffer[i];
      if (event.name.startsWith(prefix)) {
        handler(event);
      }
    }
  }

  clear(): void {
    this.buffer.splice(0, this.buffer.length);
  }
}

export type channelHandler = (event: ChannelEvent) => void;

class ChannelListener {
  prefix: string;
  handler: channelHandler;

  constructor(prefix: string, handler: channelHandler) {
    this.prefix = prefix;
    this.handler = handler;
  }
}

/**
 * One fired event.
 */
export class ChannelEvent {
  name: string;
  payload: Object;
  emittedAt: number;

  constructor(name: string, payload: Object) {
    this.name = name;
    this.payload = payload;
    this.emittedAt = Date.now();
  }

  /**
   * Convenience getters over a JSON payload.
   */
  getString(key: string, fallback: string): string {
    const parsed: Object = JSON.parse(JSON.stringify(this.payload));
    const value: Object | undefined = parsed[key];
    if (value === undefined) {
      return fallback;
    }
    return value as string;
  }
}

/**
 * Handle returned by {@link EventChannel.subscribe}.
 */
export class ChannelSubscription {
  channel: EventChannel;
  listener: ChannelListener;

  constructor(channel: EventChannel, listener: ChannelListener) {
    this.channel = channel;
    this.listener = listener;
  }

  cancel(): void {
    this.channel.unsubscribe(this);
  }
}