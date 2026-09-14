/**
 * Handle for a streaming SSE subscription. Re-arms the long-poll on each
 * server window close; parses `event:`/`data:` frames incrementally.
 */
export class SseStream {
  private transport: HttpTransport;
  private url: string;
  private headers: Array<HeaderPair>;
  private auth: string;
  private onEvent: sseEventHandler;
  private onError: sseErrorHandler;
  private stopped: boolean;
  private backoffMs: number;

  constructor(transport: HttpTransport, url: string, headers: Array<HeaderPair>, auth: string,
    onEvent: sseEventHandler, onError: sseErrorHandler) {
    this.transport = transport;
    this.url = url;
    this.headers = headers;
    this.auth = auth;
    this.onEvent = onEvent;
    this.onError = onError;
    this.stopped = false;
    this.backoffMs = 1000;
  }

  start(): void {
    this.loop().catch((err: Error) => {
      this.onError(err);
    });
  }

  stop(): void {
    this.stopped = true;
  }

  isStopped(): boolean {
    return this.stopped;
  }

  private async loop(): Promise<void> {
    while (!this.stopped) {
      try {
        const envelope: HttpEnvelope = await this.transport.requestOnce(this.url, this.headers, this.auth);
        if (!envelope.isOk()) {
          throw FirebaseException.network(`SSE stream HTTP ${envelope.status}`, undefined);
        }
        SseStream.dispatchText(envelope.text, this.onEvent);
        this.backoffMs = 1000;
      } catch (err) {
        if (this.stopped) {
          return;
        }
        this.onError(err as Error);
        await SseStream.sleep(this.backoffMs);
        this.backoffMs = Math.min(this.backoffMs * 2, 30000);
      }
    }
  }

  /** Parses raw SSE text into (event, data) pairs. Public for unit tests. */
  static dispatchText(text: string, onEvent: sseEventHandler): void {
    const blocks: Array<string> = text.split('\n\n');
    for (let i: number = 0; i < blocks.length; i++) {
      const lines: Array<string> = blocks[i].split('\n');
      let name: string = 'message';
      let data: string = '';
      for (let j: number = 0; j < lines.length; j++) {
        if (lines[j].startsWith('event:')) {
          name = lines[j].substring(6).trim();
        } else if (lines[j].startsWith('data:')) {
          data += lines[j].substring(5).trim();
        }
      }
      if (data.length > 0) {
        onEvent(name, data);
      }
    }
  }

  private static sleep(ms: number): Promise<void> {
    return new Promise<void>((resolve: () => void) => {
      setTimeout(() => {
        resolve();
      }, ms);
    });
  }
}

export type sseEventHandler = (event: string, data: string) => void;
export type sseErrorHandler = (error: Error) => void;
