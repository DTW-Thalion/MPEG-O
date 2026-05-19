/*
 * TTI-O tio-browser
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.browser.workbench;

import org.junit.jupiter.api.Test;

import java.util.Map;

import static org.junit.jupiter.api.Assertions.*;

class TransferTest {

    @Test
    void transferIdIsUniquePerInstance() {
        Transfer a = new Transfer(TransferKind.UPLOAD,
            "uri:tio:a", "/path/a.tio", 1024L, Map.of());
        Transfer b = new Transfer(TransferKind.UPLOAD,
            "uri:tio:a", "/path/a.tio", 1024L, Map.of());
        assertNotEquals(a.id(), b.id());
    }

    @Test
    void initialStateIsPending() {
        Transfer t = new Transfer(TransferKind.DOWNLOAD,
            "uri:tio:x", "/dl.tio", 0L, Map.of());
        assertSame(TransferState.PENDING, t.state());
        assertEquals(0L, t.bytesTransferred());
        assertEquals("", t.message());
    }

    @Test
    void filterDefaultsToEmptyMap() {
        Transfer t = new Transfer(TransferKind.DOWNLOAD,
            "uri:tio:x", "/dl.tio", 0L, null);
        assertTrue(t.filter().isEmpty());
    }

    @Test
    void filterIsDefensivelyCopied() {
        Map<String, Object> source = new java.util.HashMap<>();
        source.put("ms_level", 2);
        Transfer t = new Transfer(TransferKind.DOWNLOAD,
            "uri:tio:x", "/dl.tio", 0L, source);
        // Mutating the source after construction must not affect
        // the transfer's filter view (immutable copy).
        source.put("polarity", "positive");
        assertEquals(1, t.filter().size());
        assertTrue(t.filter().containsKey("ms_level"));
        assertFalse(t.filter().containsKey("polarity"));
    }

    @Test
    void kindLabelMatchesKind() {
        Transfer up = new Transfer(TransferKind.UPLOAD,
            "uri:tio:x", "/up.tio", 0L, Map.of());
        Transfer dn = new Transfer(TransferKind.DOWNLOAD,
            "uri:tio:x", "/dn.tio", 0L, Map.of());
        assertEquals("Upload", up.kindLabel());
        assertEquals("Download", dn.kindLabel());
    }
}
