package global.thalion.ttio.browser.util;

import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.*;

class CigarParserTest {

    @Test
    void parsesSimpleCigar() {
        var ops = CigarParser.parse("10M2I5M");
        assertEquals(3, ops.size());
        assertEquals(10, ops.get(0).length());
        assertEquals(CigarParser.Op.M, ops.get(0).op());
        assertEquals(2, ops.get(1).length());
        assertEquals(CigarParser.Op.I, ops.get(1).op());
        assertEquals(5, ops.get(2).length());
        assertEquals(CigarParser.Op.M, ops.get(2).op());
    }

    @Test
    void parsesAllStandardOps() {
        var ops = CigarParser.parse("1M2I3D4N5S6H7P8=9X");
        assertEquals(9, ops.size());
        assertEquals(CigarParser.Op.M, ops.get(0).op());
        assertEquals(CigarParser.Op.I, ops.get(1).op());
        assertEquals(CigarParser.Op.D, ops.get(2).op());
        assertEquals(CigarParser.Op.N, ops.get(3).op());
        assertEquals(CigarParser.Op.S, ops.get(4).op());
        assertEquals(CigarParser.Op.H, ops.get(5).op());
        assertEquals(CigarParser.Op.P, ops.get(6).op());
        assertEquals(CigarParser.Op.EQ, ops.get(7).op());
        assertEquals(CigarParser.Op.X, ops.get(8).op());
    }

    @Test
    void emptyAndStarReturnEmptyList() {
        assertTrue(CigarParser.parse("").isEmpty());
        assertTrue(CigarParser.parse("*").isEmpty());
    }

    @Test
    void rejectsInvalidCigar() {
        assertThrows(IllegalArgumentException.class,
            () -> CigarParser.parse("garbage"));
        assertThrows(IllegalArgumentException.class,
            () -> CigarParser.parse("10")); // length without op
        assertThrows(IllegalArgumentException.class,
            () -> CigarParser.parse("10Z")); // unknown op
    }

    @Test
    void capsAtMaxOps() {
        StringBuilder s = new StringBuilder();
        for (int i = 0; i < 500; i++) s.append("1M");
        var ops = CigarParser.parse(s.toString());
        assertEquals(500, ops.size());

        var capped = CigarParser.parseCapped(s.toString(), 200);
        assertEquals(200, capped.ops().size());
        assertTrue(capped.truncated());
        assertEquals(500, capped.totalOps());
    }

    @Test
    void cappedResultUntruncatedWhenUnderLimit() {
        var capped = CigarParser.parseCapped("3M2I1M", 100);
        assertEquals(3, capped.ops().size());
        assertFalse(capped.truncated());
        assertEquals(3, capped.totalOps());
    }
}
