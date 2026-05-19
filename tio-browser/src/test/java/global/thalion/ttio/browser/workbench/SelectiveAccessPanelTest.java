/*
 * TTI-O tio-browser
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.browser.workbench;

import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.*;

/**
 * Pure-unit tests for {@link SelectiveAccessPanel}'s static
 * parsers. The form behaviour itself is exercised indirectly by
 * the dialog smoke tests (the SDK-level
 * {@code SelectiveAccessFilter} already pins the value semantics).
 */
class SelectiveAccessPanelTest {

    // ---- parseInt ----

    @Test
    void parseIntAcceptsPositive() {
        assertEquals(2, SelectiveAccessPanel.parseInt("2"));
        assertEquals(50, SelectiveAccessPanel.parseInt("  50  "));
    }

    @Test
    void parseIntRejectsBlankOrNull() {
        assertNull(SelectiveAccessPanel.parseInt(null));
        assertNull(SelectiveAccessPanel.parseInt(""));
        assertNull(SelectiveAccessPanel.parseInt("   "));
    }

    @Test
    void parseIntRejectsNonNumeric() {
        assertNull(SelectiveAccessPanel.parseInt("abc"));
        assertNull(SelectiveAccessPanel.parseInt("2x"));
    }

    @Test
    void parseIntRejectsZeroAndNegative() {
        assertNull(SelectiveAccessPanel.parseInt("0"));
        assertNull(SelectiveAccessPanel.parseInt("-1"));
    }

    // ---- parseDouble ----

    @Test
    void parseDoubleAcceptsNonNegative() {
        assertEquals(0.0, SelectiveAccessPanel.parseDouble("0"));
        assertEquals(12.5, SelectiveAccessPanel.parseDouble("12.5"));
        assertEquals(25.0, SelectiveAccessPanel.parseDouble("  25.0  "));
    }

    @Test
    void parseDoubleRejectsBlankOrNull() {
        assertNull(SelectiveAccessPanel.parseDouble(null));
        assertNull(SelectiveAccessPanel.parseDouble(""));
    }

    @Test
    void parseDoubleRejectsNonNumeric() {
        assertNull(SelectiveAccessPanel.parseDouble("not-a-num"));
    }

    @Test
    void parseDoubleRejectsNegative() {
        assertNull(SelectiveAccessPanel.parseDouble("-0.5"));
        assertNull(SelectiveAccessPanel.parseDouble("-100"));
    }
}
