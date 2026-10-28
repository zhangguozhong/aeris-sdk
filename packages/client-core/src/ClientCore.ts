import { PendingCall } from './PendingCall.js';
import { BridgeDiagnostics } from './diagnostics.js';
import { BridgeDeliveryQueue } from './flowControl.js';
import type { ClientOptions } from './flowControl.js';
import { assertJSON, failure, utf8Size } from './protocol.js';
import { decodeResponse, isResponseId, validateResponse } from './responseValidation.js';
import type {
  Adapter,
  BridgeError,
  CallHandle,
  CallOptions,
  Completion,
  CallCallbacks,
  Subscription,
} from './protocol.js';
type EventRecord = {
  id: string;
  acked: boolean;
  last: number;
  phase: 'active' | 'terminal' | 'off';
  buffer: Map<number, Record<string, unknown>>;
  gap?: ReturnType<typeof setTimeout>;
  off?: Promise<{ accepted: boolean }>;
  offNeeded?: boolean;
  data: (data: Record<string, unknown>) => void;
  error?: (e: BridgeError) => void;
  complete?: () => void;
};
type Pending = {
  started: number;
  lane: 'control';
  finish: Completion<unknown>;
  timer: ReturnType<typeof setTimeout>;
};

/** 仅管理协议与请求，不导入 React Native。 */
export class ClientCore {
  private readonly adapter: Adapter;
  private readonly pending = new Map<string, Pending>();
  private readonly calls = new Map<string, PendingCall>();
  private readonly subscriptions = new Map<string, EventRecord>();
  private readonly prefix =
    globalThis.crypto?.randomUUID?.() ??
    `${Date.now().toString(36)}-${Math.random().toString(36).slice(2)}-${Math.random().toString(36).slice(2)}`;
  private counter = 0;
  private state: 'new' | 'connecting' | 'ready' | 'closed' = 'new';
  private helloCallbackId?: string;
  private handshake?: {
    resolve: () => void;
    reject: (e: BridgeError) => void;
    timer: ReturnType<typeof setTimeout>;
  };
  private readyPromise?: Promise<void>;
  private closeTask?: Promise<void>;
  private readonly onCallbackError: (e: unknown) => void;
  readonly diagnostics: BridgeDiagnostics;
  private readonly delivery: BridgeDeliveryQueue;
  private readonly frameBytes = new WeakMap<object, number>();
  constructor(
    adapter: Adapter,
    onCallbackError: (e: unknown) => void = console.error,
    options: ClientOptions = {},
  ) {
    this.adapter = adapter;
    this.onCallbackError = onCallbackError;
    this.diagnostics = options.diagnostics ?? new BridgeDiagnostics();
    this.delivery = new BridgeDeliveryQueue(
      this.diagnostics,
      () => {
        this.shutdown(failure('BACKPRESSURE', 'Bridge callback queue exceeded'));
        this.log('backpressure', { code: 'BACKPRESSURE' });
      },
      options.flowLimits,
    );
  }
  private log(stage: string, fields: Parameters<BridgeDiagnostics['record']>[1] = {}): void {
    this.diagnostics.record(stage, { clientId: this.prefix, ...fields });
  }
  private callbackError(e: unknown): void {
    this.log('callback.exception');
    try {
      this.onCallbackError(e);
    } catch {}
  }
  private critical(error: BridgeError): BridgeError {
    return {
      code:
        typeof error.code === 'string' && /^[A-Z][A-Z0-9_]{0,63}$/.test(error.code)
          ? error.code
          : 'DISCONNECTED',
      message:
        typeof error.message === 'string' ? error.message.slice(0, 256) : 'Bridge disconnected',
    };
  }
  private weight(m: object): number {
    return this.frameBytes.get(m) ?? 256;
  }
  private queue(
    run: () => void,
    bytes: number,
    discard?: () => void,
    urgent = false,
    fields: Parameters<BridgeDiagnostics['record']>[1] = {},
  ): boolean {
    const accepted = this.delivery.post(run, bytes, discard, urgent);
    if (accepted) this.log('callback.enqueue', fields);
    return accepted;
  }
  private canTransmit(id?: string): boolean {
    return (
      this.state !== 'closed' &&
      (!id || this.pending.has(id) || this.calls.get(id)?.isPending === true)
    );
  }
  private nextId(): string {
    return `${this.prefix}:${++this.counter}`;
  }

