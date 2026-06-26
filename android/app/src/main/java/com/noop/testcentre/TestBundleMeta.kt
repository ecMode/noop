package com.noop.testcentre

import org.json.JSONObject

/**
 * Twin of the Swift TestBundleMeta (spec section 5.1): meta.json schema v1, the machine-readable tie
 * between a strap log and the test profile that produced it. Same snake_case wire keys, same build and
 * storage blocks, redaction stamped v2. We emit keys in sorted order by hand so the bytes line up with
 * the Swift JSONEncoder sortedKeys output, which the parity test asserts.
 */
data class TestBundleMeta(
    val schema: Int,
    val appVersion: String,
    val platform: String,
    val osVersion: String,
    val strapModel: String?,
    val source: List<String>,
    val testProfile: String,
    val profileStartedAt: String?,
    val questionnaire: Map<String, String>,
    val build: Build,
    val storage: Storage,
    val redaction: String,
    val truncated: Boolean,
) {
    data class Build(val channel: String, val signed: Boolean)
    data class Storage(val dbBytes: Int, val rows: Map<String, Int>, val rawCaptureBytes: Int)

    /** Pretty, sorted JSON matching the Swift encoder. JSONObject sorts nothing for us, so we build the
     *  map then emit sorted entries. */
    fun encoded(): String {
        fun sortedObject(pairs: Map<String, Any?>): JSONObject {
            val o = JSONObject()
            for (k in pairs.keys.sorted()) o.put(k, pairs[k])
            return o
        }
        val buildObj = sortedObject(mapOf("channel" to build.channel, "signed" to build.signed))
        val storageObj = sortedObject(mapOf(
            "db_bytes" to storage.dbBytes,
            "raw_capture_bytes" to storage.rawCaptureBytes,
            "rows" to sortedObject(storage.rows)))
        val questObj = sortedObject(questionnaire)
        val root = sortedObject(mapOf(
            "app_version" to appVersion,
            "build" to buildObj,
            "os_version" to osVersion,
            "platform" to platform,
            "profile_started_at" to (profileStartedAt ?: JSONObject.NULL),
            "questionnaire" to questObj,
            "redaction" to redaction,
            "schema" to schema,
            "source" to org.json.JSONArray(source),
            "storage" to storageObj,
            "strap_model" to (strapModel ?: JSONObject.NULL),
            "test_profile" to testProfile,
            "truncated" to truncated))
        return root.toString(2)
    }
}
