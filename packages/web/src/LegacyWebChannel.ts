import { failure } from 'aeris-client-core/protocol';
import type { BridgeError } from 'aeris-client-core/protocol';
import type { WebChannel } from './WebChannel.js';

export interface WebPort {
  Unity?: { call: (wire: string) => void };
  webkit?: { messageHandlers?: { webViewBridge?: { postMessage: (wire: string) => void } } };
  WBBridgeJSConnector?: { Callback?: (name: string, payload: string) => void };
}
const owners = new WeakMap<object, object>();

/** 兼容现有 Web 全局对象和标记的通道。 */
export class LegacyWebChannel implements WebChannel {
  private sendWire?: (text: string) => void;
  constructor(private readonly port: WebPort) {}
  subscribe(
    receive: (text: string) => void,
    onDisconnect: (error: BridgeError) => void,
  ): () => void {
    if (owners.has(this.port)) throw failure('DUPLICATE_INIT', 'One Web channel per window');
    const unity = this.port.Unity,
      handler = this.port.webkit?.messageHandlers?.webViewBridge;
    let send: (text: string) => void;
    if (typeof unity?.call === 'function') send = (text) => unity.call(text);
    else if (typeof handler?.postMessage === 'function') send = (text) => handler.postMessage(text);
    else throw failure('BRIDGE_UNAVAILABLE', 'Native webViewBridge is missing');
    const connector = this.port.WBBridgeJSConnector ?? (this.port.WBBridgeJSConnector = {});
    const previous = connector.Callback,
      owner = {};
    let active = true;
    const installed = (name: string, payload: string) => {
      if (!active || owners.get(this.port) !== owner) return;
      // 物理宿主回调不得接收消费者抛出的异常。
      try {
        if (name !== 'unifiedBridge') {
          previous?.call(connector, name, payload);
          return;
        }
        if (typeof payload !== 'string') {
          onDisconnect(failure('PROTOCOL_ERROR', 'Expected native String'));
          return;
        }
        receive(payload);
      } catch {}
    };
    const unsubscribe = () => {
      if (!active) return;
      active = false;
      if (owners.get(this.port) !== owner) return;
      owners.delete(this.port);
      this.sendWire = undefined;
      if (connector.Callback === installed) {
        if (previous) connector.Callback = previous;
        else delete connector.Callback;
      }
    };
    owners.set(this.port, owner);
    try {
      connector.Callback = installed;
      this.sendWire = send;
    } catch (error) {
      try {
        unsubscribe();
      } catch {}
      throw error;
    }
    return unsubscribe;
  }
  send(text: string): void {
    if (!this.sendWire) throw failure('DISCONNECTED', 'Web channel is closed');
    this.sendWire('unifiedBridge&' + text);
  }
}
