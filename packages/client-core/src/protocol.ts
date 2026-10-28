export interface BridgeError {
  code: string;
  message: string;
}
export type Completion<T> = (error: BridgeError | null, result?: T) => void;
export interface Adapter {
  connect(
    receiver: (text: string) => void,
    onDisconnect: (error: BridgeError) => void,
  ): Promise<void>;
  send(text: string): Promise<void>;
  close(): Promise<void>;
}
export interface CallOptions {
  timeoutMs?: number;
  extra?: string;
}
/** 中间结果与终态结果分离；终态错误始终交给 onError。 */
export interface CallCallbacks<T> {
  onData?: (result: T) => void;
  onComplete: (result: T) => void;
  onError: (error: BridgeError) => void;
}
export interface CallHandle {
  callbackId: string;
  cancel(reason?: string): Promise<{ accepted: boolean }>;
}
export const failure = (code: string, message: string): BridgeError => ({ code, message });
export function utf8Size(text: string): number {
  let size = 0;
  for (const c of text) {
    const n = c.codePointAt(0);
    if (n === undefined) throw Error('Missing Unicode code point');
    size += n <= 0x7f ? 1 : n <= 0x7ff ? 2 : n <= 0xffff ? 3 : 4;
  }
  return size;
}
export function assertJSON(value: unknown, seen = new Set<object>(), depth = 0): void {
  if (depth > 32) throw failure('INVALID_ARGUMENT', 'JSON nesting exceeds 32');
  if (value === null || typeof value === 'string' || typeof value === 'boolean') return;
  if (
    typeof value === 'number' &&
    Number.isFinite(value) &&
    (!Number.isInteger(value) || Number.isSafeInteger(value))
  )
    return;
  if (typeof value !== 'object' || !value)
    throw failure('INVALID_ARGUMENT', 'Unsupported JSON value');
  if (seen.has(value)) throw failure('INVALID_ARGUMENT', 'Circular params');
  if (
    !Array.isArray(value) &&
    Object.getPrototypeOf(value) !== Object.prototype &&
    Object.getPrototypeOf(value) !== null
  )
    throw failure('INVALID_ARGUMENT', 'Params must contain plain JSON values');
  seen.add(value);
  for (const [key, item] of Object.entries(value)) {
    if (['__proto__', 'prototype', 'constructor'].includes(key))
      throw failure('INVALID_ARGUMENT', 'Reserved key');
    assertJSON(item, seen, depth + 1);
  }
  seen.delete(value);
}

export interface Subscription {
  subscriptionId: string;
  unsubscribe(): Promise<{ accepted: boolean }>;
}
