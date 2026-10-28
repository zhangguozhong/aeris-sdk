/** 仅记录桥接层诊断；应用回调异常处理器遵循各自策略。 */
export interface DiagnosticRecord {
  timeMs: number;
  stage: string;
  clientId?: string;
  callbackId?: string;
  subscriptionId?: string;
  method?: string;
  topic?: string;
  code?: string;
}
export interface DiagnosticSnapshot {
  counters: Record<string, number>;
  gauges: Record<string, number>;
  peaks: Record<string, number>;
  latency: Record<string, { count: number; sumMs: number; maxMs: number; buckets: number[] }>;
  records: DiagnosticRecord[];
}
export interface DiagnosticOptions {
  capacity?: number;
  observer?: (record: Readonly<DiagnosticRecord>) => void;
  clock?: () => number;
}
const stages = new Set([
  'ready',
  'start',
  'send',
  'receive',
  'callback.enqueue',
  'callback.deliver',
  'end',
  'error',
  'timeout',
  'cancel',
  'close',
  'backpressure',
  'callback.exception',
  'callback.discard',
  'observer.error',
]);
const gaugeNames = new Set([
  'queue.messages',
  'queue.bytes',
  'queue.urgentMessages',
  'queue.urgentBytes',
  'pending.business',
  'pending.control',
  'calls',
  'subscriptions',
]);
const codes = new Set([
  'BACKPRESSURE',
  'DISCONNECTED',
  'PROTOCOL_ERROR',
  'CANCELLED',
  'TIMEOUT',
  'INVALID_ARGUMENT',
  'INVALID_METHOD',
  'PAYLOAD_TOO_LARGE',
  'TOO_MANY_REQUESTS',
  'TOO_MANY_SUBSCRIPTIONS',
  'NOT_READY',
  'BRIDGE_UNAVAILABLE',
  'PERMISSION_DENIED',
  'METHOD_NOT_FOUND',
  'EVENT_NOT_FOUND',
  'EVENT_UNAVAILABLE',
  'UI_UNAVAILABLE',
  'INTERNAL_ERROR',
  'BUSY',
]);
const id = (v: unknown) =>
  typeof v === 'string' && v.length <= 256 && /^[A-Za-z0-9_-]+:[A-Za-z0-9_-]+$/.test(v);
export class BridgeDiagnostics {
  private readonly counters: Record<string, number> = {};
  private readonly gauges: Record<string, number> = {};
  private readonly peaks: Record<string, number> = {};
  private readonly latency: DiagnosticSnapshot['latency'] = {};
  private readonly ring: DiagnosticRecord[] = [];
  private readonly capacity: number;
  private readonly observer?: DiagnosticOptions['observer'];
  private readonly clock: () => number;
  private notifying = false;
  private last = 0;
  constructor(options: DiagnosticOptions = {}) {
    this.capacity = options.capacity ?? 128;
    if (!Number.isInteger(this.capacity) || this.capacity < 0 || this.capacity > 1024)
      throw RangeError('Invalid diagnostics capacity');
    this.observer = options.observer;
    this.clock = options.clock ?? (() => globalThis.performance?.now?.() ?? Date.now());
  }
  now(): number {
    let n: number;
    try {
      n = this.clock();
    } catch {
      n = this.last;
    }
    if (Number.isFinite(n)) this.last = Math.max(this.last, n);
    return this.last;
  }
  record(stage: string, fields: Partial<Omit<DiagnosticRecord, 'timeMs' | 'stage'>> = {}): void {
    if (!stages.has(stage)) return;
    this.counters[stage] = (this.counters[stage] ?? 0) + 1;
    const r: DiagnosticRecord = { timeMs: this.now(), stage };
    if (
      typeof fields.clientId === 'string' &&
      fields.clientId.length <= 256 &&
      /^[A-Za-z0-9_-]+$/.test(fields.clientId)
    )
      r.clientId = fields.clientId;
    if (id(fields.callbackId)) r.callbackId = fields.callbackId;
    if (id(fields.subscriptionId)) r.subscriptionId = fields.subscriptionId;
    if (
      typeof fields.method === 'string' &&
      fields.method.length <= 256 &&
      /^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)?$/.test(fields.method)
    )
      r.method = fields.method;
    if (
      typeof fields.topic === 'string' &&
      fields.topic.length <= 128 &&
      /^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)*$/.test(fields.topic)
    )
      r.topic = fields.topic;
    if (fields.code !== undefined) r.code = codes.has(fields.code) ? fields.code : 'OTHER';
    if (this.capacity) {
      this.ring.push({ ...r });
      if (this.ring.length > this.capacity) this.ring.shift();
    }
    if (this.observer && !this.notifying) {
      this.notifying = true;
      try {
        this.observer(Object.freeze({ ...r }));
      } catch {
        this.counters['observer.error'] = (this.counters['observer.error'] ?? 0) + 1;
      } finally {
        this.notifying = false;
      }
    }
  }
  gauge(name: string, delta: number): void {
    if (!gaugeNames.has(name) || !Number.isFinite(delta)) return;
    const n = (this.gauges[name] ?? 0) + delta;
    this.gauges[name] = Math.max(0, n);
    this.peaks[name] = Math.max(this.peaks[name] ?? 0, this.gauges[name]);
  }
  observe(name: 'request' | 'queue' | 'cleanup', ms: number): void {
    if (!['request', 'queue', 'cleanup'].includes(name) || !Number.isFinite(ms)) return;
    ms = Math.max(0, ms);
    const h =
      this.latency[name] ??
      (this.latency[name] = { count: 0, sumMs: 0, maxMs: 0, buckets: Array(9).fill(0) });
    h.count++;
    h.sumMs += ms;
    h.maxMs = Math.max(h.maxMs, ms);
    const index = [1, 5, 10, 50, 100, 500, 1000, 5000].findIndex((x) => ms <= x);
    h.buckets[index < 0 ? 8 : index]++;
  }
  snapshot(): DiagnosticSnapshot {
    return {
      counters: { ...this.counters },
      gauges: { ...this.gauges },
      peaks: { ...this.peaks },
      latency: Object.fromEntries(
        Object.entries(this.latency).map(([k, v]) => [k, { ...v, buckets: [...v.buckets] }]),
      ),
      records: this.ring.map((r) => ({ ...r })),
    };
  }
  reset(): void {
    for (const k of Object.keys(this.counters)) delete this.counters[k];
    for (const k of Object.keys(this.peaks)) this.peaks[k] = this.gauges[k] ?? 0;
    for (const k of Object.keys(this.latency)) delete this.latency[k];
    this.ring.length = 0;
  }
}
