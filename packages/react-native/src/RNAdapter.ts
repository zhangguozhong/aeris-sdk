import { failure } from 'aeris-client-core/protocol';
import type { Adapter, BridgeError } from 'aeris-client-core/protocol';
export interface NativePort {
  send(message: string): void;
  onMessage(listener: (message: string) => void): { remove(): void };
}
const owners = new WeakMap<object, RNAdapter>();

/** 仅负责固定 RN 通道，不进行方法路由或维护业务回调表。 */
export class RNAdapter implements Adapter {
  private readonly native: NativePort;
  private state: 'new' | 'connected' | 'closed' = 'new';
  private subscription?: { remove(): void };
  private disconnected?: (error: BridgeError) => void;
  constructor(native: NativePort) {
    this.native = native;
  }
  async connect(
    receiver: (text: string) => void,
    onDisconnect: (error: BridgeError) => void,
  ): Promise<void> {
    if (this.state !== 'new' || owners.has(this.native))
      throw failure('BRIDGE_UNAVAILABLE', 'Native endpoint already owned');
    if (
      !this.native ||
      typeof this.native.send !== 'function' ||
      typeof this.native.onMessage !== 'function'
    )
      throw failure('BRIDGE_UNAVAILABLE', 'NativeUnifiedBridge missing');
    owners.set(this.native, this);
    this.disconnected = onDisconnect;
    try {
      this.state = 'connected';
      this.subscription = this.native.onMessage((text) => {
        if (this.state !== 'connected' || owners.get(this.native) !== this) return;
        if (typeof text !== 'string') {
          this.disconnected?.(failure('PROTOCOL_ERROR', 'Expected native String'));
          return;
        }
        receiver(text);
      });
    } catch (e) {
      owners.delete(this.native);
      this.state = 'closed';
      throw e;
    }
  }
  async send(text: string): Promise<void> {
    if (this.state !== 'connected') throw failure('DISCONNECTED', 'RN Adapter closed');
    this.native.send(text); // 此处不返回业务结果。
  }
  async close(): Promise<void> {
    if (this.state === 'closed') return;
    this.state = 'closed';
    if (owners.get(this.native) === this) {
      owners.delete(this.native);
      this.subscription?.remove();
    }
    this.subscription = undefined;
    this.disconnected = undefined;
  }
}
