import { failure, utf8Size } from './protocol.js';
import type { BridgeError, CallCallbacks } from './protocol.js';
import type { BridgeDiagnostics, DiagnosticRecord } from './diagnostics.js';

type Fields = Partial<Omit<DiagnosticRecord, 'stage' | 'timeMs'>>;
type Phase = 'waitingFirst' | 'receiving' | 'terminalQueued' | 'released';
/** 沿用 Core 服务；PendingCall 拥有生命周期，交付队列仍保持共享。 */
export interface PendingCallHost {
  diagnostics: BridgeDiagnostics;
  closed(): boolean;
  failed(): boolean;
  queue(
    run: () => void,
    bytes: number,
    discard: (() => void) | undefined,
    urgent: boolean,
    fields: Fields,
  ): boolean;
  remove(call: PendingCall): void;
  cancelNative(id: string, reason: string): Promise<{ accepted: boolean }>;
  log(stage: string, fields: Fields): void;
  callbackError(error: unknown): void;
}

/** 单个请求，包括接收终态帧与交付终态帧之间的间隔。 */
export class PendingCall {
  readonly id: string;
  private host?: PendingCallHost;
  private callbacks: CallCallbacks<unknown>;
  private phase: Phase = 'waitingFirst';
  private localTerminal = false;
  private hasProgress = false;
  private generation = 0;
  private last = 0;
  private readonly buffered = new Map<
    number,
    { message: Record<string, unknown>; bytes: number }
  >();
  private startup?: ReturnType<typeof setTimeout>;
  private gap?: ReturnType<typeof setTimeout>;
  private started?: number;
  private slot = false;
  private cancellation?: Promise<{ accepted: boolean }>;

  constructor(id: string, callbacks: CallCallbacks<unknown>, host: PendingCallHost) {
    this.id = id;
    this.callbacks = callbacks;
    this.host = host;
  }
  get isPending(): boolean {
    return this.slot;
  }
  get accepting(): boolean {
    return this.phase === 'waitingFirst' || this.phase === 'receiving';
  }

  /** 启动或发送前，Core 已准入业务槽位并安装此所有者。 */
  start(timeoutMs: number): void {
    if (!this.host || this.slot || !this.accepting) return;
    this.slot = true;
    this.started = this.host.diagnostics.now();
    this.host.diagnostics.gauge('pending.business', 1);
    this.startup = setTimeout(() => {
      const host = this.host;
      if (!host || !this.isPending) return;
      this.end(
        failure('TIMEOUT', 'Request timed out; native side effects may still have occurred'),
      );
      host.log('timeout', { callbackId: this.id, code: 'TIMEOUT' });
      this.cancelQuietly('client timeout');
    }, timeoutMs);
  }

  /** 仅接收 Core 已解码、关联并校验的流式帧。 */
  accept(message: Record<string, unknown>, bytes = 256): void {
    if (!this.accepting) return;
    try {
      const seq = message.seq as number;
      if (seq <= this.last || this.buffered.has(seq)) return;
      if (seq > this.last + 1) {
        if (this.buffered.size >= 32) throw Error('Reorder overflow');
        this.buffered.set(seq, { message, bytes });
        if (this.gap === undefined)
          this.gap = setTimeout(() => this.fail('Response sequence gap timed out'), 2000);
        return;
      }
      this.consume(message, bytes);
      while (this.accepting && this.buffered.has(this.last + 1)) {
        const next = this.buffered.get(this.last + 1);
        if (!next) throw Error('Missing buffered response');
        this.buffered.delete(this.last + 1);
        this.consume(next.message, next.bytes);
      }
      // 存在缺帧时保留原有 TS 截止时间，不引入新的恢复策略。
      if (!this.buffered.size && this.gap !== undefined) {
        clearTimeout(this.gap);
        this.gap = undefined;
      }
    } catch {
      this.fail('Invalid response stream');
    }
  }

  private consume(message: Record<string, unknown>, bytes: number): void {
    this.last = message.seq as number;
    this.stopStartup();
    if (message.finished === true) {
      this.end((message.error as BridgeError) ?? null, message.result, false, bytes);
      return;
    }
    this.hasProgress = true; // 在任何诊断或交付钩子可能重入前发布状态。
    this.phase = 'receiving';
    if (!this.callbacks.onData) return; // 仅处理终态的完成回调不保留被忽略的进度载荷。
    const generation = this.generation,
      host = this.host;
    if (!host) throw Error('Missing call host');
    host.queue(
      () => {
        if (!this.canDeliver(generation)) return;
        host.log('callback.deliver', { callbackId: this.id });
        if (!this.canDeliver(generation)) return; // 诊断观察者可能同步取消或关闭。
        try {
          this.callbacks.onData?.(message.result);
        } catch (error) {
          host.callbackError(error);
        }
      },
      bytes,
      undefined,
      false,
      { callbackId: this.id },
    );
  }

