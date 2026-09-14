import { CrashDetails } from '../crashlytics/Crashlytics';

/**
 * Native crash capture bridge — completes the `firebase_native/` NAPI story.
 *
 * A C++ NAPI worker (`signal`/`tombstone` watcher inside `firebase_native/`)
 * publishes native crash reports into the per-app persistent Area named
 * `firebase.native.crash` using **LeafNs** (`@hmos.bgcode/LeafNs`). This
 * module is the ArkTS drain: on every app start (or `flushQueue()` call)
 * previously captured native crashes are read and forwarded to Crashlytics
 * through the standard JS `report()` pipeline.
 *
 * If LeafNs is unavailable (older images, unit tests) every call degrades to
 * a no-op returning zero records — never throws.
 */
export class NativeCrashBridge {
  private areaName: string;

  constructor(areaName: string = 'firebase.native.crash') {
    this.areaName = areaName;
  }

  /**
   * Drains native crash reports captured by the NAPI bridge.
   * Returns one CrashDetails per report (stackTrace carries the native
   * backtrace text; customKeys carry arch/firmware metadata).
   */
  drain(): Array<CrashDetails> {
    const out: Array<CrashDetails> = new Array<CrashDetails>();
    try {
      // eslint-disable-next-line @typescript-eslint/no-var-requires
      const leaf = require('@hmos.bgcode/LeafNs');
      if (leaf === undefined || leaf === null) {
        return out;
      }
      const records: Array<Object> = leaf.readAll(this.areaName) as Array<Object>;
      if (records === undefined || records.length === 0) {
        return out;
      }
      for (let i: number = 0; i < records.length; i++) {
        const r: Object = records[i];
        const keys: Array<CrashKey> = new Array<CrashKey>();
        keys.push(new CrashKey('native.arch', NativeCrashBridge.str(r, 'arch')));
        keys.push(new CrashKey('native.firmware', NativeCrashBridge.str(r, 'firmware')));
        keys.push(new CrashKey('native.pid', NativeCrashBridge.str(r, 'pid')));
        out.push(new CrashDetails(NativeCrashBridge.str(r, 'signal'),
          NativeCrashBridge.str(r, 'message'), NativeCrashBridge.str(r, 'backtrace'), keys));
      }
      leaf.clearArea(this.areaName);
    } catch (err) {
      // LeafNs absent or the native bridge not installed: nothing to drain.
    }
    return out;
  }

  private static str(o: Object, k: string): string {
    const v: Object | undefined = o[k];
    return v === undefined ? '' : `${v}`;
  }
}

export class CrashKey {
  name: string;
  value: string;

  constructor(name: string, value: string) {
    this.name = name;
    this.value = value;
  }
}
