package global.thalion.ttio.browser.importers;

import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.*;

class FormatSnifferTest {

    @Test
    void sniffsTioByHdf5Magic() {
        byte[] hdf5 = {(byte) 0x89, 'H', 'D', 'F', '\r', '\n', 0x1a, '\n', 0, 0};
        assertEquals(".tio", FormatSniffer.sniff(hdf5, "x.tio"));
    }

    @Test
    void sniffsBamByMagic() {
        byte[] bytes = {'B', 'A', 'M', 0x01, 0x00};
        assertEquals("BAM", FormatSniffer.sniff(bytes, "x.bam"));
    }

    @Test
    void sniffsCramByMagic() {
        byte[] bytes = {'C', 'R', 'A', 'M', 0x03, 0x00, 0x00};
        assertEquals("CRAM", FormatSniffer.sniff(bytes, "x.cram"));
    }

    @Test
    void sniffsTtioTransportByMagic() {
        byte[] bytes = {'T', 'T', 'I', 'O', 0x01, 0x00};
        assertEquals(".tis", FormatSniffer.sniff(bytes, "x.tis"));
    }

    @Test
    void sniffsMzMLByXmlRoot() {
        String header = "<?xml version=\"1.0\"?>\n<indexedmzML xmlns=\"...\">";
        assertEquals("mzML", FormatSniffer.sniff(header.getBytes(), "tiny.pwiz.1.1.mzML"));
    }

    @Test
    void sniffsImzMLWhenFilenameEndsImzml() {
        String header = "<?xml version=\"1.0\"?>\n<mzML xmlns=\"...\">";
        assertEquals("imzML", FormatSniffer.sniff(header.getBytes(), "image.imzML"));
    }

    @Test
    void sniffsNmrMLByRoot() {
        String header = "<?xml version=\"1.0\"?>\n<nmrML xmlns=\"...\">";
        assertEquals("nmrML", FormatSniffer.sniff(header.getBytes(), "x.nmrML"));
    }

    @Test
    void sniffsJcampDxByLdr() {
        String header = "##JCAMP-DX=5.01\n##DATA TYPE=RAMAN SPECTRUM\n";
        assertEquals("JCAMP-DX", FormatSniffer.sniff(header.getBytes(), "x.dx"));
    }

    @Test
    void sniffsMzTabByMtdLine() {
        String header = "MTD\tmzTab-version\t1.0.0\n";
        assertEquals("mzTab", FormatSniffer.sniff(header.getBytes(), "x.mzTab"));
    }

    @Test
    void sniffsBrukerDirectoryByExtension() {
        assertEquals("Bruker timsTOF",
            FormatSniffer.sniff(new byte[0], "experiment.d", true));
    }

    @Test
    void sniffsWatersDirectoryByExtension() {
        assertEquals("Waters MassLynx",
            FormatSniffer.sniff(new byte[0], "data.raw", true));
    }

    @Test
    void sniffsThermoFileByExtension() {
        assertEquals("Thermo .raw",
            FormatSniffer.sniff(new byte[0], "data.raw", false));
    }

    @Test
    void sniffsSamByHeaderTag() {
        String header = "@HD\tVN:1.6\tSO:coordinate\n@SQ\tSN:chr1\tLN:1000\n";
        assertEquals("SAM", FormatSniffer.sniff(header.getBytes(), "x.sam"));
    }

    @Test
    void sniffsFastaByGreaterThan() {
        String header = ">chr1 description\nACGTACGT\n";
        assertEquals("FASTA", FormatSniffer.sniff(header.getBytes(), "x.fa"));
    }

    @Test
    void sniffsFastqByFourLineShape() {
        String fq = "@SEQ1\nACGT\n+\n!!!!\n";
        assertEquals("FASTQ", FormatSniffer.sniff(fq.getBytes(), "x.fastq"));
    }

    @Test
    void returnsNullOnUnrecognized() {
        assertNull(FormatSniffer.sniff("hello world\n".getBytes(), "x.txt"));
    }

    @Test
    void firstNonBlankLineSkipsLeadingBlank() {
        byte[] in = "\n\n##first non-blank\nignored\n".getBytes();
        assertEquals("##first non-blank", FormatSniffer.firstNonBlankLine(in));
    }

    @Test
    void looksLikeFastqRequiresPlusOnLineThree() {
        assertTrue(FormatSniffer.looksLikeFastq("@a\nACGT\n+\n!!!!\n".getBytes()));
        assertFalse(FormatSniffer.looksLikeFastq("@a\nACGT\nbad\n!!!!\n".getBytes()));
    }
}
