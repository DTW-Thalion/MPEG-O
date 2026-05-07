package global.thalion.ttio.browser.view.plot;

import global.thalion.ttio.SpectralDataset;
import global.thalion.ttio.genomics.AlignedRead;
import global.thalion.ttio.genomics.GenomicRun;
import org.junit.jupiter.api.Test;

import java.nio.file.Paths;

import static org.junit.jupiter.api.Assertions.*;

/** Pure-Java tests for {@link ReadInspectorView#formatMetadata}. */
class ReadInspectorViewTest {

    @Test
    void formattedMetadataIncludesReadNameAndMapq() {
        AlignedRead read = new AlignedRead(
            "read_001", "chr1", 100L, 30,
            "10M", "ACGTACGTAC", new byte[]{20, 25, 30, 35, 40, 30, 25, 20, 15, 10},
            0, "*", 0L, 0);
        String meta = ReadInspectorView.formatMetadata(read);
        assertTrue(meta.contains("read_001"), "metadata: " + meta);
        assertTrue(meta.contains("MAPQ"), "metadata: " + meta);
        assertTrue(meta.contains("chr1"), "metadata: " + meta);
        assertTrue(meta.contains("pos: 100"), "metadata: " + meta);
    }

    @Test
    void unmappedReadHidesPositionAndShowsTag() {
        // Unmapped flag bit 0x4 set, chromosome "*"
        AlignedRead unmapped = new AlignedRead(
            "read_002", "*", 0L, 0,
            "*", "ACGT", new byte[]{20, 20, 20, 20},
            0x4, "*", 0L, 0);
        String meta = ReadInspectorView.formatMetadata(unmapped);
        assertTrue(meta.contains("(unmapped)"), "metadata: " + meta);
        assertFalse(meta.contains("pos:"), "should not show pos for unmapped: " + meta);
    }

    @Test
    void formatHandlesNullRead() {
        assertEquals("", ReadInspectorView.formatMetadata(null));
    }

    @Test
    void formatIncludesMateInfoOnlyWhenPresent() {
        AlignedRead withMate = new AlignedRead(
            "r1", "chr1", 100L, 30, "10M", "ACGT", new byte[]{20, 20, 20, 20},
            0, "chr2", 500L, 200);
        AlignedRead withoutMate = new AlignedRead(
            "r2", "chr1", 100L, 30, "10M", "ACGT", new byte[]{20, 20, 20, 20},
            0, "*", 0L, 0);
        assertTrue(ReadInspectorView.formatMetadata(withMate).contains("mate:"));
        assertFalse(ReadInspectorView.formatMetadata(withoutMate).contains("mate:"));
    }
}