  fail(message: string): void {
    if (!this.accepting) return;
    this.end(failure('PROTOCOL_ERROR', message), undefined, true);
    this.cancelQuietly('invalid response stream');
  }
  /** 传输请求创建前发生的本地校验或准入失败。 */
  reject(error: BridgeError): void {
    this.end(error);
  }
  /** Core 选择既定的断开或背压错误；此所有者执行状态隔离。 */
  close(error: BridgeError, preserveFinal = false): void {
    if (
      preserveFinal &&
      this.phase === 'terminalQueued' &&
      !this.localTerminal &&
      !this.hasProgress
    )
      return;
    this.end(error, undefined, true);
  }

  cancel(reason = 'user cancelled'): Promise<{ accepted: boolean }> {
    if (this.cancellation) return this.cancellation;
    const host = this.host;
    if (!host || host.closed() || this.phase === 'released' || this.localTerminal)
      return Promise.resolve({ accepted: false });
    if (this.phase === 'terminalQueued' && !this.localTerminal && !this.hasProgress)
      return Promise.resolve({ accepted: false });
    // 在任何可观察钩子可能重入 cancel() 前，先发布确认 Promise。
    let completion:
      | { resolve: (value: { accepted: boolean }) => void; reject: (error: unknown) => void }
      | undefined;
    this.cancellation = new Promise((resolve, reject) => {
      completion = { resolve, reject };
    });
    if (!completion) throw Error('Missing cancellation completion');
    const { resolve, reject } = completion;
    host.log('cancel', { callbackId: this.id, code: 'CANCELLED' });
    this.end(failure('CANCELLED', reason), undefined, true);
    if (host.closed()) resolve({ accepted: false });
    else
      host
        .cancelNative(this.id, reason)
        .then((result) => {
          if (typeof result?.accepted !== 'boolean')
            throw failure('PROTOCOL_ERROR', 'Invalid cancellation acknowledgement');
          return result;
        })
        .then(resolve, reject);
    return this.cancellation;
  }

  private end(error: BridgeError | null, result?: unknown, fence = false, bytes = 256): void {
    const host = this.host;
    if (
      !host ||
      this.phase === 'released' ||
      this.localTerminal ||
      (this.phase === 'terminalQueued' && !fence)
    )
      return;
    if (fence) {
      this.generation++;
      this.localTerminal = true;
      if (error) error = this.bounded(error);
    }
    this.phase = 'terminalQueued';
    const wasPending = this.slot;
    this.stopRequest();
    const generation = this.generation,
      terminalError = error,
      urgent = fence || host.failed();
    const accepted = host.queue(
      () => {
        if (!this.canDeliver(generation)) return;
        const callbacks = this.callbacks;
        this.release(); // 在可观察回调或业务回调前退出活动状态。
        host.log('callback.deliver', { callbackId: this.id });
        try {
          terminalError ? callbacks.onError?.(terminalError) : callbacks.onComplete?.(result);
        } catch (thrown) {
          host.callbackError(thrown);
        }
      },
      fence && terminalError ? utf8Size(JSON.stringify(terminalError)) : bytes,
      this.pressureFallback(),
      urgent,
      { callbackId: this.id },
    );
    if (!accepted && urgent) this.release();
    if (wasPending) {
      host.log('end', { callbackId: this.id, code: error?.code });
      if (error) host.log('error', { callbackId: this.id, code: error.code });
    }
  }
  // 独立作用域：背压回退不得保留被丢弃的结果或错误载荷。
  private pressureFallback(): () => void {
    return () => this.close(failure('BACKPRESSURE', 'Bridge callback queue exceeded'));
  }
  private canDeliver(generation: number): boolean {
    return this.phase !== 'released' && this.generation === generation;
  }
  private bounded(error: BridgeError): BridgeError {
    return {
      code:
        typeof error.code === 'string' && /^[A-Z][A-Z0-9_]{0,63}$/.test(error.code)
          ? error.code
          : 'DISCONNECTED',
      message:
        typeof error.message === 'string' ? error.message.slice(0, 256) : 'Bridge disconnected',
    };
  }
  private stopStartup(): void {
    if (this.startup !== undefined) clearTimeout(this.startup);
    this.startup = undefined;
  }
  private stopRequest(): void {
    this.stopStartup();
    if (this.gap !== undefined) clearTimeout(this.gap);
    this.gap = undefined;
    this.buffered.clear();
    if (this.slot) {
      const host = this.host,
        started = this.started;
      if (!host || started === undefined) throw Error('Missing pending request accounting');
      this.slot = false;
      host.diagnostics.gauge('pending.business', -1);
      host.diagnostics.observe('request', host.diagnostics.now() - started);
      this.started = undefined;
    }
  }
  private release(): void {
    if (this.phase === 'released') return;
    this.phase = 'released';
    this.stopRequest();
    this.callbacks = {} as CallCallbacks<unknown>;
    const host = this.host;
    this.host = undefined;
    host?.remove(this);
  }
  private cancelQuietly(reason: string): void {
    const host = this.host;
    if (host && !host.closed()) void host.cancelNative(this.id, reason).catch(() => {});
  }
}
