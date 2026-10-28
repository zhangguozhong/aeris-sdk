# aeris-web

Web channel adapters and Client Core composition. Install together with `aeris-client-core` 0.25.0.

The existing `bridge`, `createBridge(options, onCallbackError)` and `new WebAdapter(port)` APIs retain the legacy wire contract. The host supplies `Unity.call` or `webkit.messageHandlers.webViewBridge.postMessage`, plus `WBBridgeJSConnector.Callback`. `LegacyWebChannel` owns these globals and the `unifiedBridge&` request marker. Its callback only accepts the `unifiedBridge` response name, forwards unrelated names to the previous callback and restores that callback only while its own handler is still installed.

For another host, inject one `WebChannel` per physical container:

```ts
import {createBridgeWithChannel} from 'aeris-web';
import type {WebChannel} from 'aeris-web';

const channel:WebChannel={
  send(text){host.sendProtocolString(text);},
  subscribe(receive,onDisconnect){
    // Install synchronously; return the function that removes both callbacks.
    return host.listenForProtocolStrings(receive,onDisconnect);
  },
};
const bridge=createBridgeWithChannel(channel,{},error=>console.error(error));
await bridge.ready();
bridge.call('echo',{text:'Hello'},(error,result)=>console.log(error??result));
// On container teardown:
await bridge.dispose();
```

`send` may return `void` or `Promise<void>`. The channel passes protocol strings unchanged; host-specific framing belongs in the channel. `subscribe` may synchronously deliver a frame or disconnect. It must return an unsubscribe function; if it throws, it must remove any callbacks it already installed. The adapter fences late callbacks, unsubscribes once on disconnect or close, and releases channel ownership after failed startup. Exceptions from receive, disconnect and unsubscribe callbacks are isolated from the physical host callback.

Reuse the same channel object for the same physical container. A second active adapter for that object rejects with `DUPLICATE_INIT`; distinct channel objects represent independent containers. Legacy channels additionally enforce ownership by the original port, including when mixing `new WebAdapter(port)` with `new LegacyWebChannel(port)`. Closing a failed duplicate cannot detach the live owner. User call/event callback errors continue to reach Client Core's `onCallbackError` hook.
