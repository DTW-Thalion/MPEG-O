/*
 * TTI-O Java Implementation
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.workbench;

import global.thalion.ttio.workbench.transport.WorkbenchTransportException;

import org.junit.jupiter.api.Test;

import java.util.OptionalInt;

import static org.junit.jupiter.api.Assertions.*;

/**
 * Direct construction tests for the workbench transport exception
 * hierarchy. Production wiring throws these from
 * {@code WorkbenchTransportClient}, which is excluded from
 * coverage; these tests cover the constructor branches.
 */
class TransportExceptionTest {

    @Test
    void baseMessageOnly() {
        WorkbenchTransportException e = new WorkbenchTransportException("oops");
        assertEquals("oops", e.getMessage());
        assertTrue(e.closeCode().isEmpty());
        assertNull(e.reason());
    }

    @Test
    void baseMessageWithCause() {
        Throwable cause = new RuntimeException("inner");
        WorkbenchTransportException e = new WorkbenchTransportException("outer", cause);
        assertSame(cause, e.getCause());
    }

    @Test
    void baseWithCloseCode() {
        WorkbenchTransportException e = new WorkbenchTransportException(
            "close", OptionalInt.of(1002), "bad handshake");
        assertEquals(1002, e.closeCode().getAsInt());
        assertEquals("bad handshake", e.reason());
    }

    @Test
    void baseWithCloseCodeAndCause() {
        Throwable cause = new RuntimeException("inner");
        WorkbenchTransportException e = new WorkbenchTransportException(
            "close", cause, OptionalInt.of(1011), "server error");
        assertSame(cause, e.getCause());
        assertEquals(1011, e.closeCode().getAsInt());
    }

    @Test
    void handshakeFlavor() {
        WorkbenchTransportException.Handshake e =
            new WorkbenchTransportException.Handshake("bad handshake");
        assertEquals("bad handshake", e.getMessage());
        assertInstanceOf(WorkbenchTransportException.class, e);
    }

    @Test
    void handshakeWithCause() {
        Throwable cause = new RuntimeException("inner");
        WorkbenchTransportException.Handshake e =
            new WorkbenchTransportException.Handshake("bad", cause);
        assertSame(cause, e.getCause());
    }

    @Test
    void handshakeWithCloseCode() {
        WorkbenchTransportException.Handshake e =
            new WorkbenchTransportException.Handshake(
                "bad", OptionalInt.of(1002), "auth required");
        assertEquals(1002, e.closeCode().getAsInt());
        assertEquals("auth required", e.reason());
    }

    @Test
    void uploadFlavorCarriesResumeMetadata() {
        WorkbenchTransportException.Upload e =
            new WorkbenchTransportException.Upload(
                "mid-stream fail",
                OptionalInt.of(1011), "server died",
                42L, "stg-abc");
        assertEquals(42L, e.lastAckedAuSequence());
        assertEquals("stg-abc", e.resumeHandle());
        assertEquals(1011, e.closeCode().getAsInt());
    }

    @Test
    void downloadFlavorCarriesCloseInfo() {
        WorkbenchTransportException.Download e =
            new WorkbenchTransportException.Download(
                "no container",
                OptionalInt.of(1011), "container not found");
        assertEquals("container not found", e.reason());
        assertEquals(1011, e.closeCode().getAsInt());
    }
}
