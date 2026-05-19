/*
 * TTI-O tio-browser
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.browser.workbench;

import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.*;

/**
 * Unit tests for {@link LoginDialog}'s static validators. Mirror
 * of {@code transport/DownloadDialogTest}: validators are pure
 * static methods, so no FX toolkit is required.
 */
class LoginDialogTest {

    @Test
    void urlAcceptsWsWssHttpHttps() {
        assertTrue(LoginDialog.isValidUrl("ws://localhost:8443"));
        assertTrue(LoginDialog.isValidUrl("wss://biobank.example.com:8443/transport"));
        assertTrue(LoginDialog.isValidUrl("http://localhost:8080"));
        assertTrue(LoginDialog.isValidUrl("https://biobank.example.com"));
    }

    @Test
    void urlAcceptsBareHostPort() {
        assertTrue(LoginDialog.isValidUrl("localhost:8443"));
        assertTrue(LoginDialog.isValidUrl("biobank.example.com"));
    }

    @Test
    void urlRejectsEmptyOrNull() {
        assertFalse(LoginDialog.isValidUrl(null));
        assertFalse(LoginDialog.isValidUrl(""));
    }

    @Test
    void urlRejectsLeadingColon() {
        assertFalse(LoginDialog.isValidUrl(":8443"));
    }

    @Test
    void urlRejectsSpaces() {
        assertFalse(LoginDialog.isValidUrl("not a url"));
    }

    @Test
    void totpRequiresExactlySixDigits() {
        assertTrue(LoginDialog.isValidTotp("000000"));
        assertTrue(LoginDialog.isValidTotp("123456"));
        assertTrue(LoginDialog.isValidTotp("999999"));
    }

    @Test
    void totpRejectsWrongLength() {
        assertFalse(LoginDialog.isValidTotp(null));
        assertFalse(LoginDialog.isValidTotp(""));
        assertFalse(LoginDialog.isValidTotp("12345"));
        assertFalse(LoginDialog.isValidTotp("1234567"));
    }

    @Test
    void totpRejectsNonDigits() {
        assertFalse(LoginDialog.isValidTotp("12345a"));
        assertFalse(LoginDialog.isValidTotp("12 456"));
        assertFalse(LoginDialog.isValidTotp("abcdef"));
        assertFalse(LoginDialog.isValidTotp("-12345"));
    }

    @Test
    void usernameValidator() {
        assertFalse(LoginDialog.isValidUsername(null));
        assertFalse(LoginDialog.isValidUsername(""));
        assertFalse(LoginDialog.isValidUsername("   "));
        assertTrue(LoginDialog.isValidUsername("alice"));
        assertTrue(LoginDialog.isValidUsername("alice.smith"));
    }

    @Test
    void passwordValidator() {
        // Server-side enforces strength; UI only blocks empty.
        assertFalse(LoginDialog.isValidPassword(null));
        assertFalse(LoginDialog.isValidPassword(""));
        assertTrue(LoginDialog.isValidPassword("x"));
        assertTrue(LoginDialog.isValidPassword("correct horse battery staple"));
    }
}
