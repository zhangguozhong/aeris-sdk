import { BridgeDiagnostics } from './diagnostics.js';
export interface FlowLimits {
    maxMessages: number;
    maxBytes: number;
    urgentMessages: number;
    urgentBytes: number;
    batchSize: number;
}
export interface ClientOptions {
    flowLimits?: Partial<FlowLimits>;
    diagnostics?: BridgeDiagnostics;
}
/** 统计编码后载荷的字节数，不统计任意应用闭包引用图或宿主 SDK 缓冲。 */
export declare class BridgeDeliveryQueue {
    private readonly normal;
    private readonly urgent;
    private bytes;
    private urgentBytes;
    private scheduled;
    private draining;
    private pressured;
    readonly limits: FlowLimits;
    private readonly diagnostics;
    private readonly pressure;
    constructor(diagnostics: BridgeDiagnostics, pressure: () => void, limits?: Partial<FlowLimits>);
    get failed(): boolean;
    get terminalAvailable(): boolean;
    assertAdmission(closed?: boolean): void;
    post(run: () => void, bytes?: number, discard?: () => void, urgent?: boolean): boolean;
    private adjust;
    private schedule;
    private drain;
}
