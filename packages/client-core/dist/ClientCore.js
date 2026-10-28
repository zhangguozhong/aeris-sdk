import { PendingCall } from './PendingCall.js';
import { BridgeDiagnostics } from './diagnostics.js';
import { BridgeDeliveryQueue } from './flowControl.js';
import { assertJSON, failure, utf8Size } from './protocol.js';
import { decodeResponse, isResponseId, validateResponse } from './responseValidation.js';
/** 仅管理协议与请求，不导入 React Native。 */
export class ClientCore {
    adapter;
    pending = new Map();
    calls = new Map();
    subscriptions = new Map();
    prefix = globalThis.crypto?.randomUUID?.() ??
        `${Date.now().toString(36)}-${Math.random().toString(36).slice(2)}-${Math.random().toString(36).slice(2)}`;
    counter = 0;
    state = 'new';
    helloCallbackId;
    handshake;
    readyPromise;
    closeTask;
    onCallbackError;
    diagnostics;
    delivery;
    frameBytes = new WeakMap();
    constructor(adapter, onCallbackError = console.error, options = {}) {
        this.adapter = adapter;
        this.onCallbackError = onCallbackError;
        this.diagnostics = options.diagnostics ?? new BridgeDiagnostics();
        this.delivery = new BridgeDeliveryQueue(this.diagnostics, () => {
            this.shutdown(failure('BACKPRESSURE', 'Bridge callback queue exceeded'));
            this.log('backpressure', { code: 'BACKPRESSURE' });
        }, options.flowLimits);
    }
    log(stage, fields = {}) {
        this.diagnostics.record(stage, { clientId: this.prefix, ...fields });
    }
    callbackError(e) {
        this.log('callback.exception');
        try {
            this.onCallbackError(e);
        }
        catch { }
    }
    critical(error) {
        return {
            code: typeof error.code === 'string' && /^[A-Z][A-Z0-9_]{0,63}$/.test(error.code)
                ? error.code
                : 'DISCONNECTED',
            message: typeof error.message === 'string' ? error.message.slice(0, 256) : 'Bridge disconnected',
        };
    }
    weight(m) {
        return this.frameBytes.get(m) ?? 256;
    }
    queue(run, bytes, discard, urgent = false, fields = {}) {
        const accepted = this.delivery.post(run, bytes, discard, urgent);
        if (accepted)
            this.log('callback.enqueue', fields);
        return accepted;
    }
    canTransmit(id) {
        return (this.state !== 'closed' &&
            (!id || this.pending.has(id) || this.calls.get(id)?.isPending === true));
    }
    nextId() {
        return `${this.prefix}:${++this.counter}`;
    }
    ready() {
        if (this.state === 'closed')
            return Promise.reject(failure('DISCONNECTED', 'Bridge is closed'));
        if (this.readyPromise)
            return this.readyPromise;
        this.state = 'connecting';
        this.helloCallbackId = this.nextId();
        this.readyPromise = new Promise((resolve, reject) => {
            this.handshake = {
                resolve,
                reject,
                timer: setTimeout(() => this.shutdown(failure('TIMEOUT', 'Handshake timed out')), 5000),
            };
        });
        void this.adapter
            .connect((text) => this.receive(text), (error) => this.shutdown(error, error.code !== 'DISCONNECTED'))
            .then(() => {
            if (this.state !== 'connecting') {
                void this.adapter.close().catch(() => { });
                return;
            }
            this.transmit({ callbackId: this.helloCallbackId, method: 'bridge.hello', params: {} });
        })
            .catch(() => this.shutdown(failure('BRIDGE_UNAVAILABLE', 'Cannot connect to native bridge')));
        return this.readyPromise;
    }
    /** 统一请求 API：回调仅决定本地交付，Native 决定进度帧和终态帧。 */
    call(method, params, callback, options = {}) {
        this.delivery.assertAdmission(this.state === 'closed');
        const normalized = typeof callback === 'function' ? this.normalizeCompletion(callback) : callback;
        const id = this.nextId(), call = this.makePendingCall(id, (normalized ?? {}));
        const handle = { callbackId: id, cancel: (reason) => call.cancel(reason) };
        try {
            const timeoutMs = this.validateCall(method, params, options);
            if (!normalized ||
                typeof normalized.onComplete !== 'function' ||
                typeof normalized.onError !== 'function' ||
                (normalized.onData !== undefined && typeof normalized.onData !== 'function'))
                throw failure('INVALID_ARGUMENT', 'Expected a completion or call callbacks');
            this.assertPendingCapacity('business');
            this.calls.set(id, call);
            this.diagnostics.gauge('calls', 1);
            call.start(timeoutMs);
            this.transmit({
                callbackId: id,
                method,
                params,
                ...(options.timeoutMs === undefined ? {} : { timeoutMs }),
                ...(options.extra === undefined ? {} : { extra: options.extra }),
            }, id);
        }
        catch (error) {
            call.reject(this.asError(error));
        }
        return handle;
    }
    // 使用独立作用域，防止保留的取消句柄继续持有原始完成回调。
    normalizeCompletion(callback) {
        return { onComplete: (result) => callback(null, result), onError: (error) => callback(error) };
    }
    makePendingCall(id, callbacks) {
        return new PendingCall(id, callbacks, {
            diagnostics: this.diagnostics,
            closed: () => this.state === 'closed',
            failed: () => this.delivery.failed,
            queue: (run, bytes, discard, urgent, fields) => this.queue(run, bytes, discard, urgent, fields),
            remove: (call) => {
                if (this.calls.get(call.id) === call) {
                    this.calls.delete(call.id);
                    this.diagnostics.gauge('calls', -1);
                }
            },
            cancelNative: (targetCallbackId, reason) => this.control('bridge.cancel', { targetCallbackId, reason }),
            log: (stage, fields) => this.log(stage, fields),
            callbackError: (error) => this.callbackError(error),
        });
    }
    validateCall(method, params, options) {
        if (this.state !== 'ready')
            throw failure('NOT_READY', 'Await bridge.ready() first');
        if (typeof method !== 'string' ||
            utf8Size(method) > 256 ||
            !/^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)?$/.test(method) ||
            method.split('.').some((x) => ['constructor', 'prototype', '__proto__'].includes(x)))
            throw failure('INVALID_METHOD', 'Invalid method name');
        if (method.startsWith('bridge.'))
            throw failure('INVALID_METHOD', 'System methods are reserved for SDK lifecycle APIs');
        if (!params || Array.isArray(params) || typeof params !== 'object')
            throw failure('INVALID_ARGUMENT', 'params must be an object');
        assertJSON(params);
        if (options.extra !== undefined && typeof options.extra !== 'string')
            throw failure('INVALID_ARGUMENT', 'extra must be a string');
        if (options.extra !== undefined &&
            utf8Size(JSON.stringify({ extra: options.extra })) > 255 * 1024)
            throw failure('PAYLOAD_TOO_LARGE', 'extra leaves no response headroom');
        const timeoutMs = options.timeoutMs ?? 120000;
        if (!Number.isInteger(timeoutMs) || timeoutMs < 1 || timeoutMs > 600000)
            throw failure('INVALID_ARGUMENT', 'Invalid timeoutMs');
        return timeoutMs;
    }
    async subscribe(topic, onData, onError, onComplete) {
        if (this.state !== 'ready')
            throw failure('NOT_READY', 'Await bridge.ready() first');
        if (typeof topic !== 'string' ||
            topic.length < 1 ||
            topic.length > 128 ||
            !/^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)*(?![\s\S])/.test(topic))
            throw failure('INVALID_ARGUMENT', 'Invalid event topic');
        if (typeof onData !== 'function' ||
            (onError !== undefined && typeof onError !== 'function') ||
            (onComplete !== undefined && typeof onComplete !== 'function'))
            throw failure('INVALID_ARGUMENT', 'Expected event callbacks');
        if (this.subscriptions.size >= 32)
            throw failure('TOO_MANY_SUBSCRIPTIONS', 'Subscription limit reached');
        const id = this.nextId(), s = {
            id,
            acked: false,
            last: 0,
            phase: 'active',
            buffer: new Map(),
            data: onData,
            error: onError,
            complete: onComplete,
        };
        this.subscriptions.set(id, s);
        this.diagnostics.gauge('subscriptions', 1); // 先于 Native 可能同步发送的确认或初始快照执行。
        try {
            await this.control('bridge.subscribe', { topic, subscriptionId: id }, (result) => {
                if (!result || result.subscriptionId !== id)
                    throw failure('PROTOCOL_ERROR', 'Invalid subscription acknowledgement');
                s.acked = true;
                this.drainEvents(s);
            }, () => this.stopSubscription(s));
            if (s.phase === 'off')
                throw failure('DISCONNECTED', 'Bridge is closed');
        }
        catch (e) {
            this.stopSubscription(s);
            this.bestEffortOff(id);
            throw e;
        }
        return { subscriptionId: id, unsubscribe: () => this.unsubscribe(s) };
    }
    clearStream(s) {
        if (s.gap !== undefined)
            clearTimeout(s.gap);
        s.gap = undefined;
        s.buffer.clear();
        if (this.subscriptions.delete(s.id))
            this.diagnostics.gauge('subscriptions', -1);
    }
    releaseCallbacks(s) {
        s.data = () => { };
        s.error = undefined;
        s.complete = undefined;
    }
    stopSubscription(s) {
        s.phase = 'off';
        this.clearStream(s);
        this.releaseCallbacks(s);
    }
    unsubscribe(s) {
        if (s.off)
            return s.off;
        s.offNeeded ??= s.phase === 'active';
        let resolve;
        let reject;
        const attempt = new Promise((done, failed) => {
            resolve = done;
            reject = failed;
        });
        // 先发布共享任务，再执行可能触发诊断观察者或 Adapter 重入的动作。
        s.off = attempt;
        this.stopSubscription(s);
        const result = s.offNeeded && this.state === 'ready'
            ? this.control('bridge.unsubscribe', { subscriptionId: s.id }).then((r) => {
                s.offNeeded = false; // false 同样确认 Native 已无此订阅。
                return r;
            })
            : Promise.resolve({ accepted: false });
        // 失败不永久占用句柄；重试只清理 Native，不重新激活数据回调。
        void result.then(resolve, (error) => {
            if (s.off === attempt)
                s.off = undefined;
            reject(error);
        });
        return attempt;
    }
    bestEffortOff(id) {
        if (this.state === 'ready')
            void this.control('bridge.unsubscribe', { subscriptionId: id }).catch(() => { });
    }
    eventDeliverable(s) {
        return this.state !== 'closed' && s.phase !== 'off';
    }
    queueEvent(s, action, bytes = 256) {
        this.queue(() => {
            if (!this.eventDeliverable(s))
                return;
            this.log('callback.deliver', { subscriptionId: s.id });
            if (!this.eventDeliverable(s))
                return;
            try {
                action();
            }
            catch (e) {
                this.callbackError(e);
            }
        }, bytes, undefined, false, { subscriptionId: s.id });
    }
    failStream(s, error) {
        if (s.phase !== 'active')
            return;
        s.phase = 'terminal';
        this.clearStream(s);
        if (s.error) {
            const fn = s.error;
            this.queueEvent(s, () => fn(error));
        }
        this.releaseCallbacks(s);
        this.bestEffortOff(s.id);
    }
    receiveEvent(m) {
        const s = this.subscriptions.get(m.subscriptionId);
        if (!s || s.phase !== 'active')
            return;
        try {
            const seq = m.seq;
            if (seq <= s.last || s.buffer.has(seq))
                return;
            if (!s.acked) {
                if (s.buffer.size >= 32)
                    throw Error('Early event overflow');
                s.buffer.set(seq, m);
                return;
            }
            if (seq > s.last + 1) {
                if (s.buffer.size >= 32)
                    throw Error('Reorder overflow');
                s.buffer.set(seq, m);
                if (s.gap === undefined)
                    s.gap = setTimeout(() => this.failStream(s, failure('PROTOCOL_ERROR', 'Event sequence gap timed out')), 2000);
                return;
            }
            this.dispatchEvent(s, m);
            this.drainEvents(s);
        }
        catch {
            this.failStream(s, failure('PROTOCOL_ERROR', 'Invalid event stream'));
        }
    }
    drainEvents(s) {
        while (s.phase === 'active' && s.buffer.has(s.last + 1)) {
            const next = s.buffer.get(s.last + 1);
            if (!next)
                throw Error('Missing buffered event');
            s.buffer.delete(s.last + 1);
            this.dispatchEvent(s, next);
        }
        if (s.buffer.size === 0 && s.gap !== undefined) {
            clearTimeout(s.gap);
            s.gap = undefined;
        }
        else if (s.phase === 'active' && s.buffer.size > 0 && s.gap === undefined)
            s.gap = setTimeout(() => this.failStream(s, failure('PROTOCOL_ERROR', 'Event sequence gap timed out')), 2000);
    }
    dispatchEvent(s, m) {
        s.last = m.seq;
        if (Object.hasOwn(m, 'data')) {
            const fn = s.data;
            this.queueEvent(s, () => fn(m.data), this.weight(m));
            return;
        }
        s.phase = 'terminal';
        this.clearStream(s);
        if (Object.hasOwn(m, 'error')) {
            if (s.error) {
                const fn = s.error;
                this.queueEvent(s, () => fn(m.error), this.weight(m));
            }
        }
        else if (s.complete) {
            const fn = s.complete;
            this.queueEvent(s, fn, this.weight(m));
        }
        this.releaseCallbacks(s);
    }
    assertPendingCapacity(lane) {
        const ordinary = lane === 'control' ? this.pending.size : 0;
        const activeCalls = lane === 'business'
            ? Array.from(this.calls.values()).filter((call) => call.isPending).length
            : 0;
        if (ordinary + activeCalls >= (lane === 'business' ? 128 : 16))
            throw failure('TOO_MANY_REQUESTS', 'Pending limit reached');
    }
    register(callbackId, callback, timeoutMs) {
        const lane = 'control';
        this.assertPendingCapacity(lane);
        const timer = setTimeout(() => {
            this.finish(callbackId, failure('TIMEOUT', 'Request timed out; native side effects may still have occurred'));
            this.log('timeout', { callbackId, code: 'TIMEOUT' });
        }, timeoutMs);
        this.pending.set(callbackId, {
            started: this.diagnostics.now(),
            finish: callback,
            timer,
            lane,
        });
        this.diagnostics.gauge('pending.' + lane, 1); // 必须先于发送执行。
    }
    control(method, params, validate, onFailure) {
        return new Promise((resolve, reject) => {
            if (this.state !== 'ready') {
                reject(failure('DISCONNECTED', 'Bridge is closed'));
                return;
            }
            const callbackId = this.nextId();
            try {
                this.register(callbackId, (error, result) => {
                    if (error) {
                        onFailure?.(error);
                        reject(error);
                        return;
                    }
                    try {
                        if ((method === 'bridge.cancel' || method === 'bridge.unsubscribe') &&
                            typeof result?.accepted !== 'boolean')
                            throw failure('PROTOCOL_ERROR', 'Invalid control acknowledgement');
                        validate?.(result);
                        resolve(result);
                    }
                    catch (e) {
                        const failure = this.asError(e);
                        onFailure?.(failure);
                        reject(failure);
                    }
                }, 5000);
                this.transmit({ callbackId, method, params }, callbackId);
            }
            catch (e) {
                if (this.pending.has(callbackId))
                    this.finish(callbackId, this.asError(e));
                else
                    reject(e);
            }
        });
    }
    transmit(message, callbackId) {
        if (!this.canTransmit(callbackId))
            return;
        const raw = JSON.stringify(message);
        const fields = message;
        this.log('start', { callbackId: fields.callbackId, method: fields.method });
        this.log('send', { callbackId: fields.callbackId, method: fields.method });
        if (!this.canTransmit(callbackId))
            return;
        if (utf8Size(raw) > 256 * 1024)
            throw failure('PAYLOAD_TOO_LARGE', 'Message exceeds 256 KiB');
        const failed = () => {
            // 迟到的传输错误不能替换已完成的响应。
            if (!callbackId || this.canTransmit(callbackId))
                this.shutdown(failure('DISCONNECTED', 'Native transport send failed'));
        };
        try {
            void this.adapter.send(raw).catch(failed);
        }
        catch {
            failed();
        }
    }
    receive(raw) {
        if (this.state === 'closed')
            return;
        try {
            const m = decodeResponse(raw);
            this.log('receive', {
                callbackId: m.callbackId,
                subscriptionId: m.subscriptionId,
            });
            this.frameBytes.set(m, utf8Size(raw));
            if (m.method === 'bridge.close') {
                this.nativeClose(m, raw);
                return;
            }
            const callback = typeof m.callbackId === 'string' ? m.callbackId : undefined;
            const call = callback ? this.calls.get(callback) : undefined;
            // 终态交付记录在其排队回调交付前始终具有优先权。
            if (call) {
                if (!call.accepting)
                    return;
                try {
                    validateResponse(m, 'call', raw);
                    call.accept(m, this.weight(m));
                }
                catch {
                    call.fail('Invalid call response');
                }
                return;
            }
            const pending = callback ? this.pending.get(callback) : undefined;
            if (pending && callback) {
                try {
                    validateResponse(m, pending.lane === 'control' ? 'control' : 'call', raw);
                }
                catch {
                    this.finish(callback, failure('PROTOCOL_ERROR', 'Invalid native response'));
                    return;
                }
                this.finish(callback, Object.hasOwn(m, 'error') ? m.error : null, m.result, this.weight(m), true);
                return;
            }
            if (this.state === 'connecting' && callback === this.helloCallbackId) {
                validateResponse(m, 'control', raw);
                if (Object.hasOwn(m, 'error')) {
                    this.shutdown(m.error);
                    return;
                }
                if (m.result.ready !== true)
                    throw Error('Invalid readiness result');
                const h = this.handshake;
                if (!h)
                    throw Error('Missing handshake completion');
                this.state = 'ready';
                this.handshake = undefined;
                clearTimeout(h.timer);
                h.resolve();
                this.log('ready');
                return;
            }
            const subscription = typeof m.subscriptionId === 'string' ? this.subscriptions.get(m.subscriptionId) : undefined;
            if (subscription) {
                try {
                    validateResponse(m, 'event', raw);
                    this.receiveEvent(m);
                }
                catch {
                    this.failStream(subscription, failure('PROTOCOL_ERROR', 'Invalid event stream'));
                }
                return;
            }
            // 只有可靠且已完全退出的标识符才可跳过校验。
            const ids = ['callbackId', 'subscriptionId'].filter((k) => Object.hasOwn(m, k));
            if (ids.length > 0 && ids.every((k) => isResponseId(m[k])))
                return;
            throw Error('Unreliable response identifier');
        }
        catch {
            this.shutdown(failure('PROTOCOL_ERROR', 'Invalid native message'));
        }
    }
    nativeClose(m, raw) {
        const p = m.params;
        if (utf8Size(raw) > 256 * 1024 ||
            Object.keys(m).sort().join(',') !== 'method,params' ||
            !p ||
            typeof p !== 'object' ||
            Array.isArray(p))
            throw Error('Invalid native close');
        const fields = p;
        if (Object.keys(fields).sort().join(',') !== 'code,reason' ||
            !['BACKPRESSURE', 'DISCONNECTED'].includes(fields.code) ||
            typeof fields.reason !== 'string' ||
            fields.reason.length < 1 ||
            fields.reason.length > 256)
            throw Error('Invalid native close');
        this.shutdown(failure(fields.code, fields.reason), false);
    }
    releasePending(p, id, error) {
        this.diagnostics.gauge('pending.' + p.lane, -1);
        this.diagnostics.observe('request', this.diagnostics.now() - p.started);
    }
    endLog(p, id, error) {
        this.log('end', { callbackId: id, code: error?.code });
        if (error)
            this.log('error', { callbackId: id, code: error.code });
    }
    finish(callbackId, error, result, bytes = 256, received = false) {
        const p = this.pending.get(callbackId);
        if (!p)
            return;
        this.pending.delete(callbackId);
        clearTimeout(p.timer);
        this.releasePending(p, callbackId, error); // 在用户代码执行前清理。
        p.finish(error, result);
        this.endLog(p, callbackId, error);
    }
    asError(e) {
        if (e &&
            typeof e === 'object' &&
            'code' in e &&
            'message' in e &&
            typeof e.code === 'string' &&
            typeof e.message === 'string')
            return { code: e.code, message: e.message };
        return failure('INVALID_ARGUMENT', 'Cannot encode request');
    }
    closeTransport(text) {
        if (!this.closeTask) {
            // 先保存共享任务，再执行可能同步重入的 Adapter。
            this.closeTask = Promise.resolve().then(async () => {
                let timer;
                try {
                    if (text)
                        await Promise.race([
                            this.adapter.send(text),
                            new Promise((resolve) => {
                                timer = setTimeout(resolve, 250);
                            }),
                        ]);
                }
                catch {
                }
                finally {
                    if (timer !== undefined)
                        clearTimeout(timer);
                    try {
                        await this.adapter.close();
                    }
                    catch { }
                }
            });
        }
        return this.closeTask;
    }
    shutdown(error, notifyNative = true) {
        if (this.state === 'closed')
            return;
        const close = notifyNative && (this.state === 'ready' || this.state === 'connecting')
            ? JSON.stringify({
                callbackId: this.nextId(),
                method: 'bridge.close',
                params: { reason: 'SDK close' },
            })
            : undefined;
        this.state = 'closed';
        void this.closeTransport(close);
        this.log('close', { code: error.code });
        for (const s of this.calls.values())
            s.close(error, true);
        for (const s of this.subscriptions.values())
            this.stopSubscription(s);
        const h = this.handshake;
        this.handshake = undefined;
        if (h) {
            clearTimeout(h.timer);
            h.reject(error);
        }
        for (const callbackId of this.pending.keys())
            this.finish(callbackId, error);
    }
    async dispose() {
        this.shutdown(failure('DISCONNECTED', 'Bridge disposed'));
        await this.closeTask;
    }
}
