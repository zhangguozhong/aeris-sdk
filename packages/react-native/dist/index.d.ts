import { ClientCore } from 'aeris-client-core/ClientCore';
import type { ClientOptions } from 'aeris-client-core/flowControl';
export declare function createBridge(options?: ClientOptions, onCallbackError?: (error: unknown) => void): ClientCore;
export declare const bridge: ClientCore;
export { ClientCore } from 'aeris-client-core/ClientCore';
export { BridgeDiagnostics } from 'aeris-client-core/diagnostics';
export type { DiagnosticOptions, DiagnosticRecord, DiagnosticSnapshot, } from 'aeris-client-core/diagnostics';
export type { ClientOptions, FlowLimits } from 'aeris-client-core/flowControl';
export type { BridgeError, Completion, CallHandle, CallOptions, CallCallbacks, Subscription, } from 'aeris-client-core/protocol';
