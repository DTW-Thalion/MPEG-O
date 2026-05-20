/*
 * TTI-O tio-browser
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.browser.workbench;

import global.thalion.ttio.workbench.pipeline.Pipeline;
import org.junit.jupiter.api.Test;

import java.util.Map;

import static org.junit.jupiter.api.Assertions.*;

class PipelineLauncherTest {

    // ---- isValidJsonObject ----

    @Test
    void emptyObjectIsValid() {
        assertTrue(PipelineLauncher.isValidJsonObject("{}"));
        assertTrue(PipelineLauncher.isValidJsonObject(" { } "));
    }

    @Test
    void populatedObjectIsValid() {
        assertTrue(PipelineLauncher.isValidJsonObject(
            "{\"raw_reads\": \"uri:tio:demo\"}"));
        assertTrue(PipelineLauncher.isValidJsonObject(
            "{\"threads\": 4, \"verbose\": true}"));
    }

    @Test
    void blankOrNullRejected() {
        assertFalse(PipelineLauncher.isValidJsonObject(null));
        assertFalse(PipelineLauncher.isValidJsonObject(""));
        assertFalse(PipelineLauncher.isValidJsonObject("   "));
    }

    @Test
    void arrayRejected() {
        // Only top-level objects are accepted; the SDK methods take
        // Map<String,Object>, not List.
        assertFalse(PipelineLauncher.isValidJsonObject("[1, 2, 3]"));
    }

    @Test
    void scalarRejected() {
        assertFalse(PipelineLauncher.isValidJsonObject("42"));
        assertFalse(PipelineLauncher.isValidJsonObject("\"alpha\""));
        assertFalse(PipelineLauncher.isValidJsonObject("true"));
    }

    @Test
    void malformedJsonRejected() {
        assertFalse(PipelineLauncher.isValidJsonObject("{not json"));
        assertFalse(PipelineLauncher.isValidJsonObject("{,}"));
    }

    // ---- renderSchemaPreview ----

    @Test
    void renderPreviewIncludesIdentifierAndVersion() {
        Pipeline p = new Pipeline(
            "01HPL", "eqtl-analysis", "1.2.0",
            "alpha", "alice", "shell", "definition-string",
            Map.of("raw_reads", "string"),
            Map.of("eqtls", "string"));
        String text = PipelineLauncher.renderSchemaPreview(p);
        assertTrue(text.contains("eqtl-analysis"), text);
        assertTrue(text.contains("v1.2.0"), text);
        assertTrue(text.contains("alpha"), text);
        assertTrue(text.contains("alice"), text);
        assertTrue(text.contains("shell"), text);
        assertTrue(text.contains("raw_reads"), text);
        assertTrue(text.contains("eqtls"), text);
    }

    @Test
    void renderPreviewHandlesEmptySchemas() {
        Pipeline p = new Pipeline(
            "01HPL", "id", "", "alpha", "alice", null, "",
            Map.of(), Map.of());
        String text = PipelineLauncher.renderSchemaPreview(p);
        assertTrue(text.contains("(none)"), text);
        // Engine-pin section omitted when null/empty.
        assertFalse(text.contains("Engine pin"), text);
    }

    @Test
    void renderPreviewStableForIdenticalInputs() {
        Pipeline p = new Pipeline(
            "01HPL", "id", "1.0", "alpha", "alice", "shell", "",
            Map.of("raw_reads", "string"),
            Map.of("eqtls", "string"));
        assertEquals(
            PipelineLauncher.renderSchemaPreview(p),
            PipelineLauncher.renderSchemaPreview(p));
    }
}
