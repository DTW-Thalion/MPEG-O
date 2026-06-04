package global.thalion.ttio.browser;

import java.util.Map;

/** Bridges tio-browser GUI display names to TTI-O SDK registry canonical
 *  keys. Registry-covered formats map to their SDK key; GUI-local formats
 *  (fasta/fastq + the FASTA reference/reads + FASTQ export rows) map to null. */
public final class SdkFormatKeys {
    private SdkFormatKeys() {}

    public static final Map<String,String> IMPORT = Map.ofEntries(
        Map.entry("mzML","mzml"), Map.entry("mzTab","mztab"),
        Map.entry("imzML","imzml"), Map.entry("nmrML","nmrml"),
        Map.entry("JCAMP-DX","jcamp-dx"), Map.entry("Bruker timsTOF","bruker-timstof"),
        Map.entry("Waters MassLynx","waters-masslynx"), Map.entry("Thermo .raw","thermo-raw"),
        Map.entry("BAM","bam"), Map.entry("SAM","sam"), Map.entry("CRAM","cram"));

    public static final Map<String,String> EXPORT = Map.ofEntries(
        Map.entry("mzML (indexed)","mzml"), Map.entry("mzTab","mztab"),
        Map.entry("nmrML","nmrml"), Map.entry("imzML","imzml"),
        Map.entry("JCAMP-DX","jcamp-dx"), Map.entry("ISA-Tab/JSON","isa"),
        Map.entry("BAM","bam"), Map.entry("CRAM","cram"));

    /** SDK import key for a GUI display name, or null if GUI-local. */
    public static String importKey(String displayName) { return IMPORT.get(displayName); }
    /** SDK export key for a GUI display name, or null if GUI-local. */
    public static String exportKey(String displayName) { return EXPORT.get(displayName); }
}
