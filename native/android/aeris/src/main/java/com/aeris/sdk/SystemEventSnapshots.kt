package com.aeris.sdk

import com.google.gson.JsonObject

/** 将平台状态归一为与 iOS 相同的事件数据字段。 */
object SystemEventSnapshots {
    fun network(available: Boolean, validated: Boolean, networkInterface: String, expensive: Boolean, constrained: Boolean): JsonObject {
        val connected = available && validated
        return jsonObject(
            "status" to if (connected) "satisfied" else if (available) "requiresConnection" else "unsatisfied",
            "connected" to connected,
            "interface" to if (connected) networkInterface else "none",
            "expensive" to expensive, "constrained" to constrained,
        )
    }
    fun appearance(dark: Boolean?): JsonObject = jsonObject("style" to when (dark) { true -> "dark"; false -> "light"; null -> "unspecified" })
}
