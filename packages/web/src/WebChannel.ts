import type { BridgeError } from 'aeris-client-core/protocol';

/** 由宿主拥有的物理通道，传输未经修改的协议字符串。 */
export interface WebChannel {
  send(text: string): void | Promise<void>;
  /** 同步安装回调；返回清理函数，或在抛出异常前清理。 */
  subscribe(
    receive: (text: string) => void,
    onDisconnect: (error: BridgeError) => void,
  ): () => void;
}
