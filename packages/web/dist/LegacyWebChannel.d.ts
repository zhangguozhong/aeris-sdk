import type { BridgeError } from 'aeris-client-core/protocol';
import type { WebChannel } from './WebChannel.js';
export interface WebPort {
    Unity?: {
        call: (wire: string) => void;
    };
    webkit?: {
        messageHandlers?: {
            webViewBridge?: {
                postMessage: (wire: string) => void;
            };
        };
    };
    WBBridgeJSConnector?: {
        Callback?: (name: string, payload: string) => void;
    };
}
/** 兼容现有 Web 全局对象和标记的通道。 */
export declare class LegacyWebChannel implements WebChannel {
    private readonly port;
    private sendWire?;
    constructor(port: WebPort);
    subscribe(receive: (text: string) => void, onDisconnect: (error: BridgeError) => void): () => void;
    send(text: string): void;
}
