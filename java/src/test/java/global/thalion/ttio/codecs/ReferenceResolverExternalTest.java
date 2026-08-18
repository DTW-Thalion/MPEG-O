package global.thalion.ttio.codecs;

import static org.junit.jupiter.api.Assertions.assertArrayEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;

import global.thalion.ttio.genomics.LazyReference;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.security.MessageDigest;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

/** External-FASTA branch of {@link ReferenceResolver}: a run written
 *  against a multi-chromosome FASTA records the reference-set md5, and
 *  the resolver must accept it (and still accept the pre-1.9
 *  single-chromosome digests). */
class ReferenceResolverExternalTest {

    @TempDir Path tmp;

    private static byte[] md5(byte[]... parts) throws Exception {
        MessageDigest md = MessageDigest.getInstance("MD5");
        for (byte[] p : parts) md.update(p);
        return md.digest();
    }

    @Test
    void acceptsReferenceSetMd5AndLegacyDigests() throws Exception {
        Path fa = tmp.resolve("multi.fa");
        Files.writeString(fa, ">chr2\nGGGGCCCC\n>chr1\nacgtACGT\n>chrM\nTTTT\n");
        byte[] chr1 = "acgtACGT".getBytes(StandardCharsets.US_ASCII);
        byte[] chr1Upper = "ACGTACGT".getBytes(StandardCharsets.US_ASCII);
        byte[] set = md5(chr1, "GGGGCCCC".getBytes(StandardCharsets.US_ASCII),
                         "TTTT".getBytes(StandardCharsets.US_ASCII));
        assertArrayEquals(set, new LazyReference(fa).setMd5());
        // the digest is cached beside the FASTA and reused while size and mtime match
        Path side = tmp.resolve("multi.fa.ttio-md5");
        String[] parts = Files.readString(side).trim().split("\\s+");
        assertArrayEquals(set, java.util.HexFormat.of().parseHex(parts[0]));
        Files.writeString(side, "00000000000000000000000000000000 " + parts[1] + " " + parts[2] + "\n");
        assertArrayEquals(new byte[16], new LazyReference(fa).setMd5());
        Files.writeString(side, "00000000000000000000000000000000 1 1\n");
        assertArrayEquals(set, new LazyReference(fa).setMd5());

        ReferenceResolver r = new ReferenceResolver(null, fa);
        assertArrayEquals(chr1Upper, r.resolve("x", set, "chr1"));
        assertArrayEquals("GGGGCCCC".getBytes(StandardCharsets.US_ASCII), r.resolve("x", set, "chr2"));
        assertArrayEquals(chr1Upper, r.resolve("x", md5(chr1), "chr1"));
        assertArrayEquals(chr1Upper, r.resolve("x", md5(chr1Upper), "chr1"));
        assertThrows(RefMissingException.class,
            () -> r.resolve("x", new byte[16], "chr1"));
        assertThrows(RefMissingException.class,
            () -> r.resolve("x", set, "chrZ"));
    }
}
