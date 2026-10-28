import NativeUnifiedBridge from './specs/NativeUnifiedBridge.js';
import { ClientCore } from 'aeris-client-core/ClientCore';
import { RNAdapter } from './RNAdapter.js';
import type { ClientOptions } from 'aeris-client-core/flowControl';

// RN Bridge SDK 由 Client Core 与 RN Adapter 组合而成。
export function createBridge(
  options: ClientOptions = {},
  onCallbackError?: (error: unknown) => void,
): ClientCore {
  return new ClientCore(new RNAdapter(NativeUnifiedBridge), onCallbackError, options);
}
// 每个 RN 运行时选择默认或配置后的实例，仅连接一个所有者。
export const bridge = createBridge();
export { ClientCore } from 'aeris-client-core/ClientCore';
export { BridgeDiagnostics } from 'aeris-client-core/diagnostics';
export type {
  DiagnosticOptions,
  DiagnosticRecord,
  DiagnosticSnapshot,
} from 'aeris-client-core/diagnostics';
export type { ClientOptions, FlowLimits } from 'aeris-client-core/flowControl';
export type {
  BridgeError,
  Completion,
  CallHandle,
  CallOptions,
  CallCallbacks,
  Subscription,
} from 'aeris-client-core/protocol';
