/**
 * Paste your Firebase web config here (Project Settings -> General).
 * Never commit production keys: this demo reads placeholders by default.
 *
 * Telemetry shim switch:
 *  - `TELEMETRY_BACKEND` selects which telemetry backend the app uses.
 *  - Current valid values: 'firebase' | 'huawei'
 *  - 'huawei' compiles, but the Huawei backend is a no-op shell until its
 *    wire contract is implemented.
 */
export class DemoConfig {
  static readonly API_KEY: string = 'PASTE_API_KEY';
  static readonly PROJECT_ID: string = 'demo-project';
  static readonly AUTH_DOMAIN: string = 'demo-project.firebaseapp.com';
  static readonly DATABASE_URL: string = 'demo-project-default-rtdb';
  static readonly APP_NAME: string = 'demo';
  static readonly SENDER_ID: string = '12345@fcm.googleapis.com';
  static readonly PROXY_BASE_URL: string = '';

  /**
   * Selected telemetry backend for the demo app.
   *
   * Default: 'firebase'.
   */
  static readonly TELEMETRY_BACKEND: string = 'firebase';

  /**
   * Huawei app identifier used by the Huawei telemetry backend, when enabled.
   *
   * Placeholder until the Huawei backend is implemented.
   */
  static readonly HUAWEI_APP_ID: string = '';
}

