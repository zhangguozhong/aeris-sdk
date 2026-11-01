package com.aeris.sdk

import com.google.gson.*
import com.google.gson.stream.JsonReader
import com.google.gson.stream.JsonToken
import java.io.StringReader
import java.math.BigDecimal

internal fun jsonObject(vararg entries: Pair<String, Any?>): JsonObject =
    JsonObject().apply {
        entries.forEach { (key, value) ->
            add(
                key,
                when (value) {
                    null -> JsonNull.INSTANCE
                    is JsonElement -> value
                    is String -> JsonPrimitive(value)
                    is Number -> JsonPrimitive(value)
                    is Boolean -> JsonPrimitive(value)
                    else -> error("协议内部值类型不受支持")
                },
            )
        }
    }

/** Gson strict reader 前置检测重复键，避免对象解析时悄悄覆盖字段。 */
internal object BridgeCodec {
    const val MAX_BYTES = 256 * 1024
    private val gson = GsonBuilder().disableHtmlEscaping().create()
    private val reserved = setOf("__proto__", "prototype", "constructor")
    private val name = Regex("^[A-Za-z][A-Za-z0-9_]*$")
    private val id = Regex("^[A-Za-z0-9_-]+:[A-Za-z0-9_-]+$")
    private val safeInteger = BigDecimal("9007199254740991")

    fun size(text: String) = text.toByteArray(Charsets.UTF_8).size

    fun prefix(value: String): String? =
        value.takeIf { size(it) <= 256 && id.matches(it) }?.substringBefore(':')

    fun validName(value: String): Boolean = name.matches(value) && value !in reserved

    fun validMethod(value: String): Boolean =
        size(value) <= 256 && value.split('.').let { it.size in 1..2 && it.all(::validName) }

    fun decode(text: String): JsonObject {
        if (size(text) > MAX_BYTES) throw BridgeFailure("PROTOCOL_ERROR", "消息超出字节上限")
        try {
            JsonReader(StringReader(text)).use { reader ->
                reader.strictness = Strictness.STRICT
                scan(reader, 0)
                if (reader.peek() != JsonToken.END_DOCUMENT) error("多余 JSON 内容")
            }
            val value = JsonParser.parseString(text)
            if (!value.isJsonObject) error("请求必须为对象")
            return value.asJsonObject
        } catch (error: Exception) {
            throw BridgeFailure("PROTOCOL_ERROR", "无效 JSON 消息")
        }
    }

    private fun scan(reader: JsonReader, depth: Int) {
        require(depth <= 64) { "JSON 嵌套过深" }
        when (reader.peek()) {
            JsonToken.BEGIN_OBJECT -> {
                reader.beginObject()
                val seen = HashSet<String>()
                while (reader.hasNext()) {
                    val key = reader.nextName()
                    require(unicode(key) && key !in reserved && seen.add(key)) { "非法或重复字段" }
                    scan(reader, depth + 1)
                }
                reader.endObject()
            }
            JsonToken.BEGIN_ARRAY -> {
                reader.beginArray()
                while (reader.hasNext()) scan(reader, depth + 1)
                reader.endArray()
            }
            JsonToken.STRING -> require(unicode(reader.nextString())) { "非法 Unicode" }
            JsonToken.NUMBER -> {
                val number = BigDecimal(reader.nextString())
                require(number.toDouble().isFinite()) { "非有限数字" }
                require(number.stripTrailingZeros().scale() > 0 || number.abs() <= safeInteger) {
                    "非安全整数"
                }
            }
            JsonToken.BOOLEAN -> reader.nextBoolean()
            JsonToken.NULL -> reader.nextNull()
            else -> error("非法 JSON 标记")
        }
    }

    private fun unicode(value: String): Boolean {
        var i = 0
        while (i < value.length) {
            val c = value[i++]
            if (c.isHighSurrogate()) {
                if (i == value.length || !value[i++].isLowSurrogate()) return false
            } else if (c.isLowSurrogate()) return false
        }
        return true
    }

