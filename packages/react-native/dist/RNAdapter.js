import { failure } from 'aeris-client-core/protocol';
const owners = new WeakMap();
/** 仅负责固定 RN 通道，不进行方法路由或维护业务回调表。 */
export class RNAdapter {
    native;
    state = 'new';
    subscription;
    disconnected;
    constructor(native) {
        this.native = native;
    }
    async connect(receiver, onDisconnect) {
        if (this.state !== 'new' || owners.has(this.native))
            throw failure('BRIDGE_UNAVAILABLE', 'Native endpoint already owned');
        if (!this.native ||
            typeof this.native.send !== 'function' ||
            typeof this.native.onMessage !== 'function')
            throw failure('BRIDGE_UNAVAILABLE', 'NativeUnifiedBridge missing');
        owners.set(this.native, this);
        this.disconnected = onDisconnect;
        try {
            this.state = 'connected';
            this.subscription = this.native.onMessage((text) => {
                if (this.state !== 'connected' || owners.get(this.native) !== this)
                    return;
                if (typeof text !== 'string') {
                    this.disconnected?.(failure('PROTOCOL_ERROR', 'Expected native String'));
                    return;
                }
                receiver(text);
            });
        }
        catch (e) {
            owners.delete(this.native);
            this.state = 'closed';
            throw e;
        }
    }
    async send(text) {
        if (this.state !== 'connected')
            throw failure('DISCONNECTED', 'RN Adapter closed');
        this.native.send(text); // 此处不返回业务结果。
    }
    async close() {
        if (this.state === 'closed')
            return;
        this.state = 'closed';
        if (owners.get(this.native) === this) {
            owners.delete(this.native);
            this.subscription?.remove();
        }
        this.subscription = undefined;
        this.disconnected = undefined;
    }
}
