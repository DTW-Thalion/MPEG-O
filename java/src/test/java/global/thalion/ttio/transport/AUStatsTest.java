/*
 * TTI-O Java Implementation.
 * SPDX-License-Identifier: LGPL-3.0-or-later
 *
 * Unit tests for AUStats (per-AU summary statistics).
 *
 * Cross-language equivalents:
 *   objc/Tests/TestAUStats.m
 *   python/tests/test_au_stats.py
 */
package global.thalion.ttio.transport;

import global.thalion.ttio.MiniJson;

import org.junit.jupiter.api.Test;

import java.util.Arrays;
import java.util.Map;

import static org.junit.jupiter.api.Assertions.*;

class AUStatsTest {

    private static ChannelData ch(String name, int nElements, int dataLen) {
        return new ChannelData(name, 0, 0, nElements, new byte[dataLen]);
    }

    private static AccessUnit msAu() {
        return new AccessUnit(
            /*spectrumClass*/ 0,
            /*acquisitionMode*/ 0,
            /*msLevel*/ 2,
            /*polarity*/ 1,
            /*retentionTime*/ 12.5,
            /*precursorMz*/ 400.5,
            /*precursorCharge*/ 2,
            /*ionMobility*/ 0.0,
            /*basePeakIntensity*/ 98765.0,
            /*channels*/ Arrays.asList(ch("mz", 1024, 4096),
                                       ch("intensity", 1024, 4096)),
            /*pixelX*/ 0L, /*pixelY*/ 0L, /*pixelZ*/ 0L,
            /*chromosome*/ "",
            /*position*/ 0L,
            /*mappingQuality*/ 0,
            /*flags*/ 0,
            /*matePosition*/ -1L,
            /*templateLength*/ 0
        );
    }

    private static AccessUnit genomicAu() {
        return new AccessUnit(
            /*spectrumClass*/ 5,
            /*acquisitionMode*/ 0,
            /*msLevel*/ 0,
            /*polarity*/ 2,
            /*retentionTime*/ 0.0,
            /*precursorMz*/ 0.0,
            /*precursorCharge*/ 0,
            /*ionMobility*/ 0.0,
            /*basePeakIntensity*/ 0.0,
            /*channels*/ Arrays.asList(ch("seq", 150, 150),
                                       ch("qual", 150, 150),
                                       ch("cigar", 10, 12)),
            /*pixelX*/ 0L, /*pixelY*/ 0L, /*pixelZ*/ 0L,
            /*chromosome*/ "chr3",
            /*position*/ 12_345_678L,
            /*mappingQuality*/ 60,
            /*flags*/ 99,
            /*matePosition*/ -1L,
            /*templateLength*/ 0
        );
    }

    private static AccessUnit imageAu() {
        return new AccessUnit(
            /*spectrumClass*/ 4,
            /*acquisitionMode*/ 0,
            /*msLevel*/ 1,
            /*polarity*/ 0,
            /*retentionTime*/ 0.0,
            /*precursorMz*/ 0.0,
            /*precursorCharge*/ 0,
            /*ionMobility*/ 0.0,
            /*basePeakIntensity*/ 0.0,
            /*channels*/ Arrays.asList(ch("mz", 512, 2048)),
            /*pixelX*/ 7L, /*pixelY*/ 11L, /*pixelZ*/ 13L,
            /*chromosome*/ "",
            /*position*/ 0L,
            /*mappingQuality*/ 0,
            /*flags*/ 0,
            /*matePosition*/ -1L,
            /*templateLength*/ 0
        );
    }

    @Test
    void msStatsFieldsPreserved() {
        AUStats s = AUStats.fromAccessUnit(msAu(), 42L);
        assertEquals(42L, s.auSequence);
        assertEquals(0, s.spectrumClass);
        assertEquals(2, s.msLevel);
        assertEquals(1, s.polarity);
        assertEquals(12.5, s.retentionTime);
        assertEquals(400.5, s.precursorMz);
        assertEquals(2, s.precursorCharge);
        assertEquals(98765.0, s.basePeakIntensity);
        assertEquals(2L, s.channelCount);
        assertEquals(2048L, s.totalElements);
        assertEquals(8192L, s.payloadBytes);
        assertEquals(0L, s.position);
        assertEquals(0L, s.pixelX);
    }

