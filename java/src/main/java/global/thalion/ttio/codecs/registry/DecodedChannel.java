package global.thalion.ttio.codecs.registry;

import java.util.List;

/** Closed union of a decoded channel value: bytes | str-list | mate-info.
 *  Mirrors the Python DecodedChannel; consumed via pattern-matching switch. */
public sealed interface DecodedChannel {
    record Bytes(byte[] data) implements DecodedChannel {}
    record StrList(List<String> names) implements DecodedChannel {}
    record MateInfo(int[] mateChromIds, long[] matePositions, int[] templateLengths)
        implements DecodedChannel {}
}
