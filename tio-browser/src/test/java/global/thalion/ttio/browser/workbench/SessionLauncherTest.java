/*
 * TTI-O tio-browser
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.browser.workbench;

import org.junit.jupiter.api.Test;

import java.util.List;
import java.util.Map;

import static org.junit.jupiter.api.Assertions.*;

class SessionLauncherTest {

    // ---- parseCommand ----

    @Test
    void parseCommandSplitsOnWhitespace() {
        assertEquals(List.of("/bin/bash", "-l"),
            SessionLauncher.parseCommand("/bin/bash -l"));
        assertEquals(List.of("python", "-m", "http.server"),
            SessionLauncher.parseCommand("  python   -m  http.server  "));
    }

    @Test
    void parseCommandEmptyOrNullIsEmptyList() {
        assertTrue(SessionLauncher.parseCommand(null).isEmpty());
        assertTrue(SessionLauncher.parseCommand("").isEmpty());
        assertTrue(SessionLauncher.parseCommand("   ").isEmpty());
    }

    // ---- parseBindMounts ----

    @Test
    void parseBindMountsBasic() {
        Map<String, String> m = SessionLauncher.parseBindMounts(
            "/host/a:/container/a\n/host/b:/container/b");
        assertEquals(2, m.size());
        assertEquals("/container/a", m.get("/host/a"));
        assertEquals("/container/b", m.get("/host/b"));
    }

    @Test
    void parseBindMountsDropsModeSuffix() {
        Map<String, String> m = SessionLauncher.parseBindMounts(
            "/host/data:/data:ro");
        assertEquals("/data", m.get("/host/data"));
    }

    @Test
    void parseBindMountsSkipsBlankLines() {
        Map<String, String> m = SessionLauncher.parseBindMounts(
            "/host/a:/container/a\n\n   \n/host/b:/container/b");
        assertEquals(2, m.size());
    }

    @Test
    void parseBindMountsEmptyOrNull() {
        assertTrue(SessionLauncher.parseBindMounts(null).isEmpty());
        assertTrue(SessionLauncher.parseBindMounts("").isEmpty());
    }

    @Test
    void parseBindMountsRejectsNoColon() {
        assertThrows(IllegalArgumentException.class, () ->
            SessionLauncher.parseBindMounts("/host/no-container"));
    }

    @Test
    void parseBindMountsRejectsTrailingColon() {
        assertThrows(IllegalArgumentException.class, () ->
            SessionLauncher.parseBindMounts("/host/a:"));
    }

    @Test
    void parseBindMountsRejectsLeadingColon() {
        assertThrows(IllegalArgumentException.class, () ->
            SessionLauncher.parseBindMounts(":/container/a"));
    }

    // ---- parseEnv ----

    @Test
    void parseEnvBasic() {
        Map<String, String> e = SessionLauncher.parseEnv(
            "FOO=bar\nBAZ=qux");
        assertEquals("bar", e.get("FOO"));
        assertEquals("qux", e.get("BAZ"));
    }

    @Test
    void parseEnvValueWithEquals() {
        Map<String, String> e = SessionLauncher.parseEnv("URL=http://x?a=b");
        assertEquals("http://x?a=b", e.get("URL"));
    }

    @Test
    void parseEnvSkipsBlankLines() {
        Map<String, String> e = SessionLauncher.parseEnv("FOO=bar\n\n  \nBAZ=qux");
        assertEquals(2, e.size());
    }

    @Test
    void parseEnvRejectsNoEquals() {
        assertThrows(IllegalArgumentException.class, () ->
            SessionLauncher.parseEnv("NOVALUE"));
    }

    @Test
    void parseEnvRejectsLeadingEquals() {
        assertThrows(IllegalArgumentException.class, () ->
            SessionLauncher.parseEnv("=value"));
    }

    // ---- isValidProject ----

    @Test
    void projectValidator() {
        assertFalse(SessionLauncher.isValidProject(null));
        assertFalse(SessionLauncher.isValidProject(""));
        assertFalse(SessionLauncher.isValidProject("  "));
        assertTrue(SessionLauncher.isValidProject("alpha"));
    }
}
