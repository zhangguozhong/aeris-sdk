import { failure } from './protocol.js';
/** 统计编码后载荷的字节数，不统计任意应用闭包引用图或宿主 SDK 缓冲。 */
export class BridgeDeliveryQueue {
    normal = [];
    urgent = [];
    bytes = 0;
    urgentBytes = 0;
    scheduled = false;
    draining = false;
    pressured = false;
    limits;
    diagnostics;
    pressure;
    constructor(diagnostics, pressure, limits = {}) {
        this.diagnostics = diagnostics;
        this.pressure = pressure;
        this.limits = {
            maxMessages: 256,
            maxBytes: 4 * 1024 * 1024,
            urgentMessages: 512,
            urgentBytes: 512 * 1024,
            batchSize: 32,
            ...limits,
        };
        for (const n of Object.values(this.limits))
            if (!Number.isSafeInteger(n) || n < 1)
                throw RangeError('Invalid flow limit');
        if (this.limits.batchSize > 32)
            throw RangeError('Batch size must not exceed 32');
    }
    get failed() {
        return this.pressured;
    }
    get terminalAvailable() {
        return (this.urgent.length < this.limits.urgentMessages &&
            this.urgentBytes + 1024 <= this.limits.urgentBytes);
    }
    assertAdmission(closed = false) {
        if ((this.pressured || closed) && !this.terminalAvailable)
            throw failure('BACKPRESSURE', 'Bridge callback reserve exhausted');
    }
    post(run, bytes = 0, discard, urgent = false) {
        bytes = Math.max(0, Math.ceil(bytes));
        if (!Number.isSafeInteger(bytes))
            bytes = Number.MAX_SAFE_INTEGER;
        if (urgent) {
            if (this.urgent.length >= this.limits.urgentMessages ||
                this.urgentBytes + bytes > this.limits.urgentBytes) {
                this.diagnostics.record('backpressure');
                this.diagnostics.record('callback.discard');
                if (!this.pressured) {
                    this.pressured = true;
                    this.pressure();
                }
                return false;
            }
            this.urgent.push({ run, bytes, at: this.diagnostics.now() });
            this.urgentBytes += bytes;
            this.adjust(true, 1, bytes);
            this.schedule(false);
            return true;
        }
        if (this.pressured) {
            discard?.();
            return false;
        }
        if (this.normal.length >= this.limits.maxMessages ||
            this.bytes + bytes > this.limits.maxBytes) {
            this.pressured = true;
            const dropped = this.normal.splice(0);
            this.bytes = 0;
            for (const job of dropped)
                this.adjust(false, -1, -job.bytes);
            // 回退仅包含有界错误，不保留被丢弃的载荷。
            this.pressure();
            for (const job of dropped)
                job.discard?.();
            discard?.();
            this.schedule(false);
            return false;
        }
        this.normal.push({ run, discard, bytes, at: this.diagnostics.now() });
        this.bytes += bytes;
        this.adjust(false, 1, bytes);
        this.schedule(false);
        return true;
    }
    adjust(urgent, count, bytes) {
        this.diagnostics.gauge(urgent ? 'queue.urgentMessages' : 'queue.messages', count);
        this.diagnostics.gauge(urgent ? 'queue.urgentBytes' : 'queue.bytes', bytes);
    }
    schedule(yieldHost) {
        if (this.scheduled || this.draining || (!this.normal.length && !this.urgent.length))
            return;
        this.scheduled = true;
        if (yieldHost)
            setTimeout(() => this.drain(), 0);
        else
            queueMicrotask(() => this.drain());
    }
    drain() {
        this.scheduled = false;
        if (this.draining)
            return;
        this.draining = true;
        try {
            for (let i = 0; i < this.limits.batchSize; i++) {
                const urgent = this.urgent.length > 0, job = (urgent ? this.urgent : this.normal).shift();
                if (!job)
                    break;
                if (urgent)
                    this.urgentBytes -= job.bytes;
                else
                    this.bytes -= job.bytes;
                this.adjust(urgent, -1, -job.bytes);
                this.diagnostics.observe('queue', this.diagnostics.now() - job.at);
                try {
                    job.run();
                }
                catch {
                    this.diagnostics.record('callback.exception');
                }
            }
        }
        finally {
            this.draining = false;
            this.schedule(true);
        }
    }
}
