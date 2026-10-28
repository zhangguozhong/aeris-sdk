export type ResponseMode = 'call' | 'control' | 'event';
export declare function isResponseId(value: unknown): value is string;
/** 在 JSON.parse 前限制工作量，并拒绝重复键，包括转义后的等价键。 */
export declare function decodeResponse(raw: string): Record<string, unknown>;
/** 仅校验模式；Core 先选择已知目标，再调用此严格校验器。 */
export declare function validateResponse(m: Record<string, unknown>, mode: ResponseMode, raw: string): void;
