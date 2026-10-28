import { ClientCore } from 'aeris-client-core/ClientCore';
import { WebAdapter } from './WebAdapter.js';
import type { WebPort } from './WebAdapter.js';
import type { WebChannel } from './WebChannel.js';
import type { ClientOptions } from 'aeris-client-core/flowControl';
export function createBridge(
  options: ClientOptions = {},
  onCallbackError?: (error: unknown) => void,
): ClientCore {
  return new ClientCore(new WebAdapter(window as unknown as WebPort), onCallbackError, options);
}
export function createBridgeWithChannel(
  channel: WebChannel,
  options: ClientOptions = {},
  onCallbackError?: (error: unknown) => void,
): ClientCore {
  return new ClientCore(new WebAdapter(channel), onCallbackError, options);
}
export { WebAdapter } from './WebAdapter.js';
export { LegacyWebChannel } from './LegacyWebChannel.js';
export type { WebPort } from './LegacyWebChannel.js';
export type { WebChannel } from './WebChannel.js';
// 每个 Web 容器只选择一个所有者。
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
