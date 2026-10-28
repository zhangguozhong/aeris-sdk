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
    latency: Record<string, {
        count: number;
        sumMs: number;
        maxMs: number;
        buckets: number[];
    }>;
    records: DiagnosticRecord[];
}
export interface DiagnosticOptions {
    capacity?: number;
    observer?: (record: Readonly<DiagnosticRecord>) => void;
    clock?: () => number;
}
export declare class BridgeDiagnostics {
    private readonly counters;
    private readonly gauges;
    private readonly peaks;
    private readonly latency;
    private readonly ring;
    private readonly capacity;
    private readonly observer?;
    private readonly clock;
    private notifying;
    private last;
    constructor(options?: DiagnosticOptions);
    now(): number;
    record(stage: string, fields?: Partial<Omit<DiagnosticRecord, 'timeMs' | 'stage'>>): void;
    gauge(name: string, delta: number): void;
    observe(name: 'request' | 'queue' | 'cleanup', ms: number): void;
    snapshot(): DiagnosticSnapshot;
    reset(): void;
}
