import { notificationManager } from '@kit.NotificationKit';

/**
 * Local OS notifications via **Notification Kit** — the UI half of the push story.
 *
 * Push Kit delivers the message; when it arrives as a silent/data message the
 * app hands the payload here to surface it in the notification center. This is
 * the iOS parity of building `UNMutableNotificationContent` in response to a
 * silent push or `MessagingDelegate` callback.
 */
export class LocalNotifier {
  /** True when the user has granted notification authorization. */
  async enabled(): Promise<boolean> {
    try {
      return await notificationManager.isNotificationEnabled();
    } catch (err) {
      return false;
    }
  }

  /**
   * Posts a basic-text notification. `id` is caller-chosen so it can be
   * cancelled later or reused to update in place (iOS `identifier` analog).
   */
  async publish(id: number, title: string, text: string): Promise<number> {
    const normal: notificationManager.NotificationBasicContent = {
      title: title,
      text: text,
      additionalText: '',
    };
    const content: notificationManager.NotificationContent = {
      notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
      normal: normal,
    };
    const request: notificationManager.NotificationRequest = {
      id: id,
      content: content,
      slotType: notificationManager.SlotType.SOCIAL_COMMUNICATION,
    };
    await notificationManager.publish(request);
    return id;
  }

  /** Cancels a previously published notification by id. */
  async cancel(id: number): Promise<void> {
    try {
      await notificationManager.cancel(id);
    } catch (err) {
      // Already removed or not authorized — cancellation is best-effort.
    }
  }
}
