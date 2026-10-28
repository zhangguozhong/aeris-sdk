import type { Adapter, BridgeError } from 'aeris-client-core/protocol';
import type { WebPort } from './LegacyWebChannel.js';
import type { WebChannel } from './WebChannel.js';
export type { WebPort } from './LegacyWebChannel.js';
/** 负责通道生命周期；协议校验仍由 Client Core 处理。 */
export declare class WebAdapter implements Adapter {
    private phase;
    private unsubscribe?;
    private readonly channel;
    constructor(portOrChannel: WebPort | WebChannel);
    connect(receive: (text: string) => void, disconnected: (error: BridgeError) => void): Promise<void>;
    send(text: string): Promise<void>;
    private cleanup;
    private release;
    close(): Promise<void>;
}
