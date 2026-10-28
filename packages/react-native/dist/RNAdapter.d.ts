import type { Adapter, BridgeError } from 'aeris-client-core/protocol';
export interface NativePort {
    send(message: string): void;
    onMessage(listener: (message: string) => void): {
        remove(): void;
    };
}
/** 仅负责固定 RN 通道，不进行方法路由或维护业务回调表。 */
export declare class RNAdapter implements Adapter {
    private readonly native;
    private state;
    private subscription?;
    private disconnected?;
    constructor(native: NativePort);
    connect(receiver: (text: string) => void, onDisconnect: (error: BridgeError) => void): Promise<void>;
    send(text: string): Promise<void>;
    close(): Promise<void>;
}