  ready(): Promise<void> {
    if (this.state === 'closed') return Promise.reject(failure('DISCONNECTED', 'Bridge is closed'));
    if (this.readyPromise) return this.readyPromise;
    this.state = 'connecting';
    this.helloCallbackId = this.nextId();
    this.readyPromise = new Promise((resolve, reject) => {
      this.handshake = {
        resolve,
        reject,
        timer: setTimeout(() => this.shutdown(failure('TIMEOUT', 'Handshake timed out')), 5000),
      };
    });
    void this.adapter
      .connect(
        (text) => this.receive(text),
        (error) => this.shutdown(error, error.code !== 'DISCONNECTED'),
      )
      .then(() => {
        if (this.state !== 'connecting') {
          void this.adapter.close().catch(() => {});
          return;
        }
        this.transmit({ callbackId: this.helloCallbackId, method: 'bridge.hello', params: {} });
      })
      .catch(() => this.shutdown(failure('BRIDGE_UNAVAILABLE', 'Cannot connect to native bridge')));
    return this.readyPromise;
  }

  /** 统一请求 API：回调仅决定本地交付，Native 决定进度帧和终态帧。 */
  call<T>(
    method: string,
    params: Record<string, unknown>,
    callback: Completion<T> | CallCallbacks<T>,
    options: CallOptions = {},
  ): CallHandle {
    this.delivery.assertAdmission(this.state === 'closed');
    const normalized: CallCallbacks<T> =
      typeof callback === 'function' ? this.normalizeCompletion(callback) : callback;
    const id = this.nextId(),
      call = this.makePendingCall(id, (normalized ?? {}) as CallCallbacks<unknown>);
    const handle: CallHandle = { callbackId: id, cancel: (reason) => call.cancel(reason) };
    try {
      const timeoutMs = this.validateCall(method, params, options);
      if (
        !normalized ||
        typeof normalized.onComplete !== 'function' ||
        typeof normalized.onError !== 'function' ||
        (normalized.onData !== undefined && typeof normalized.onData !== 'function')
      )
        throw failure('INVALID_ARGUMENT', 'Expected a completion or call callbacks');
      this.assertPendingCapacity('business');
      this.calls.set(id, call);
      this.diagnostics.gauge('calls', 1);
      call.start(timeoutMs);
      this.transmit(
        {
          callbackId: id,
          method,
          params,
          ...(options.timeoutMs === undefined ? {} : { timeoutMs }),
          ...(options.extra === undefined ? {} : { extra: options.extra }),
        },
        id,
      );
    } catch (error) {
      call.reject(this.asError(error));
    }
    return handle;
  }
  // 使用独立作用域，防止保留的取消句柄继续持有原始完成回调。
  private normalizeCompletion<T>(callback: Completion<T>): CallCallbacks<T> {
    return { onComplete: (result) => callback(null, result), onError: (error) => callback(error) };
  }
  private makePendingCall(id: string, callbacks: CallCallbacks<unknown>): PendingCall {
    return new PendingCall(id, callbacks, {
      diagnostics: this.diagnostics,
      closed: () => this.state === 'closed',
      failed: () => this.delivery.failed,
      queue: (run, bytes, discard, urgent, fields) =>
        this.queue(run, bytes, discard, urgent, fields),
      remove: (call) => {
        if (this.calls.get(call.id) === call) {
          this.calls.delete(call.id);
          this.diagnostics.gauge('calls', -1);
        }
      },
      cancelNative: (targetCallbackId, reason) =>
        this.control<{ accepted: boolean }>('bridge.cancel', { targetCallbackId, reason }),
      log: (stage, fields) => this.log(stage, fields),
      callbackError: (error) => this.callbackError(error),
    });
  }
  private validateCall(
    method: string,
    params: Record<string, unknown>,
    options: CallOptions,
  ): number {
    if (this.state !== 'ready') throw failure('NOT_READY', 'Await bridge.ready() first');
    if (
      typeof method !== 'string' ||
      utf8Size(method) > 256 ||
      !/^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)?$/.test(method) ||
      method.split('.').some((x) => ['constructor', 'prototype', '__proto__'].includes(x))
    )
      throw failure('INVALID_METHOD', 'Invalid method name');
    if (method.startsWith('bridge.'))
      throw failure('INVALID_METHOD', 'System methods are reserved for SDK lifecycle APIs');
    if (!params || Array.isArray(params) || typeof params !== 'object')
      throw failure('INVALID_ARGUMENT', 'params must be an object');
    assertJSON(params);
    if (options.extra !== undefined && typeof options.extra !== 'string')
      throw failure('INVALID_ARGUMENT', 'extra must be a string');
    if (
      options.extra !== undefined &&
      utf8Size(JSON.stringify({ extra: options.extra })) > 255 * 1024
    )
      throw failure('PAYLOAD_TOO_LARGE', 'extra leaves no response headroom');
    const timeoutMs = options.timeoutMs ?? 120000;
    if (!Number.isInteger(timeoutMs) || timeoutMs < 1 || timeoutMs > 600000)
      throw failure('INVALID_ARGUMENT', 'Invalid timeoutMs');
    return timeoutMs;
  }
  async subscribe(
    topic: string,
    onData: (data: Record<string, unknown>) => void,
    onError?: (error: BridgeError) => void,
    onComplete?: () => void,
  ): Promise<Subscription> {
    if (this.state !== 'ready') throw failure('NOT_READY', 'Await bridge.ready() first');
    if (
      typeof topic !== 'string' ||
      topic.length < 1 ||
      topic.length > 128 ||
      !/^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)*(?![\s\S])/.test(topic)
    )
      throw failure('INVALID_ARGUMENT', 'Invalid event topic');
    if (
      typeof onData !== 'function' ||
      (onError !== undefined && typeof onError !== 'function') ||
      (onComplete !== undefined && typeof onComplete !== 'function')
    )
      throw failure('INVALID_ARGUMENT', 'Expected event callbacks');
    if (this.subscriptions.size >= 32)
      throw failure('TOO_MANY_SUBSCRIPTIONS', 'Subscription limit reached');
    const id = this.nextId(),
      s: EventRecord = {
        id,
        acked: false,
        last: 0,
        phase: 'active',
        buffer: new Map(),
        data: onData,
        error: onError,
        complete: onComplete,
      };
    this.subscriptions.set(id, s);
    this.diagnostics.gauge('subscriptions', 1); // 先于 Native 可能同步发送的确认或初始快照执行。
    try {
      await this.control<{ subscriptionId: string }>(
        'bridge.subscribe',
        { topic, subscriptionId: id },
        (result) => {
          if (!result || result.subscriptionId !== id)
            throw failure('PROTOCOL_ERROR', 'Invalid subscription acknowledgement');
          s.acked = true;
          this.drainEvents(s);
        },
        () => this.stopSubscription(s),
      );
      if (s.phase === 'off') throw failure('DISCONNECTED', 'Bridge is closed');
    } catch (e) {
      this.stopSubscription(s);
      this.bestEffortOff(id);
      throw e;
    }
    return { subscriptionId: id, unsubscribe: () => this.unsubscribe(s) };
  }
  private clearStream(s: EventRecord): void {
    if (s.gap !== undefined) clearTimeout(s.gap);
    s.gap = undefined;
    s.buffer.clear();
    if (this.subscriptions.delete(s.id)) this.diagnostics.gauge('subscriptions', -1);
  }
  private releaseCallbacks(s: EventRecord): void {
    s.data = () => {};
    s.error = undefined;
    s.complete = undefined;
  }
  private stopSubscription(s: EventRecord): void {
    s.phase = 'off';
    this.clearStream(s);
    this.releaseCallbacks(s);
  }
  private unsubscribe(s: EventRecord): Promise<{ accepted: boolean }> {
    if (s.off) return s.off;
    s.offNeeded ??= s.phase === 'active';
    let resolve!: (value: { accepted: boolean }) => void;
    let reject!: (error: unknown) => void;
    const attempt = new Promise<{ accepted: boolean }>((done, failed) => {
      resolve = done;
      reject = failed;
    });
    // 先发布共享任务，再执行可能触发诊断观察者或 Adapter 重入的动作。
    s.off = attempt;
    this.stopSubscription(s);
    const result =
      s.offNeeded && this.state === 'ready'
        ? this.control<{ accepted: boolean }>('bridge.unsubscribe', { subscriptionId: s.id }).then(
            (r) => {
              s.offNeeded = false; // false 同样确认 Native 已无此订阅。
              return r;
            },
          )
        : Promise.resolve({ accepted: false });
    // 失败不永久占用句柄；重试只清理 Native，不重新激活数据回调。
    void result.then(resolve, (error) => {
      if (s.off === attempt) s.off = undefined;
      reject(error);
    });
    return attempt;
  }
  private bestEffortOff(id: string): void {
    if (this.state === 'ready')
      void this.control('bridge.unsubscribe', { subscriptionId: id }).catch(() => {});
  }
  private eventDeliverable(s: EventRecord): boolean {
    return this.state !== 'closed' && s.phase !== 'off';
  }
  private queueEvent(s: EventRecord, action: () => void, bytes = 256): void {
    this.queue(
      () => {
        if (!this.eventDeliverable(s)) return;
        this.log('callback.deliver', { subscriptionId: s.id });
        if (!this.eventDeliverable(s)) return;
        try {
          action();
        } catch (e) {
          this.callbackError(e);
        }
      },
      bytes,
      undefined,
      false,
      { subscriptionId: s.id },
    );
  }
  private failStream(s: EventRecord, error: BridgeError): void {
    if (s.phase !== 'active') return;
    s.phase = 'terminal';
    this.clearStream(s);
    if (s.error) {
      const fn = s.error;
      this.queueEvent(s, () => fn(error));
    }
    this.releaseCallbacks(s);
    this.bestEffortOff(s.id);
  }
  private receiveEvent(m: Record<string, unknown>): void {
    const s = this.subscriptions.get(m.subscriptionId as string);
    if (!s || s.phase !== 'active') return;
    try {
      const seq = m.seq;
      if ((seq as number) <= s.last || s.buffer.has(seq as number)) return;
      if (!s.acked) {
        if (s.buffer.size >= 32) throw Error('Early event overflow');
        s.buffer.set(seq as number, m);
        return;
      }
      if ((seq as number) > s.last + 1) {
        if (s.buffer.size >= 32) throw Error('Reorder overflow');
        s.buffer.set(seq as number, m);
        if (s.gap === undefined)
          s.gap = setTimeout(
            () => this.failStream(s, failure('PROTOCOL_ERROR', 'Event sequence gap timed out')),
            2000,
          );
        return;
      }
      this.dispatchEvent(s, m);
      this.drainEvents(s);
    } catch {
      this.failStream(s, failure('PROTOCOL_ERROR', 'Invalid event stream'));
    }
  }
  private drainEvents(s: EventRecord): void {
    while (s.phase === 'active' && s.buffer.has(s.last + 1)) {
      const next = s.buffer.get(s.last + 1);
      if (!next) throw Error('Missing buffered event');
      s.buffer.delete(s.last + 1);
      this.dispatchEvent(s, next);
    }
    if (s.buffer.size === 0 && s.gap !== undefined) {
      clearTimeout(s.gap);
      s.gap = undefined;
    } else if (s.phase === 'active' && s.buffer.size > 0 && s.gap === undefined)
      s.gap = setTimeout(
        () => this.failStream(s, failure('PROTOCOL_ERROR', 'Event sequence gap timed out')),
        2000,
      );
  }
  private dispatchEvent(s: EventRecord, m: Record<string, unknown>): void {
    s.last = m.seq as number;
    if (Object.hasOwn(m, 'data')) {
      const fn = s.data;
      this.queueEvent(s, () => fn(m.data as Record<string, unknown>), this.weight(m));
      return;
    }
    s.phase = 'terminal';
    this.clearStream(s);
    if (Object.hasOwn(m, 'error')) {
      if (s.error) {
        const fn = s.error;
        this.queueEvent(s, () => fn(m.error as BridgeError), this.weight(m));
      }
    } else if (s.complete) {
      const fn = s.complete;
      this.queueEvent(s, fn, this.weight(m));
    }
    this.releaseCallbacks(s);
  }
  private assertPendingCapacity(lane: 'business' | 'control'): void {
    const ordinary = lane === 'control' ? this.pending.size : 0;
    const activeCalls =
      lane === 'business'
        ? Array.from(this.calls.values()).filter((call) => call.isPending).length
        : 0;
    if (ordinary + activeCalls >= (lane === 'business' ? 128 : 16))
      throw failure('TOO_MANY_REQUESTS', 'Pending limit reached');
  }
  private register(callbackId: string, callback: Completion<unknown>, timeoutMs: number): void {
    const lane = 'control' as const;
    this.assertPendingCapacity(lane);
    const timer = setTimeout(() => {
      this.finish(
        callbackId,
        failure('TIMEOUT', 'Request timed out; native side effects may still have occurred'),
      );
      this.log('timeout', { callbackId, code: 'TIMEOUT' });
    }, timeoutMs);
    this.pending.set(callbackId, {
      started: this.diagnostics.now(),
      finish: callback,
      timer,
      lane,
    });
    this.diagnostics.gauge('pending.' + lane, 1); // 必须先于发送执行。
  }
  private control<T>(
    method: string,
    params: Record<string, unknown>,
    validate?: (result: T) => void,
    onFailure?: (error: BridgeError) => void,
  ): Promise<T> {
    return new Promise((resolve, reject) => {
      if (this.state !== 'ready') {
        reject(failure('DISCONNECTED', 'Bridge is closed'));
        return;
      }
      const callbackId = this.nextId();
      try {
        this.register(
          callbackId,
          (error, result) => {
            if (error) {
              onFailure?.(error);
              reject(error);
              return;
            }
            try {
              if (
                (method === 'bridge.cancel' || method === 'bridge.unsubscribe') &&
                typeof (result as { accepted?: unknown })?.accepted !== 'boolean'
              )
                throw failure('PROTOCOL_ERROR', 'Invalid control acknowledgement');
              validate?.(result as T);
              resolve(result as T);
            } catch (e) {
              const failure = this.asError(e);
              onFailure?.(failure);
              reject(failure);
            }
          },
          5000,
        );
        this.transmit({ callbackId, method, params }, callbackId);
      } catch (e) {
        if (this.pending.has(callbackId)) this.finish(callbackId, this.asError(e));
        else reject(e);
      }
    });
  }
  private transmit(message: object, callbackId?: string): void {
    if (!this.canTransmit(callbackId)) return;
    const raw = JSON.stringify(message);
    const fields = message as Record<string, unknown>;
    this.log('start', { callbackId: fields.callbackId as string, method: fields.method as string });
    this.log('send', { callbackId: fields.callbackId as string, method: fields.method as string });
    if (!this.canTransmit(callbackId)) return;
    if (utf8Size(raw) > 256 * 1024) throw failure('PAYLOAD_TOO_LARGE', 'Message exceeds 256 KiB');
    const failed = () => {
      // 迟到的传输错误不能替换已完成的响应。
      if (!callbackId || this.canTransmit(callbackId))
        this.shutdown(failure('DISCONNECTED', 'Native transport send failed'));
    };
    try {
      void this.adapter.send(raw).catch(failed);
    } catch {
      failed();
    }
  }
  private receive(raw: string): void {
    if (this.state === 'closed') return;
    try {
      const m = decodeResponse(raw);
      this.log('receive', {
        callbackId: m.callbackId as string,
        subscriptionId: m.subscriptionId as string,
      });
      this.frameBytes.set(m, utf8Size(raw));
      if (m.method === 'bridge.close') {
        this.nativeClose(m, raw);
        return;
      }
      const callback = typeof m.callbackId === 'string' ? m.callbackId : undefined;
      const call = callback ? this.calls.get(callback) : undefined;
      // 终态交付记录在其排队回调交付前始终具有优先权。
      if (call) {
        if (!call.accepting) return;
        try {
          validateResponse(m, 'call', raw);
          call.accept(m, this.weight(m));
        } catch {
          call.fail('Invalid call response');
        }
        return;
      }
      const pending = callback ? this.pending.get(callback) : undefined;
      if (pending && callback) {
        try {
          validateResponse(m, pending.lane === 'control' ? 'control' : 'call', raw);
        } catch {
          this.finish(callback, failure('PROTOCOL_ERROR', 'Invalid native response'));
          return;
        }
        this.finish(
          callback,
          Object.hasOwn(m, 'error') ? (m.error as BridgeError) : null,
          m.result,
          this.weight(m),
          true,
        );
        return;
      }
      if (this.state === 'connecting' && callback === this.helloCallbackId) {
        validateResponse(m, 'control', raw);
        if (Object.hasOwn(m, 'error')) {
          this.shutdown(m.error as BridgeError);
          return;
        }
        if ((m.result as Record<string, unknown>).ready !== true)
          throw Error('Invalid readiness result');
        const h = this.handshake;
        if (!h) throw Error('Missing handshake completion');
        this.state = 'ready';
        this.handshake = undefined;
        clearTimeout(h.timer);
        h.resolve();
        this.log('ready');
        return;
      }
      const subscription =
        typeof m.subscriptionId === 'string' ? this.subscriptions.get(m.subscriptionId) : undefined;
      if (subscription) {
        try {
          validateResponse(m, 'event', raw);
          this.receiveEvent(m);
        } catch {
          this.failStream(subscription, failure('PROTOCOL_ERROR', 'Invalid event stream'));
        }
        return;
      }
      // 只有可靠且已完全退出的标识符才可跳过校验。
      const ids = ['callbackId', 'subscriptionId'].filter((k) => Object.hasOwn(m, k));
      if (ids.length > 0 && ids.every((k) => isResponseId(m[k]))) return;
      throw Error('Unreliable response identifier');
    } catch {
      this.shutdown(failure('PROTOCOL_ERROR', 'Invalid native message'));
    }
  }
  private nativeClose(m: Record<string, unknown>, raw: string): void {
    const p = m.params;
    if (
      utf8Size(raw) > 256 * 1024 ||
      Object.keys(m).sort().join(',') !== 'method,params' ||
      !p ||
      typeof p !== 'object' ||
      Array.isArray(p)
    )
      throw Error('Invalid native close');
    const fields = p as Record<string, unknown>;
    if (
      Object.keys(fields).sort().join(',') !== 'code,reason' ||
      !['BACKPRESSURE', 'DISCONNECTED'].includes(fields.code as string) ||
      typeof fields.reason !== 'string' ||
      fields.reason.length < 1 ||
      fields.reason.length > 256
    )
      throw Error('Invalid native close');
    this.shutdown(failure(fields.code as string, fields.reason), false);
  }
  private releasePending(p: Pending, id: string, error?: BridgeError | null): void {
    this.diagnostics.gauge('pending.' + p.lane, -1);
    this.diagnostics.observe('request', this.diagnostics.now() - p.started);
  }
  private endLog(p: Pending, id: string, error?: BridgeError | null): void {
    this.log('end', { callbackId: id, code: error?.code });
    if (error) this.log('error', { callbackId: id, code: error.code });
  }
  private finish(
    callbackId: string,
    error: BridgeError | null,
    result?: unknown,
    bytes = 256,
    received = false,
  ): void {
    const p = this.pending.get(callbackId);
    if (!p) return;
    this.pending.delete(callbackId);
    clearTimeout(p.timer);
    this.releasePending(p, callbackId, error); // 在用户代码执行前清理。
    p.finish(error, result);
    this.endLog(p, callbackId, error);
  }
  private asError(e: unknown): BridgeError {
    if (
      e &&
      typeof e === 'object' &&
      'code' in e &&
      'message' in e &&
      typeof e.code === 'string' &&
      typeof e.message === 'string'
    )
      return { code: e.code, message: e.message };
    return failure('INVALID_ARGUMENT', 'Cannot encode request');
  }
  private closeTransport(text?: string): Promise<void> {
    if (!this.closeTask) {
      // 先保存共享任务，再执行可能同步重入的 Adapter。
      this.closeTask = Promise.resolve().then(async () => {
        let timer: ReturnType<typeof setTimeout> | undefined;
        try {
          if (text)
            await Promise.race([
              this.adapter.send(text),
              new Promise<void>((resolve) => {
                timer = setTimeout(resolve, 250);
              }),
            ]);
        } catch {
        } finally {
          if (timer !== undefined) clearTimeout(timer);
          try {
            await this.adapter.close();
          } catch {}
        }
      });
    }
    return this.closeTask;
  }
  private shutdown(error: BridgeError, notifyNative = true): void {
    if (this.state === 'closed') return;
    const close =
      notifyNative && (this.state === 'ready' || this.state === 'connecting')
        ? JSON.stringify({
            callbackId: this.nextId(),
            method: 'bridge.close',
            params: { reason: 'SDK close' },
          })
        : undefined;
    this.state = 'closed';
    void this.closeTransport(close);
    this.log('close', { code: error.code });
    for (const s of this.calls.values()) s.close(error, true);
    for (const s of this.subscriptions.values()) this.stopSubscription(s);
    const h = this.handshake;
    this.handshake = undefined;
    if (h) {
      clearTimeout(h.timer);
      h.reject(error);
    }
    for (const callbackId of this.pending.keys()) this.finish(callbackId, error);
  }
  async dispose(): Promise<void> {
    this.shutdown(failure('DISCONNECTED', 'Bridge disposed'));
    await this.closeTask;
  }
}
