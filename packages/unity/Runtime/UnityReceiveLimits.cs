using System;

namespace Aeris
{
/// 入站预算按 UTF-8 字节计费；不表示托管堆的精确大小。
public sealed class UnityReceiveLimits
{
    public int MaxMessages { get; private set; }
    public long MaxBytes { get; private set; }

    public UnityReceiveLimits(int maxMessages = 128, long maxBytes = 4 * 1024 * 1024)
    {
        if (maxMessages <= 0 || maxBytes <= 0)
            throw new ArgumentOutOfRangeException("Receive limits must be positive");
        MaxMessages = maxMessages;
        MaxBytes = maxBytes;
    }
}
}
