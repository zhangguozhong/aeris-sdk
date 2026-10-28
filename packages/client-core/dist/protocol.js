export const failure = (code, message) => ({ code, message });
export function utf8Size(text) {
    let size = 0;
    for (const c of text) {
        const n = c.codePointAt(0);
        if (n === undefined)
            throw Error('Missing Unicode code point');
        size += n <= 0x7f ? 1 : n <= 0x7ff ? 2 : n <= 0xffff ? 3 : 4;
    }
    return size;
}
export function assertJSON(value, seen = new Set(), depth = 0) {
    if (depth > 32)
        throw failure('INVALID_ARGUMENT', 'JSON nesting exceeds 32');
    if (value === null || typeof value === 'string' || typeof value === 'boolean')
        return;
    if (typeof value === 'number' &&
        Number.isFinite(value) &&
        (!Number.isInteger(value) || Number.isSafeInteger(value)))
        return;
    if (typeof value !== 'object' || !value)
        throw failure('INVALID_ARGUMENT', 'Unsupported JSON value');
    if (seen.has(value))
        throw failure('INVALID_ARGUMENT', 'Circular params');
    if (!Array.isArray(value) &&
        Object.getPrototypeOf(value) !== Object.prototype &&
        Object.getPrototypeOf(value) !== null)
        throw failure('INVALID_ARGUMENT', 'Params must contain plain JSON values');
    seen.add(value);
    for (const [key, item] of Object.entries(value)) {
        if (['__proto__', 'prototype', 'constructor'].includes(key))
            throw failure('INVALID_ARGUMENT', 'Reserved key');
        assertJSON(item, seen, depth + 1);
    }
    seen.delete(value);
}
