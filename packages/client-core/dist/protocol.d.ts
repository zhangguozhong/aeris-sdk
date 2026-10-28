export interface BridgeError {
    code: string;
    message: string;
}
export type Completion<T> = (error: BridgeError | null, result?: T) => void;
export interface Adapter {
    connect(receiver: (text: string) => void, onDisconnect: (error: BridgeError) => void): Promise<void>;
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
    cancel(reason?: string): Promise<{
        accepted: boolean;
    }>;
}
export declare const failure: (code: string, message: string) => BridgeError;
export declare function utf8Size(text: string): number;
export declare function assertJSON(value: unknown, seen?: Set<object>, depth?: number): void;
export interface Subscription {
    subscriptionId: string;
    unsubscribe(): Promise<{
        accepted: boolean;
    }>;
}
