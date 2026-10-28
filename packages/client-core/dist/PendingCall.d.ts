import type { BridgeError, CallCallbacks } from './protocol.js';
import type { BridgeDiagnostics, DiagnosticRecord } from './diagnostics.js';
type Fields = Partial<Omit<DiagnosticRecord, 'stage' | 'timeMs'>>;
/** 沿用 Core 服务；PendingCall 拥有生命周期，交付队列仍保持共享。 */
export interface PendingCallHost {
    diagnostics: BridgeDiagnostics;
    closed(): boolean;
    failed(): boolean;
    queue(run: () => void, bytes: number, discard: (() => void) | undefined, urgent: boolean, fields: Fields): boolean;
    remove(call: PendingCall): void;
    cancelNative(id: string, reason: string): Promise<{
        accepted: boolean;
    }>;
    log(stage: string, fields: Fields): void;
    callbackError(error: unknown): void;
}
/** 单个请求，包括接收终态帧与交付终态帧之间的间隔。 */
export declare class PendingCall {
    readonly id: string;
    private host?;
    private callbacks;
    private phase;
    private localTerminal;
    private hasProgress;
    private generation;
    private last;
    private readonly buffered;
    private startup?;
    private gap?;
    private started?;
    private slot;
    private cancellation?;
    constructor(id: string, callbacks: CallCallbacks<unknown>, host: PendingCallHost);
    get isPending(): boolean;
    get accepting(): boolean;
    /** 启动或发送前，Core 已准入业务槽位并安装此所有者。 */
    start(timeoutMs: number): void;
    /** 仅接收 Core 已解码、关联并校验的流式帧。 */
    accept(message: Record<string, unknown>, bytes?: number): void;
    private consume;
    fail(message: string): void;
    /** 传输请求创建前发生的本地校验或准入失败。 */
    reject(error: BridgeError): void;
    /** Core 选择既定的断开或背压错误；此所有者执行状态隔离。 */
    close(error: BridgeError, preserveFinal?: boolean): void;
    cancel(reason?: string): Promise<{
        accepted: boolean;
    }>;
    private end;
    private pressureFallback;
    private canDeliver;
    private bounded;
    private stopStartup;
    private stopRequest;
    private release;
    private cancelQuietly;
}
export {};
