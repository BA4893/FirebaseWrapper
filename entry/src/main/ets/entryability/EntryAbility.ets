import { AbilityConstant, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { FirebaseApp, FirebaseOptions, CrashContext, CrashDetails, ShimCrashDetails, ShimCrashKey,
  TelemetryShimConfig, analyticsShim, crashShim } from '@openharmony/firebase';
import { DemoConfig } from '../Config';

const DOMAIN = 0x0000;

function crashReporter(filesDir: string = ''): (d: CrashDetails) => void {
  try {
    const app = FirebaseApp.initialize(new FirebaseOptions(DemoConfig.API_KEY,
      DemoConfig.PROJECT_ID, DemoConfig.DATABASE_URL, DemoConfig.AUTH_DOMAIN, DemoConfig.APP_NAME)
      .withFilesDir(filesDir));
    const crash = app.crashlytics(new CrashContext('1.0.0', 'OpenHarmony', 'openharmony',
      `entry-${Date.now()}`, ''), () => {
    });
    crash.flushQueue();
    return (d: CrashDetails) => {
      crash.report(d);
    };
  } catch (err) {
    return (d: CrashDetails) => {
      hilog.error(DOMAIN, 'Crashlytics', 'report failed: %{public}s', JSON.stringify(err));
    };
  }
}

function shimConfig(): TelemetryShimConfig {
  if (DemoConfig.TELEMETRY_BACKEND === 'huawei') {
    return TelemetryShimConfig.huawei(DemoConfig.HUAWEI_APP_ID);
  }
  return TelemetryShimConfig.firebase();
}

function shimCrashReporter(filesDir: string = ''): {
  send: (d: ShimCrashDetails) => void,
  flushQueue: () => Promise<number>,
  analytics: any,
  config: TelemetryShimConfig
} {
  try {
    const app = FirebaseApp.initialize(new FirebaseOptions(DemoConfig.API_KEY,
      DemoConfig.PROJECT_ID, DemoConfig.DATABASE_URL, DemoConfig.AUTH_DOMAIN, DemoConfig.APP_NAME)
      .withFilesDir(filesDir));
    const config = shimConfig();
    const http = app.http;

    const queuePath = filesDir.length > 0 ? `${filesDir}/firebase.demo.crash.json` : '';
    let queue: any = undefined;
    if (queuePath.length > 0) {
      const KeyValueStoreClass = (require('@openharmony/firebase').KeyValueStore as any);
      queue = new KeyValueStoreClass(queuePath);
    }

    const context = new CrashContext('1.0.0', 'OpenHarmony', 'openharmony',
      `entry-${Date.now()}`, '');
    const errorSink = (err: Object): void => {
      hilog.error(DOMAIN, 'ShimCrashlytics', 'backend error: %{public}s', JSON.stringify(err));
    };

    const crash = crashShim(http, config, context, errorSink, queue);
    const analytics = analyticsShim(http, config, `demo-${Date.now()}`, errorSink);
    analytics.start();

    crash.flushQueue().then((sent: number) => {
      hilog.info(DOMAIN, 'ShimCrashlytics', 'flushed %{public}d pending reports', sent);
    }).catch((err: Error) => {
      hilog.error(DOMAIN, 'ShimCrashlytics', 'flush failed: %{public}s', JSON.stringify(err));
    });

    return {
      send: (d: ShimCrashDetails): void => {
        crash.report(d);
      },
      flushQueue: (): Promise<number> => {
        return crash.flushQueue();
      },
      analytics: analytics,
      config: config
    };
  } catch (err) {
    return {
      send: (d: ShimCrashDetails): void => {
        hilog.error(DOMAIN, 'ShimCrashlytics', 'report failed: %{public}s', JSON.stringify(err));
      },
      flushQueue: (): Promise<number> => Promise.resolve(0),
      analytics: null,
      config: shimConfig()
    };
  }
}


export default class EntryAbility extends UIAbility {
  private shimContext: any = null;

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    try {
      this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
    } catch (err) {
      hilog.error(DOMAIN, 'testTag', 'Failed to set colorMode. Cause: %{public}s', JSON.stringify(err));
    }
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onCreate');

    if (DemoConfig.TELEMETRY_BACKEND === 'huawei') {
      this.installShimCrashHook();
    } else {
      this.installCrashHook();
    }
  }

  private installCrashHook(): void {
    const send = crashReporter(this.context.filesDir);
    const handler = (reason: Object): void => {
      hilog.error(DOMAIN, 'Crashlytics', 'Unhandled: %{public}s', JSON.stringify(reason));
      try {
        const err: Error = reason instanceof Error ? reason : new Error(JSON.stringify(reason));
        send(CrashDetails.fromError(err));
      } catch (err) {
      }
    };
    try {
      const proc = globalThis.process as Object | undefined;
      if (proc !== undefined) {
        const on = proc['on'] as ((e: string, h: (r: Object) => void) => void) | undefined;
        if (on !== undefined) {
          on.call(proc, 'uncaughtException', handler);
          on.call(proc, 'unhandledRejection', handler);
        }
      }
    } catch (err) {
      hilog.error(DOMAIN, 'Crashlytics', 'hook failed: %{public}s', JSON.stringify(err));
    }
  }

  private installShimCrashHook(): void {
    const ctx = shimCrashReporter(this.context.filesDir);
    this.shimContext = ctx;

    const handler = (reason: Object): void => {
      hilog.error(DOMAIN, 'ShimCrashlytics', 'Unhandled: %{public}s', JSON.stringify(reason));
      try {
        const err: Error = reason instanceof Error ? reason : new Error(JSON.stringify(reason));
        const details = new ShimCrashDetails(err.name, err.message,
          err.stack !== undefined ? err.stack as string : '',
          new Array<ShimCrashKey>());
        ctx.send(details);
      } catch (err) {
      }
    };
    try {
      const proc = globalThis.process as Object | undefined;
      if (proc !== undefined) {
        const on = proc['on'] as ((e: string, h: (r: Object) => void) => void) | undefined;
        if (on !== undefined) {
          on.call(proc, 'uncaughtException', handler);
          on.call(proc, 'unhandledRejection', handler);
        }
      }
    } catch (err) {
      hilog.error(DOMAIN, 'ShimCrashlytics', 'shim hook failed: %{public}s', JSON.stringify(err));
    }
  }

  onDestroy(): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onDestroy');
    if (this.shimContext !== null && this.shimContext.analytics !== null) {
      try {
        this.shimContext.analytics.stop();
      } catch (err) {
      }
      this.shimContext = null;
    }
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    // Main window is created, set main page for this ability
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageCreate');

    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, 'testTag', 'Failed to load the content. Cause: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(DOMAIN, 'testTag', 'Succeeded in loading the content.');
    });
  }

  onWindowStageDestroy(): void {
    // Main window is destroyed, release UI related resources
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageDestroy');
  }

  onForeground(): void {
    // Ability has brought to foreground
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onForeground');
    if (this.shimContext !== null && this.shimContext.analytics !== null) {
      try {
        const ShimAnalyticsParamClass = (require('@openharmony/firebase').ShimAnalyticsParam as any);
        this.shimContext.analytics.logEvent('lifecycle', [new ShimAnalyticsParamClass('state', 'foreground')]);
      } catch (err) {
      }
    }
  }

  onBackground(): void {
    // Ability has back to background
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onBackground');
    if (this.shimContext !== null && this.shimContext.analytics !== null) {
      try {
        const ShimAnalyticsParamClass = (require('@openharmony/firebase').ShimAnalyticsParam as any);
        this.shimContext.analytics.logEvent('lifecycle', [new ShimAnalyticsParamClass('state', 'background')]);
      } catch (err) {
      }
    }
  }
}