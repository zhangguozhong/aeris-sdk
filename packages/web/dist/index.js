import { ClientCore } from 'aeris-client-core/ClientCore';
import { WebAdapter } from './WebAdapter.js';
export function createBridge(options = {}, onCallbackError) {
    return new ClientCore(new WebAdapter(window), onCallbackError, options);
}
export function createBridgeWithChannel(channel, options = {}, onCallbackError) {
    return new ClientCore(new WebAdapter(channel), onCallbackError, options);
}
export { WebAdapter } from './WebAdapter.js';
export { LegacyWebChannel } from './LegacyWebChannel.js';
// 每个 Web 容器只选择一个所有者。
export const bridge = createBridge();
export { ClientCore } from 'aeris-client-core/ClientCore';
export { BridgeDiagnostics } from 'aeris-client-core/diagnostics';
