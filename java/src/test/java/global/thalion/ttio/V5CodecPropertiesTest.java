package global.thalion.ttio;

import global.thalion.ttio.codecs.BasePack;
import global.thalion.ttio.codecs.Quality;
import global.thalion.ttio.codecs.Rans;

import net.jqwik.api.Arbitraries;
import net.jqwik.api.Arbitrary;
import net.jqwik.api.ForAll;
import net.jqwik.api.Property;
import net.jqwik.api.Provide;
import net.jqwik.api.constraints.IntRange;
import net.jqwik.api.constraints.Size;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;

/**
 * V5 property-based tests for the genomic codecs (Java).
 *
 * <p>Mirrors the Python (V5a) coverage: each codec's round-trip /
 * safety properties are exercised with jqwik-generated inputs. A
 * counter-example surfaces either a bug or a previously-undocumented
 * edge case.</p>
 *
 * <p>Codecs covered:</p>
 * <ul>
 *   <li>{@link Rans#encode(byte[], int)} / {@link Rans#decode(byte[])}
 *       — order 0 + 1 lossless round-trip.</li>
 *   <li>{@link BasePack#encode(byte[])} / {@link BasePack#decode(byte[])}
 *       — round-trips ANY byte sequence losslessly via the sidecar
 *       mask (M84 binding decision §81).</li>
 *   <li>{@link Quality#encode(byte[])} / {@link Quality#decode(byte[])}
 *       — lossy bin-quantised round-trip; per-byte error bounded by
 *       the Illumina-8 worst case (215 = 255 − 40).</li>
 * </ul>
 *
 * <p>jqwik default: 1000 tries per property. Each test caps input
 * size at 4096 bytes / 64 names so the full suite stays under ~5
 * seconds.</p>
 *
 * <p>Per docs/verification-workplan.md §V5.</p>
 */
public class V5CodecPropertiesTest {

    private static final int MAX_BYTES = 4096;
    private static final int MAX_NAMES = 64;
    private static final int MAX_NAME_LEN = 32;
    private static final byte[] ILLUMINA8_CENTRES = {0, 5, 15, 22, 27, 32, 37, 40};
    private static final int QUALITY_MAX_ERROR = 215;  // 255 - 40

    // ── Provider arbitraries ───────────────────────────────────────────────

    @Provide
    Arbitrary<byte[]> arbitraryBytes() {
        return Arbitraries.bytes()
            .list()
            .ofMinSize(0)
            .ofMaxSize(MAX_BYTES)
            .map(list -> {
                byte[] arr = new byte[list.size()];
                for (int i = 0; i < arr.length; i++) arr[i] = list.get(i);
                return arr;
            });
    }

    @Provide
    Arbitrary<byte[]> arbitraryAcgtBytes() {
        return Arbitraries.of((byte) 'A', (byte) 'C', (byte) 'G', (byte) 'T')
            .list()
            .ofMinSize(0)
            .ofMaxSize(MAX_BYTES)
            .map(list -> {
                byte[] arr = new byte[list.size()];
                for (int i = 0; i < arr.length; i++) arr[i] = list.get(i);
                return arr;
            });
    }

    @Provide
    Arbitrary<byte[]> arbitraryIlluminaCentreBytes() {
        Byte[] boxedCentres = new Byte[ILLUMINA8_CENTRES.length];
        for (int i = 0; i < ILLUMINA8_CENTRES.length; i++) {
            boxedCentres[i] = ILLUMINA8_CENTRES[i];
        }
        return Arbitraries.of(boxedCentres)
            .list()
            .ofMinSize(0)
            .ofMaxSize(MAX_BYTES)
            .map(list -> {
                byte[] arr = new byte[list.size()];
                for (int i = 0; i < arr.length; i++) arr[i] = list.get(i);
                return arr;
            });
    }

