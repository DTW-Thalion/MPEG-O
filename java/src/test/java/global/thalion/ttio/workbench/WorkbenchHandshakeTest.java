/*
 * TTI-O Java Implementation
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.workbench;

import global.thalion.ttio.workbench.transport.WorkbenchHandshake;
import global.thalion.ttio.workbench.transport.WorkbenchHandshake.OutputMode;
import global.thalion.ttio.workbench.transport.WorkbenchHandshake.ServerFrame;
import global.thalion.ttio.workbench.transport.WorkbenchHandshake.ServerFrameKind;

import org.junit.jupiter.api.Test;

import java.util.LinkedHashMap;
import java.util.Map;

import static org.junit.jupiter.api.Assertions.*;

/**
 * Pure-data tests for the Java workbench handshake builders +
 * parser. Mirrors {@code python/tests/workbench/test_handshake.py};
 * the two suites must accept the same inputs and produce
 * structurally-equivalent JSON.
 */
class WorkbenchHandshakeTest {

    @Test
    void subprotocolMatchesServer() {
        assertEquals("ttio-transport", WorkbenchHandshake.WS_SUBPROTOCOL);
    }

    @Test
    void uploadHandshakeMinimal() {
        String json = WorkbenchHandshake.buildUploadHandshake(
            "alice", "alpha", "uri:tio:demo-001", null, null);
        assertEquals(
            "{\"type\":\"handshake\","
            + "\"owner\":\"alice\","
            + "\"project\":\"alpha\","
            + "\"container_uri\":\"uri:tio:demo-001\"}",
            json);
    }

    @Test
    void uploadHandshakeWithToken() {
        String json = WorkbenchHandshake.buildUploadHandshake(
            "alice", "alpha", "uri:tio:demo-001", "ttiowbs_abc", null);
        assertTrue(json.contains("\"token\":\"ttiowbs_abc\""));
    }

    @Test
    void uploadHandshakeWithResume() {
        String json = WorkbenchHandshake.buildUploadHandshake(
            "alice", "alpha", "uri:tio:demo-001",
            "ttiowbs_abc", "stg-deadbeef");
        assertTrue(json.contains("\"resume_handle\":\"stg-deadbeef\""));
    }

    @Test
    void uploadHandshakeRejectsMissingOwner() {
        assertThrows(IllegalArgumentException.class,
            () -> WorkbenchHandshake.buildUploadHandshake(
                "", "alpha", "uri:tio:demo-001", null, null));
    }

    @Test
    void uploadHandshakeRejectsMissingProject() {
        assertThrows(IllegalArgumentException.class,
            () -> WorkbenchHandshake.buildUploadHandshake(
                "alice", "", "uri:tio:demo-001", null, null));
    }

    @Test
    void uploadHandshakeRejectsMissingUri() {
        assertThrows(IllegalArgumentException.class,
            () -> WorkbenchHandshake.buildUploadHandshake(
                "alice", "alpha", "", null, null));
    }

    @Test
    void downloadHandshakeMinimal() {
        String json = WorkbenchHandshake.buildDownloadHandshake(
            "uri:tio:demo-001", null, null, null, null, 0);
        assertEquals(
            "{\"type\":\"handshake\","
            + "\"mode\":\"download\","
            + "\"container_uri\":\"uri:tio:demo-001\","
            + "\"output_mode\":\"binary\"}",
            json);
    }

    @Test
    void downloadHandshakeWithFilter() {
        Map<String, Object> filter = new LinkedHashMap<>();
        filter.put("ms_level", 1);
        filter.put("retention_time_min", 12.5);
        String json = WorkbenchHandshake.buildDownloadHandshake(
            "uri:tio:demo-001", null, null, OutputMode.BINARY, filter, 0);
        assertTrue(json.contains("\"filter\":{"));
        assertTrue(json.contains("\"ms_level\":1"));
        assertTrue(json.contains("\"retention_time_min\":12.5"));
    }

    @Test
    void downloadHandshakeRejectsUnknownFilterKey() {
        Map<String, Object> filter = new LinkedHashMap<>();
        filter.put("not_a_real_key", 1);
        assertThrows(IllegalArgumentException.class,
            () -> WorkbenchHandshake.buildDownloadHandshake(
                "uri:tio:demo-001", null, null, null, filter, 0));
    }

    @Test
    void downloadHandshakeRejectsNegativeMaxAu() {
        assertThrows(IllegalArgumentException.class,
            () -> WorkbenchHandshake.buildDownloadHandshake(
                "uri:tio:demo-001", null, null, null, null, -1));
    }

    @Test
    void downloadHandshakeOmitsMaxAuWhenZero() {
        String json = WorkbenchHandshake.buildDownloadHandshake(
            "uri:tio:demo-001", null, null, null, null, 0);
        assertFalse(json.contains("max_au"));
    }

    @Test
    void downloadHandshakeIncludesMaxAuWhenPositive() {
        String json = WorkbenchHandshake.buildDownloadHandshake(
            "uri:tio:demo-001", null, null, null, null, 100);
        assertTrue(json.contains("\"max_au\":100"));
    }

    @Test
    void allowedFilterKeysMatchServer() {
        // Pinning the set catches drift if a server change removes
        // a supported predicate without updating the client.
        assertEquals(
            java.util.Set.of(
                "ms_level", "polarity",
                "retention_time_min", "retention_time_max",
                "precursor_mz_min", "precursor_mz_max",
                "precursor_charge", "max_au"),
            WorkbenchHandshake.ALLOWED_DOWNLOAD_FILTER_KEYS);
    }

    @Test
    void parseAckFrame() {
        ServerFrame frame = WorkbenchHandshake.parseServerFrame(
            "{\"type\":\"ack\",\"au_sequence\":12}");
        assertEquals(ServerFrameKind.ACK, frame.kind());
        assertEquals(12L, frame.body().get("au_sequence"));
    }

    @Test
    void parseDoneFrame() {
        ServerFrame frame = WorkbenchHandshake.parseServerFrame(
            "{\"type\":\"done\",\"container_uri\":\"uri:tio:demo-001\"}");
        assertEquals(ServerFrameKind.DONE, frame.kind());
        assertEquals("uri:tio:demo-001", frame.body().get("container_uri"));
    }

    @Test
    void parseErrorFrame() {
        ServerFrame frame = WorkbenchHandshake.parseServerFrame(
            "{\"type\":\"error\",\"message\":\"bad handshake\"}");
        assertEquals(ServerFrameKind.ERROR, frame.kind());
        assertEquals("bad handshake", frame.body().get("message"));
    }

    @Test
    void parseUnknownTypeRaises() {
        assertThrows(IllegalArgumentException.class,
            () -> WorkbenchHandshake.parseServerFrame("{\"type\":\"weird\"}"));
    }

    @Test
    void outputModeWireValues() {
        assertEquals("binary", OutputMode.BINARY.wire());
        assertEquals("stats-only", OutputMode.STATS_ONLY.wire());
        assertEquals("stats-with-payload", OutputMode.STATS_WITH_PAYLOAD.wire());
    }
}
