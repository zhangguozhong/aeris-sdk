using System;
using System.IO;
using System.Text;
using System.Text.RegularExpressions;
using Newtonsoft.Json;
using Newtonsoft.Json.Linq;

namespace Aeris
{
// 仅使用 LINQ-to-JSON，不使用 TypeNameHandling、ToObject<T>、Unity 反射或任意 CLR 对象。
internal static class BridgeJson
{
    public const int MaxBytes = 256 * 1024;
    public static JObject ParseObject(string text, int limit = MaxBytes)
    {
        return ParseObject(text, limit, false);
    }
    // 此阶段仅进行有界关联；活动响应会依据
    // 严格协议限制再次解析，已退出响应的载荷不会影响活动调用。
    public static JObject ParseResponseObject(string text)
    {
        if (text == null || Encoding.UTF8.GetByteCount(text) > 2 * 1024 * 1024)
            throw new FormatException("Invalid message size");
        new JsonSyntax(text, 64).Validate();
        // 此阶段仅使用 callbackId/subscriptionId 字符串。屏蔽 JSON
        // 数字，使 1e999 等溢出值仍能进入每条流的严格校验。
        // 引号字符串逐字节保留，包括转义引号与数字形式的 ID。
        string routing = Regex.Replace(
            text, @"""(?:\\.|[^""\\])*""|-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?",
            match => match.Value[0] == '"' ? match.Value : "0");
        return ParseObject(routing, 2 * 1024 * 1024, true);
    }
    static JObject ParseObject(string text, int limit, bool routing)
    {
        if (text == null || Encoding.UTF8.GetByteCount(text) > limit)
            throw new FormatException("Invalid message size");
        new JsonSyntax(text, 64).Validate();
        using (var input = new StringReader(text)) using (var reader = new WireJsonReader(input))
        {
            reader.DateParseHandling = DateParseHandling.None;
            reader.MaxDepth = 64;
            var token = JToken.Load(
                reader, new JsonLoadSettings { DuplicatePropertyNameHandling =
                                                   DuplicatePropertyNameHandling.Error });
            if (reader.Read())
                throw new FormatException("Additional JSON content");
            var obj = token as JObject;
            if (obj == null)
                throw new FormatException("Expected JSON object");
            return obj;
        }
    }
    // Json.NET 支持 JavaScript 扩展，包括十六进制或八进制数字、
    // 无引号键及尾随逗号；因此在解析值前先校验 JSON 语法。
    // 仅使用索引与有界递归，不转换数字词法单元。
    sealed class JsonSyntax
    {
        readonly string text;
        readonly int maxDepth;
        int index;
        public JsonSyntax(string text, int maxDepth)
        {
            this.text = text;
            this.maxDepth = maxDepth;
        }
        public void Validate()
        {
            Whitespace();
            Value(0);
            Whitespace();
            if (index != text.Length)
                Invalid();
        }
        static void Invalid()
        {
            throw new FormatException("Invalid JSON syntax");
        }
        void Whitespace()
        {
            while (index < text.Length && (text[index] == ' ' || text[index] == '\t' ||
                                           text[index] == '\r' || text[index] == '\n'))
                index++;
        }
        bool Take(char value)
        {
            if (index >= text.Length || text[index] != value)
                return false;
            index++;
            return true;
        }
        void Require(char value)
        {
            if (!Take(value))
                Invalid();
        }
        static bool Digit(char value)
        {
            return value >= '0' && value <= '9';
        }
        static bool Hex(char value)
        {
            return Digit(value) || value >= 'a' && value <= 'f' || value >= 'A' && value <= 'F';
        }
        void Value(int depth)
        {
            if (index >= text.Length)
                Invalid();
            char token = text[index];
            if (token == '{' || token == '[')
            {
                if (depth >= maxDepth)
                    Invalid();
                index++;
                Whitespace();
                char close = token == '{' ? '}' : ']';
                if (Take(close))
                    return;
                while (true)
                {
                    if (token == '{')
                    {
                        String();
                        Whitespace();
                        Require(':');
                        Whitespace();
                    }
                    Value(depth + 1);
                    Whitespace();
                    if (Take(close))
                        return;
                    Require(',');
                    Whitespace();
                }
            }
            if (token == '"')
            {
                String();
                return;
            }
            if (token == 't')
            {
                Literal("true");
                return;
            }
            if (token == 'f')
            {
                Literal("false");
                return;
            }
            if (token == 'n')
            {
                Literal("null");
                return;
            }
            Number();
        }
        void Literal(string value)
        {
            foreach (char character in value)
                Require(character);
        }
        char UnicodeUnit()
        {
            int code = 0;
            for (int n = 0; n < 4; n++)
            {
                if (index >= text.Length || !Hex(text[index]))
                    Invalid();
                char c = text[index++];
                code = code * 16 + (c <= '9' ? c - '0' : c <= 'F' ? c - 'A' + 10 : c - 'a' + 10);
            }
            return (char)code;
        }
        void String()
        {
            Require('"');
            bool high = false;
            while (index < text.Length)
            {
                char character = text[index++];
                if (character == '"')
                {
                    if (high)
                        Invalid();
                    return;
                }
                if (character < 0x20)
                    Invalid();
                if (character == '\\')
                {
                    if (index >= text.Length)
                        Invalid();
                    char escape = text[index++];
                    if (escape == 'u')
                        character = UnicodeUnit();
                    else if (escape == '"' || escape == '\\' || escape == '/' || escape == 'b' ||
                             escape == 'f' || escape == 'n' || escape == 'r' || escape == 't')
                        character = escape;
                    else
                    {
                        Invalid();
                        return;
                    }
                }
                // Json.NET 会替换孤立代理码元，可能使不同对象键变为相同键。
                // 在解码值前拒绝它们，并保持有效的 UTF16 码元对不变。
                if (char.IsHighSurrogate(character))
                {
                    if (high)
                        Invalid();
                    high = true;
                }
                else if (char.IsLowSurrogate(character))
                {
                    if (!high)
                        Invalid();
                    high = false;
                }
                else if (high)
                    Invalid();
            }
            Invalid();
        }
        void Number()
        {
            Take('-');
            if (!Take('0'))
            {
                if (index >= text.Length || text[index] < '1' || text[index] > '9')
                    Invalid();
                do
                {
                    index++;
                } while (index < text.Length && Digit(text[index]));
            }
            if (Take('.'))
                Digits();
            if (Take('e') || Take('E'))
            {
                if (!Take('+'))
                    Take('-');
                Digits();
            }
        }
        void Digits()
        {
            if (index >= text.Length || !Digit(text[index]))
                Invalid();
            do
            {
                index++;
            } while (index < text.Length && Digit(text[index]));
        }
    }
    // 否则 Json.NET 会接受 RN JSON.parse 拒绝的 JavaScript 专用字面量。
    sealed class WireJsonReader : JsonTextReader
    {
        public WireJsonReader(TextReader reader) : base(reader)
        {
        }
        public override bool Read()
        {
            bool more = base.Read();
            if (!more)
                return false;
            if (TokenType == JsonToken.Undefined || TokenType == JsonToken.StartConstructor ||
                TokenType == JsonToken.EndConstructor || TokenType == JsonToken.Comment)
                throw new FormatException("Non-JSON token");
            if ((TokenType == JsonToken.PropertyName || TokenType == JsonToken.String) &&
                QuoteChar != '"')
                throw new FormatException("Expected double quoted JSON string");
            if (TokenType == JsonToken.Float)
            {
                double number =
                    Convert.ToDouble(Value, System.Globalization.CultureInfo.InvariantCulture);
                if (double.IsNaN(number) || double.IsInfinity(number))
                    throw new FormatException("Non-finite JSON number");
            }
            return true;
        }
    }
    public static string Stringify(JObject value, int limit = MaxBytes)
    {
        string raw = value.ToString(Formatting.None);
        if (Encoding.UTF8.GetByteCount(raw) > limit)
            throw new BridgeError("PAYLOAD_TOO_LARGE", "Message exceeds its byte limit");
        return raw;
    }
    public static void ValidateParams(JToken token, int depth = 0)
    {
        if (token == null || depth > 32)
            throw new BridgeError("INVALID_ARGUMENT", "Invalid JSON parameters or nesting");
        switch (token.Type)
        {
        case JTokenType.Object:
            foreach (var p in ((JObject)token).Properties())
            {
                if (p.Name == "__proto__" || p.Name == "prototype" || p.Name == "constructor")
                    throw new BridgeError("INVALID_ARGUMENT", "Reserved parameter key");
                ValidateParams(p.Value, depth + 1);
            }
            return;
        case JTokenType.Array:
            foreach (var child in (JArray)token)
                ValidateParams(child, depth + 1);
            return;
        case JTokenType.Null:
        case JTokenType.Boolean:
        case JTokenType.String:
            return;
        case JTokenType.Integer:
        case JTokenType.Float:
            double number;
            try
            {
                number = token.Value<double>();
            }
            catch
            {
                throw new BridgeError("INVALID_ARGUMENT", "Invalid number");
            }
            if (double.IsNaN(number) || double.IsInfinity(number) ||
                (Math.Truncate(number) == number && Math.Abs(number) > 9007199254740991d))
                throw new BridgeError("INVALID_ARGUMENT", "Number is not JSON interoperable");
            return;
        default:
            throw new BridgeError("INVALID_ARGUMENT", "Only JSON parameter values are supported");
        }
    }
    public static string Text(JObject value, string key)
    {
        var t = value[key];
        return t != null && t.Type == JTokenType.String ? (string)t : null;
    }
    public static bool Integer(JObject value, string key, long expected)
    {
        var t = value[key];
        return t != null && (t.Type == JTokenType.Integer || t.Type == JTokenType.Float) &&
               t.Value<double>() == expected;
    }
}
}