    @Provide
    Arbitrary<List<String>> arbitraryNameList() {
        return Arbitraries.strings()
            .ascii()
            .ofMinLength(0)
            .ofMaxLength(MAX_NAME_LEN)
            // Strip control characters that break tokenization.
            .filter(s -> s.chars().allMatch(c -> c >= 33 && c <= 126))
            .list()
            .ofMinSize(0)
            .ofMaxSize(MAX_NAMES);
    }

    // ── rANS ───────────────────────────────────────────────────────────────

    @Property
    boolean ransOrder0RoundTrip(@ForAll("arbitraryBytes") byte[] data) {
        byte[] encoded = Rans.encode(data, 0);
        byte[] decoded = Rans.decode(encoded);
        return Arrays.equals(decoded, data);
    }

    @Property
    boolean ransOrder1RoundTrip(@ForAll("arbitraryBytes") byte[] data) {
        byte[] encoded = Rans.encode(data, 1);
        byte[] decoded = Rans.decode(encoded);
        return Arrays.equals(decoded, data);
    }

    @Property
    boolean ransNotPathologicallyInflated(@ForAll("arbitraryBytes") byte[] data) {
        if (data.length == 0) return true;
        byte[] encoded = Rans.encode(data, 0);
        // 8× input size + 2 KB header (matches the Python V5a bound).
        long maxAllowed = Math.max(8L * data.length, 2048L);
        return encoded.length <= maxAllowed;
    }

    // ── BASE_PACK ─────────────────────────────────────────────────────────

    @Property
    boolean basePackRoundTripAcgt(@ForAll("arbitraryAcgtBytes") byte[] data) {
        byte[] encoded = BasePack.encode(data);
        byte[] decoded = BasePack.decode(encoded);
        return Arrays.equals(decoded, data);
    }

    @Property
    boolean basePackCompressionRatioAcgt(@ForAll("arbitraryAcgtBytes") byte[] data) {
        if (data.length == 0) return true;
        byte[] encoded = BasePack.encode(data);
        // ceil(len/4) data bytes + ≤ 64-byte header.
        long expectedMax = (data.length + 3L) / 4L + 64L;
        return encoded.length <= expectedMax;
    }

    @Property
    boolean basePackRoundTripAnyBytes(@ForAll("arbitraryBytes") byte[] data) {
        // Per binding decision §81, BASE_PACK round-trips arbitrary
        // bytes via the sidecar mask. The Python V5a verification
        // surfaced this contract; mirror it in Java.
        byte[] encoded = BasePack.encode(data);
        byte[] decoded = BasePack.decode(encoded);
        return Arrays.equals(decoded, data);
    }

    // ── NAME_TOKENIZED — removed in Phase 2c (v1 codec id 8 deleted) ────
    // The v2 codec (NameTokenizerV2, codec id 15) is exercised by
    // NameTokenizerV2Test; no jqwik property suite here yet.

    // ── QUALITY_BINNED ────────────────────────────────────────────────────

    @Property
    boolean qualityBinnedRoundTripBoundedError(@ForAll("arbitraryBytes") byte[] data) {
        byte[] encoded = Quality.encode(data);
        byte[] decoded = Quality.decode(encoded);
        if (decoded.length != data.length) return false;
        for (int i = 0; i < data.length; i++) {
            int dec = decoded[i] & 0xFF;
            int orig = data[i] & 0xFF;
            // Decoded byte must be a centre (or 0 for unreachable nibbles).
            boolean isCentre = false;
            for (byte c : ILLUMINA8_CENTRES) {
                if ((c & 0xFF) == dec) { isCentre = true; break; }
            }
            if (!isCentre) return false;
            int err = Math.abs(orig - dec);
            if (err > QUALITY_MAX_ERROR) return false;
        }
        return true;
    }

    @Property
    boolean qualityBinnedCentreInputsLossless(
            @ForAll("arbitraryIlluminaCentreBytes") byte[] data) {
        byte[] encoded = Quality.encode(data);
        byte[] decoded = Quality.decode(encoded);
        return Arrays.equals(decoded, data);
    }
}
