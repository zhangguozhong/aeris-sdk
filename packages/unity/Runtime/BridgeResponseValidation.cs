using System;
using System.Text;
using System.Text.RegularExpressions;
using Newtonsoft.Json.Linq;

namespace Aeris
{
// 共享入站模式；Core 先选择已知所有者，再应用这些规则。
internal static class BridgeResponseValidation
{
    public static bool ValidId(string id)
    {
        return id != null && Encoding.UTF8.GetByteCount(id) <= 256 &&
               Regex.IsMatch(id, @"\A[A-Za-z0-9_-]+:[A-Za-z0-9_-]+\z");
    }
    public static long Sequence(JToken token)
    {
        if (token == null || (token.Type != JTokenType.Integer && token.Type != JTokenType.Float))
            throw new FormatException("Invalid sequence");
        double n = token.Value<double>();
        if (double.IsNaN(n) || double.IsInfinity(n) || n < 1 || n > 9007199254740991d ||
            Math.Truncate(n) != n)
            throw new FormatException("Invalid sequence");
        return (long)n;
    }
    public static long Validate(JObject frame, string mode)
    {
        bool events = mode == "event", call = mode == "call";
        foreach (var p in frame.Properties())
        {
            bool allowed =
                events ? (p.Name == "subscriptionId" || p.Name == "seq" || p.Name == "data" ||
                          p.Name == "error" || p.Name == "complete")
                       : (p.Name == "callbackId" || p.Name == "seq" || p.Name == "finished" ||
                          p.Name == "result" || p.Name == "error" || p.Name == "extra");
            if (!allowed)
                throw new FormatException("Unknown response field");
        }
        if (!ValidId(BridgeJson.Text(frame, events ? "subscriptionId" : "callbackId")))
            throw new FormatException("Invalid response identifier");
        long seq = Sequence(frame["seq"]);
        if (!events && !call && seq != 1)
            throw new FormatException("Ordinary sequence must be one");
        bool result = frame.Property(events ? "data" : "result") != null,
             error = frame.Property("error") != null;
        if (events)
        {
            bool complete = frame.Property("complete") != null;
            if ((result ? 1 : 0) + (error ? 1 : 0) + (complete ? 1 : 0) != 1)
                throw new FormatException("Expected one event output");
            if (complete &&
                (frame["complete"].Type != JTokenType.Boolean || !(bool)frame["complete"]))
                throw new FormatException("Invalid completion");
        }
        else
        {
            if (result == error)
                throw new FormatException("Expected one response output");
            if (frame.Property("extra") != null && BridgeJson.Text(frame, "extra") == null)
                throw new FormatException("Invalid extra");
            var finished = frame["finished"];
            if (call && finished == null ||
                finished != null &&
                    (finished.Type != JTokenType.Boolean || (!call || error) && !(bool)finished))
                throw new FormatException("Invalid terminal flag");
        }
        if (result)
        {
            var value = frame[events ? "data" : "result"] as JObject;
            if (value == null)
                throw new FormatException("Expected payload object");
            BridgeJson.ValidateParams(value);
        }
        else if (error)
            ReadError(frame["error"]);
        return seq;
    }
    public static BridgeError ReadError(JToken token)
    {
        var value = token as JObject;
        if (value == null)
            throw new FormatException("Invalid error");
        foreach (var p in value.Properties())
            if (p.Name != "code" && p.Name != "message")
                throw new FormatException("Unknown error field");
        string code = BridgeJson.Text(value, "code"), message = BridgeJson.Text(value, "message");
        if (code == null || message == null || code.Length < 1 || code.Length > 128 ||
            message.Length < 1 || message.Length > 4096)
            throw new FormatException("Invalid error bounds");
        return new BridgeError(code, message);
    }
}
}
