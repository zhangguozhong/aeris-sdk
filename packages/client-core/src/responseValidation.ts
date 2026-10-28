import { assertJSON, utf8Size } from './protocol.js';

export type ResponseMode = 'call' | 'control' | 'event';
export function isResponseId(value: unknown): value is string {
  return (
    typeof value === 'string' &&
    utf8Size(value) <= 256 &&
    /^[A-Za-z0-9_-]+:[A-Za-z0-9_-]+$/.test(value)
  );
}
const object = (value: unknown): value is Record<string, unknown> =>
  value !== null && typeof value === 'object' && !Array.isArray(value);

/** 在 JSON.parse 前限制工作量，并拒绝重复键，包括转义后的等价键。 */
export function decodeResponse(raw: string): Record<string, unknown> {
  if (typeof raw !== 'string' || utf8Size(raw) > 2 * 1024 * 1024)
    throw Error('Routing parse limit exceeded');
  let i = 0;
  const space = () => {
    while (i < raw.length && /[\x20\t\r\n]/.test(raw[i])) i++;
  };
  const string = (): string => {
    const start = i++;
    while (i < raw.length) {
      const c = raw[i++];
      if (c === '"') {
        const decoded = JSON.parse(raw.slice(start, i)) as string;
        // 在解码器替换孤立 UTF16 代理码元并导致键混淆前拒绝它们。
        for (let unit = 0; unit < decoded.length; unit++) {
          const code = decoded.charCodeAt(unit);
          if (code >= 0xd800 && code <= 0xdbff) {
            const low = decoded.charCodeAt(++unit);
            if (!(low >= 0xdc00 && low <= 0xdfff)) throw Error('Isolated surrogate');
          } else if (code >= 0xdc00 && code <= 0xdfff) throw Error('Isolated surrogate');
        }
        return decoded;
      }
      if (c === '\\') i++;
    }
    throw Error('Unterminated string');
  };
  const value = (depth: number): void => {
    space();
    const c = raw[i];
    if (c === '{' || c === '[') {
      if (depth >= 64) throw Error('JSON nesting exceeds 64');
      i++;
      space();
      const end = c === '{' ? '}' : ']',
        keys = new Set<string>();
      if (raw[i] === end) {
        i++;
        return;
      }
      for (;;) {
        if (c === '{') {
          space();
          if (raw[i] !== '"') throw Error('Expected key');
          const key = string();
          if (keys.has(key)) throw Error('Duplicate key');
          keys.add(key);
          space();
          if (raw[i++] !== ':') throw Error('Expected colon');
        }
        value(depth + 1);
        space();
        if (raw[i] === end) {
          i++;
          return;
        }
        if (raw[i++] !== ',') throw Error('Expected comma');
      }
    }
    if (c === '"') {
      string();
      return;
    }
    const start = i;
    while (i < raw.length && !/[\x20\t\r\n,\]}]/.test(raw[i])) i++;
    if (i === start) throw Error('Expected JSON value');
  };
  value(0);
  space();
  if (i !== raw.length) throw Error('Trailing JSON');
  const decoded: unknown = JSON.parse(raw);
  if (!object(decoded)) throw Error('Expected root object');
  return decoded;
}
function errorValue(value: unknown): void {
  if (
    !object(value) ||
    Object.keys(value).some((k) => k !== 'code' && k !== 'message') ||
    typeof value.code !== 'string' ||
    value.code.length < 1 ||
    value.code.length > 128 ||
    typeof value.message !== 'string' ||
    value.message.length < 1 ||
    value.message.length > 4096
  )
    throw Error('Invalid error');
}
function payload(value: unknown): void {
  if (!object(value)) throw Error('Expected payload object');
  assertJSON(value);
}

/** 仅校验模式；Core 先选择已知目标，再调用此严格校验器。 */
export function validateResponse(
  m: Record<string, unknown>,
  mode: ResponseMode,
  raw: string,
): void {
  if (utf8Size(raw) > 256 * 1024) throw Error('Response exceeds 256 KiB');
  const event = mode === 'event';
  const allowed = event
    ? ['subscriptionId', 'seq', 'data', 'error', 'complete']
    : ['callbackId', 'seq', 'finished', 'result', 'error', 'extra'];
  if (
    Object.keys(m).some((k) => !allowed.includes(k)) ||
    !isResponseId(m[event ? 'subscriptionId' : 'callbackId'])
  )
    throw Error('Invalid response envelope');
  if (!Number.isSafeInteger(m.seq) || (m.seq as number) < 1) throw Error('Invalid sequence');
  if (event) {
    const fields = ['data', 'error', 'complete'].filter((k) => Object.hasOwn(m, k));
    if (fields.length !== 1) throw Error('Expected one event output');
    if (fields[0] === 'data') payload(m.data);
    else if (fields[0] === 'error') errorValue(m.error);
    else if (m.complete !== true) throw Error('Invalid completion');
    return;
  }
  const result = Object.hasOwn(m, 'result'),
    error = Object.hasOwn(m, 'error');
  if (result === error || (Object.hasOwn(m, 'extra') && typeof m.extra !== 'string'))
    throw Error('Invalid response output');
  if (mode === 'call') {
    if (typeof m.finished !== 'boolean' || (error && m.finished !== true))
      throw Error('Invalid call finality');
  } else if (m.seq !== 1 || (Object.hasOwn(m, 'finished') && m.finished !== true))
    throw Error('Invalid final response');
  if (error) errorValue(m.error);
  else payload(m.result);
}
