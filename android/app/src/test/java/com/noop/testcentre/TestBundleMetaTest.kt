package com.noop.testcentre

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** Twin of the Swift TestBundleMetaTests: same fields, same snake_case wire keys, sorted ordering. */
class TestBundleMetaTest {

    private fun sample() = TestBundleMeta(
        schema = 1,
        appVersion = "7.3.0",
        platform = "Android",
        osVersion = "14",
        strapModel = "WHOOP 5.0",
        source = listOf("Live Bluetooth"),
        testProfile = "sleep",
        profileStartedAt = "2026-06-26T07:12:00Z",
        questionnaire = mapOf("naps" to "no"),
        build = TestBundleMeta.Build(channel = "GitHub", signed = true),
        storage = TestBundleMeta.Storage(dbBytes = 1024, rows = mapOf("sleep_sessions" to 12), rawCaptureBytes = 2048),
        redaction = "v2",
        truncated = false)

    @Test fun encodesSnakeCaseWireKeys() {
        val json = sample().encoded()
        assertTrue(json.contains("\"app_version\""))
        assertTrue(json.contains("\"os_version\""))
        assertTrue(json.contains("\"strap_model\""))
        assertTrue(json.contains("\"test_profile\""))
        assertTrue(json.contains("\"profile_started_at\""))
    }

    @Test fun encodesBuildAndStorageBlocks() {
        val json = sample().encoded()
        assertTrue(json.contains("\"channel\""))
        assertTrue(json.contains("\"db_bytes\""))
        assertTrue(json.contains("\"raw_capture_bytes\""))
    }

    @Test fun redactionAndSchemaStamps() {
        val m = sample()
        assertEquals(1, m.schema)
        assertEquals("v2", m.redaction)
        assertEquals(false, m.truncated)
    }

    @Test fun keysAreSortedForParity() {
        val json = sample().encoded()
        assertTrue(json.indexOf("\"app_version\"") < json.indexOf("\"platform\""))
        assertTrue(json.indexOf("\"build\"") < json.indexOf("\"storage\""))
    }
}
