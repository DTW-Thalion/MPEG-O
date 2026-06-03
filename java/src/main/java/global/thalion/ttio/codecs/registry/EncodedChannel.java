package global.thalion.ttio.codecs.registry;

import java.util.Map;

/** Closed union of encode output: a flat dataset blob or a group layout (ref_diff). */
public sealed interface EncodedChannel {
    record DatasetBytes(byte[] bytes) implements EncodedChannel {}
    record GroupLayout(Map<String, byte[]> children, Map<String, Object> attrs)
        implements EncodedChannel {}
}
