package org.levarac.beid.lab

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonPrimitive
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import java.util.concurrent.TimeUnit

/** Identity required for every Lab connection; no defaults are accepted. */
data class LabControlIdentity(
    val runId: String,
    val role: String,
    val deviceId: String,
    val generation: Int,
    val token: String,
    val protocolVersion: Int,
) {
    init {
        require(runId.isNotBlank()) { "run_id is required" }
        require(role.isNotBlank()) { "role is required" }
        require(deviceId.isNotBlank()) { "device_id is required" }
        require(generation >= 1) { "generation is required" }
        require(token.isNotBlank()) { "token is required" }
        require(protocolVersion == 1) { "unsupported protocol_version" }
    }
}

data class LabHello(val identity: LabControlIdentity) {
    fun wire(): JsonObject = buildJsonObject {
        put("type", JsonPrimitive("hello"))
        put("protocol_version", JsonPrimitive(identity.protocolVersion))
        put("run_id", JsonPrimitive(identity.runId))
        put("role", JsonPrimitive(identity.role))
        put("device_id", JsonPrimitive(identity.deviceId))
        put("generation", JsonPrimitive(identity.generation))
        put("token", JsonPrimitive(identity.token))
    }
}

data class LabSnapshot(
    val requestId: String,
    val runId: String,
    val role: String,
    val deviceId: String,
    val generation: Int,
    val productionState: String,
    val nearbyCandidates: List<String>,
)

interface LabWebSocketClient {
    fun connect(url: String, hello: LabHello, productionState: () -> String,
        nearbyCandidates: () -> List<String>, joinNearbyEvent: (String, (Boolean, String?) -> Unit) -> Unit,
        onSnapshot: (LabSnapshot) -> Unit)
    fun stop()
}

