import { failure } from 'aeris-client-core/protocol';
import { LegacyWebChannel } from './LegacyWebChannel.js';
const owners = new WeakMap();
function isChannel(value) {
    return (typeof value.send === 'function' &&
        typeof value.subscribe === 'function');
}
/** 负责通道生命周期；协议校验仍由 Client Core 处理。 */
export class WebAdapter {
    phase = 'new';
    unsubscribe;
    channel;
    constructor(portOrChannel) {
        this.channel = isChannel(portOrChannel) ? portOrChannel : new LegacyWebChannel(portOrChannel);
    }
    async connect(receive, disconnected) {
        if (this.phase !== 'new' || owners.has(this.channel))
            throw failure('DUPLICATE_INIT', 'One Web adapter per channel');
        owners.set(this.channel, this);
        this.phase = 'connected';
        let startupError;
        const active = () => this.phase === 'connected' && owners.get(this.channel) === this;
        try {
            const unsubscribe = this.channel.subscribe((text) => {
                if (!active())
                    return;
                try {
                    receive(text);
                }
                catch { }
            }, (error) => {
                if (!active())
                    return;
                startupError = error;
                this.release();
                try {
                    disconnected(error);
                }
                catch { }
            });
            this.unsubscribe = unsubscribe;
            // subscribe 可能同步调用 receive/disconnect 并关闭此适配器。
            if (!active()) {
                this.cleanup();
                throw startupError ?? failure('DISCONNECTED', 'Web adapter closed during subscribe');
            }
        }
        catch (error) {
            this.release();
            throw error;
        }
    }
    async send(text) {
        if (this.phase !== 'connected' || owners.get(this.channel) !== this)
            throw failure('DISCONNECTED', 'Web adapter is closed');
        await this.channel.send(text);
    }
    cleanup() {
        const unsubscribe = this.unsubscribe;
        this.unsubscribe = undefined;
        try {
            unsubscribe?.();
        }
        catch { }
    }
    release() {
        this.phase = 'closed';
        if (owners.get(this.channel) === this)
            owners.delete(this.channel);
        this.cleanup();
    }
    async close() {
        this.release();
    }
}
