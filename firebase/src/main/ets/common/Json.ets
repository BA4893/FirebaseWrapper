import { http } from '@kit.NetworkKit';
import { FirebaseException, FirebaseErrorCode } from './FirebaseError';
import { HttpEnvelope } from './HttpTransport';

/**
 * JSON access helpers over the platform JSON module.
 *
 * Firestore / RTDB values are arbitrary JSON; these small typed accessors keep
 * the rest of the SDK free of dynamic property access.
 */
export class Json {
  static tryParse(text: string): Object | undefined {
    try {
      return JSON.parse(text);
    } catch (err) {
      return undefined;
    }
  }

  static string(obj: Object, key: string, fallback: string): string {
    const value: Object | undefined = obj[key];
    if (value === undefined) {
      return fallback;
    }
    return value as string;
  }

  static number(obj: Object, key: string, fallback: number): number {
    const value: Object | undefined = obj[key];
    if (value === undefined) {
      return fallback;
    }
    return value as number;
  }

  static boolean(obj: Object, key: string, fallback: boolean): boolean {
    const value: Object | undefined = obj[key];
    if (value === undefined) {
      return fallback;
    }
    return value as boolean;
  }

  static object(obj: Object, key: string): Object | undefined {
    const value: Object | undefined = obj[key];
    if (value === undefined) {
      return undefined;
    }
    return value as Object;
  }

  static stringArray(obj: Object, key: string): Array<string> {
    const value: Object | undefined = obj[key];
    if (value === undefined) {
      return new Array<string>();
    }
    const arr: Array<Object> = value as Array<Object>;
    const out: Array<string> = new Array<string>();
    for (let i: number = 0; i < arr.length; i++) {
      out.push(arr[i] as string);
    }
    return out;
  }

  /**
   * Parses a Firebase REST error body into a stable message.
   */
  static firebaseErrorMessage(text: string): string {
    const parsed: Object | undefined = Json.tryParse(text);
    if (parsed === undefined) {
      return text.length > 0 ? text : 'unknown error';
    }
    const error: Object | undefined = Json.object(parsed, 'error');
    if (error === undefined) {
      return Json.string(parsed, 'message', 'unknown error');
    }
    return Json.string(error, 'message', 'unknown error');
  }
}