/** Minimal host client. It only answers the broker's snapshot request. */
class OkHttpLabWebSocketClient(
    private val client: OkHttpClient = OkHttpClient.Builder().readTimeout(0, TimeUnit.MILLISECONDS).build(),
) : LabWebSocketClient {
    private var socket: WebSocket? = null

    override fun stop() {
        socket?.close(1000, "lab activity stopped")
        socket = null
    }

    override fun connect(url: String, hello: LabHello, productionState: () -> String,
        nearbyCandidates: () -> List<String>, joinNearbyEvent: (String, (Boolean, String?) -> Unit) -> Unit,
        onSnapshot: (LabSnapshot) -> Unit) {
        require(url.startsWith("ws://") || url.startsWith("wss://")) { "broker_url must be a WebSocket URL" }
        val request = Request.Builder().url(url).build()
        socket = client.newWebSocket(request, object : WebSocketListener() {
            override fun onOpen(webSocket: WebSocket, response: Response) {
                webSocket.send(Json.encodeToString(JsonObject.serializer(), hello.wire()))
            }

            override fun onMessage(webSocket: WebSocket, text: String) {
                runCatching {
                    val value = Json.parseToJsonElement(text).jsonObject
                    if (value["type"]?.jsonPrimitive?.content == "join_nearby_event") {
                        require(value.keys == setOf("type", "request_id", "run_id", "role", "device_id", "generation", "event_code_hash_hex")) { "invalid join_nearby_event fields" }
                        require(value["run_id"]?.jsonPrimitive?.content == hello.identity.runId)
                        require(value["role"]?.jsonPrimitive?.content == hello.identity.role)
                        require(value["device_id"]?.jsonPrimitive?.content == hello.identity.deviceId)
                        require(value["generation"]?.jsonPrimitive?.intOrNull == hello.identity.generation)
                        val requestId = value["request_id"]!!.jsonPrimitive.content
                        val hash = value["event_code_hash_hex"]!!.jsonPrimitive.content
                        if (seenJoinRequestIds.contains(requestId)) {
                            webSocket.send(Json.encodeToString(JsonObject.serializer(), joinResult(requestId, false, "duplicate_request", productionState(), hello)))
                            return@runCatching
                        }
                        seenJoinRequestIds.add(requestId)
                        if (!nearbyCandidates().contains(hash)) {
                            webSocket.send(Json.encodeToString(JsonObject.serializer(), joinResult(requestId, false, "candidate_not_currently_verified", productionState(), hello)))
                            return@runCatching
                        }
                        joinNearbyEvent(hash) { accepted, reason ->
                          val result = buildJsonObject {
                            put("type", JsonPrimitive("join_nearby_event_result"))
                            put("request_id", JsonPrimitive(requestId))
                            put("run_id", JsonPrimitive(hello.identity.runId))
                            put("role", JsonPrimitive(hello.identity.role))
                            put("device_id", JsonPrimitive(hello.identity.deviceId))
                            put("generation", JsonPrimitive(hello.identity.generation))
                            put("status", JsonPrimitive(if (accepted) "accepted" else "rejected"))
                            if (reason == null) put("reason", kotlinx.serialization.json.JsonNull)
                            else put("reason", JsonPrimitive(reason))
                            put("production_state", JsonPrimitive(productionState()))
                          }
                          webSocket.send(Json.encodeToString(JsonObject.serializer(), result))
                        }
                        return@runCatching
                    }
                    require(value.keys == setOf("type", "request_id", "run_id", "role", "generation")) { "invalid snapshot_request fields" }
                    require(value["type"]?.jsonPrimitive?.content == "snapshot_request") { "unexpected broker message" }
                    require(value["run_id"]?.jsonPrimitive?.content == hello.identity.runId)
                    require(value["role"]?.jsonPrimitive?.content == hello.identity.role)
                    require(value["generation"]?.jsonPrimitive?.intOrNull == hello.identity.generation)
                    val requestId = value["request_id"]!!.jsonPrimitive.content
                    val snapshot = buildJsonObject {
                        put("type", JsonPrimitive("snapshot_response"))
                        put("request_id", JsonPrimitive(requestId))
                        put("run_id", JsonPrimitive(hello.identity.runId))
                        put("role", JsonPrimitive(hello.identity.role))
                        put("device_id", JsonPrimitive(hello.identity.deviceId))
                        put("generation", JsonPrimitive(hello.identity.generation))
                        put("production_state", JsonPrimitive(productionState()))
                        put("nearby_candidates", kotlinx.serialization.json.buildJsonArray {
                            nearbyCandidates().forEach { add(JsonPrimitive(it)) }
                        })
                    }
                    webSocket.send(Json.encodeToString(JsonObject.serializer(), snapshot))
                    onSnapshot(LabSnapshot(requestId, hello.identity.runId, hello.identity.role, hello.identity.deviceId, hello.identity.generation, productionState(), nearbyCandidates()))
                }
            }
        })
    }

    private val seenJoinRequestIds = mutableSetOf<String>()

    private fun joinResult(requestId: String, accepted: Boolean, reason: String, state: String, hello: LabHello) = buildJsonObject {
        put("type", JsonPrimitive("join_nearby_event_result")); put("request_id", JsonPrimitive(requestId))
        put("run_id", JsonPrimitive(hello.identity.runId)); put("role", JsonPrimitive(hello.identity.role))
        put("device_id", JsonPrimitive(hello.identity.deviceId)); put("generation", JsonPrimitive(hello.identity.generation))
        put("status", JsonPrimitive(if (accepted) "accepted" else "rejected")); put("reason", JsonPrimitive(reason)); put("production_state", JsonPrimitive(state))
    }
}

/** Lab-only bootstrap. Missing URL/identity fails closed before production BLE starts. */
class LabControlBootstrap(
    private val identity: LabControlIdentity,
    private val brokerUrl: String,
    private val broker: LabWebSocketClient,
    private val productionState: () -> String,
    private val nearbyCandidates: () -> List<String>,
    private val joinNearbyEvent: (String, (Boolean, String?) -> Unit) -> Unit,
) {
    fun start(onSnapshot: (LabSnapshot) -> Unit = {}): Result<Unit> {
        if (brokerUrl.isBlank()) return Result.failure(IllegalStateException("lab broker is not configured"))
        broker.connect(brokerUrl, LabHello(identity), productionState, nearbyCandidates, joinNearbyEvent, onSnapshot)
        return Result.success(Unit)
    }

    fun stop() = broker.stop()
}
