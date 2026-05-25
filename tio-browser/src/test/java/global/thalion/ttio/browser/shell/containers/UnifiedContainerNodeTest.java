/*
 * TTI-O tio-browser
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.browser.shell.containers;

import org.junit.jupiter.api.Test;
import static org.junit.jupiter.api.Assertions.*;

class UnifiedContainerNodeTest {

    @Test
    void localRootIsAGroup() {
        var n = new UnifiedContainerNode.LocalRoot();
        assertEquals("Local", n.displayName());
        assertEquals(UnifiedContainerNode.Kind.GROUP, n.kind());
    }

    @Test
    void serverContainerCarriesUri() {
        var n = new UnifiedContainerNode.ServerContainer(
            "uri:tio:adni/x", "X-001", 134_217_728L);
        assertEquals("uri:tio:adni/x", n.uri());
        assertEquals(UnifiedContainerNode.Kind.CONTAINER, n.kind());
    }

    @Test
    void actionNodeMarksItselfAsAction() {
        var n = new UnifiedContainerNode.OpenLocalAction();
        assertEquals(UnifiedContainerNode.Kind.ACTION, n.kind());
    }
}
