package global.thalion.ttio.codecs.registry;

import global.thalion.ttio.Enums.Compression;

/** A codec adapter: uniform decode/encode over the closed channel unions. */
public interface Codec {
    Compression id();
    boolean isContextAware();
    boolean needsEmbeddedReference();
    DecodedChannel decode(ChannelPayload payload, CodecContext ctx);
    EncodedChannel encode(DecodedChannel value, CodecContext ctx);
}