    fun validatePayload(value: JsonElement, depth: Int = 0, maxDepth: Int = 32) {
        require(depth <= maxDepth) { "业务 JSON 嵌套过深" }
        when {
            value.isJsonObject ->
                value.asJsonObject.entrySet().forEach { (key, item) ->
                    require(key !in reserved && unicode(key))
                    validatePayload(item, depth + 1, maxDepth)
                }
            value.isJsonArray ->
                value.asJsonArray.forEach { validatePayload(it, depth + 1, maxDepth) }
            value.isJsonPrimitive -> {
                val p = value.asJsonPrimitive
                if (p.isString) require(unicode(p.asString))
                if (p.isNumber) {
                    val number = p.asBigDecimal
                    require(number.toDouble().isFinite())
                    require(number.stripTrailingZeros().scale() > 0 || number.abs() <= safeInteger)
                }
            }
        }
    }

    fun encode(value: JsonObject): String {
        // 业务数据先独立检查 32 层；协议封套使用独立的 64 层边界。
        validatePayload(value, maxDepth = 64)
        return gson.toJson(value).also {
            if (size(it) > MAX_BYTES) throw BridgeFailure("PAYLOAD_TOO_LARGE", "回包超出字节上限")
        }
    }

    fun validateRequest(message: JsonObject) {
        if (
            !setOf("method", "callbackId", "params", "timeoutMs", "extra")
                .containsAll(message.keySet())
        )
            throw BridgeFailure("INVALID_ARGUMENT", "未知请求字段")
        val method = string(message, "method")
        if (method == null || !validMethod(method)) throw BridgeFailure("INVALID_METHOD", "无效方法名")
        val params = message.get("params")
        if (params == null || !params.isJsonObject)
            throw BridgeFailure("INVALID_ARGUMENT", "params 必须为对象")
        try {
            validatePayload(params)
        } catch (e: Exception) {
            throw BridgeFailure("INVALID_ARGUMENT", "无效业务参数")
        }
        message.get("timeoutMs")?.let {
            if (
                !it.isJsonPrimitive ||
                    !it.asJsonPrimitive.isNumber ||
                    runCatching { it.asBigDecimal.toBigIntegerExact().toLong() }
                        .getOrNull()
                        ?.let { n -> n in 1..600000 } != true
            )
                throw BridgeFailure("INVALID_ARGUMENT", "无效 timeoutMs")
        }
        if (message.has("extra")) {
            val extra =
                string(message, "extra") ?: throw BridgeFailure("INVALID_ARGUMENT", "extra 必须为字符串")
            if (!extraFits(extra)) throw BridgeFailure("PAYLOAD_TOO_LARGE", "extra 没有留下回包空间")
        }
    }

    fun string(objectValue: JsonObject, key: String): String? =
        objectValue.get(key)?.let {
            if (it.isJsonPrimitive && it.asJsonPrimitive.isString) it.asString else null
        }

    fun extraFits(extra: String): Boolean =
        size(gson.toJson(jsonObject("extra" to extra))) <= 255 * 1024

    fun response(
        id: String,
        sequence: Long,
        finished: Boolean,
        data: JsonObject?,
        failure: BridgeFailure?,
        extra: String?,
    ): BridgePreparedResponse {
        val base = jsonObject("callbackId" to id, "seq" to sequence, "finished" to finished)
        if (extra != null && extraFits(extra)) base.addProperty("extra", extra)
        if (failure != null)
            base.add("error", jsonObject("code" to failure.code, "message" to failure.message))
        else base.add("result", data ?: JsonObject())
        return try {
            if (data != null) validatePayload(data)
            BridgePreparedResponse(encode(base), finished, callbackId = id)
        } catch (e: Exception) {
            base.remove("result")
            base.addProperty("finished", true)
            base.add("error", jsonObject("code" to "PAYLOAD_TOO_LARGE", "message" to "无法编码业务回包"))
            BridgePreparedResponse(encode(base), true, requiresCleanup = true, callbackId = id)
        }
    }
}

// callbackId仅为Native诊断元数据；不再次解析已编码JSON，也不新增wire字段。
internal data class BridgePreparedResponse(
    val text: String,
    val finished: Boolean,
    val requiresCleanup: Boolean = false,
    val callbackId: String? = null,
)
