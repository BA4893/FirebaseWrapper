import { AbilityConstant, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { FirebaseApp, FirebaseOptions, CrashContext, CrashDetails } from '@openharmony/firebase';
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

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    try {
      this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
    } catch (err) {
      hilog.error(DOMAIN, 'testTag', 'Failed to set colorMode. Cause: %{public}s', JSON.stringify(err));
    }
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onCreate');
    this.installCrashHook();
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

  onDestroy(): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onDestroy');
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
  }

  onBackground(): void {
    // Ability has back to background
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onBackground');
  }
}