    @Test
    void genomicStatsFieldsPreserved() {
        AUStats s = AUStats.fromAccessUnit(genomicAu(), 7L);
        assertEquals(5, s.spectrumClass);
        assertEquals("chr3", s.chromosome);
        assertEquals(12_345_678L, s.position);
        assertEquals(60, s.mappingQuality);
        assertEquals(99, s.flags);
        assertEquals(3L, s.channelCount);
        assertEquals(310L, s.totalElements);   // 150 + 150 + 10
        assertEquals(312L, s.payloadBytes);    // 150 + 150 + 12
    }

    @Test
    void imageStatsFieldsPreserved() {
        AUStats s = AUStats.fromAccessUnit(imageAu(), 3L);
        assertEquals(4, s.spectrumClass);
        assertEquals(7L, s.pixelX);
        assertEquals(11L, s.pixelY);
        assertEquals(13L, s.pixelZ);
    }

    @SuppressWarnings("unchecked")
    @Test
    void jsonMsExcludesGenomicAndImageKeys() {
        String j = AUStats.fromAccessUnit(msAu(), 1L).jsonString();
        Map<String, Object> m = (Map<String, Object>) MiniJson.parse(j);
        assertFalse(m.containsKey("chromosome"));
        assertFalse(m.containsKey("position"));
        assertFalse(m.containsKey("mapping_quality"));
        assertFalse(m.containsKey("flags"));
        assertFalse(m.containsKey("pixel_x"));
        assertTrue(m.containsKey("au_sequence"));
        assertTrue(m.containsKey("channel_count"));
    }

    @SuppressWarnings("unchecked")
    @Test
    void jsonGenomicIncludesGenomicKeys() {
        String j = AUStats.fromAccessUnit(genomicAu(), 7L).jsonString();
        Map<String, Object> m = (Map<String, Object>) MiniJson.parse(j);
        assertEquals("chr3", m.get("chromosome"));
        assertEquals(12_345_678L, ((Number) m.get("position")).longValue());
        assertEquals(60L, ((Number) m.get("mapping_quality")).longValue());
        assertEquals(99L, ((Number) m.get("flags")).longValue());
        assertFalse(m.containsKey("pixel_x"));
    }

    @SuppressWarnings("unchecked")
    @Test
    void jsonImageIncludesImageKeys() {
        String j = AUStats.fromAccessUnit(imageAu(), 3L).jsonString();
        Map<String, Object> m = (Map<String, Object>) MiniJson.parse(j);
        assertEquals(7L, ((Number) m.get("pixel_x")).longValue());
        assertEquals(11L, ((Number) m.get("pixel_y")).longValue());
        assertEquals(13L, ((Number) m.get("pixel_z")).longValue());
        assertFalse(m.containsKey("chromosome"));
    }

    @Test
    void jsonKeysCompactAndSorted() {
        String j = AUStats.fromAccessUnit(msAu(), 42L).jsonString();
        // No whitespace anywhere outside string contents (none of
        // our test fields contain spaces).
        assertFalse(j.contains(" "));
        // au_sequence sorts before base_peak_intensity sorts before
        // channel_count, so they must appear in that order.
        int a = j.indexOf("au_sequence");
        int b = j.indexOf("base_peak_intensity");
        int c = j.indexOf("channel_count");
        assertTrue(a >= 0 && b > a && c > b,
            "expected au_sequence < base_peak_intensity < channel_count in " + j);
    }

    @Test
    void jsonStringForShortcut() {
        AccessUnit au = msAu();
        assertEquals(
            AUStats.fromAccessUnit(au, 99L).jsonString(),
            AUStats.jsonStringFor(au, 99L)
        );
    }
}
