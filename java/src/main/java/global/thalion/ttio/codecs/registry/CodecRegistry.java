package global.thalion.ttio.codecs.registry;

import global.thalion.ttio.Enums.Compression;
import global.thalion.ttio.codecs.BasePack;
import global.thalion.ttio.codecs.DeltaRans;
import global.thalion.ttio.codecs.Quality;
import global.thalion.ttio.codecs.Rans;
import java.util.EnumMap;
import java.util.Map;

/** Maps Compression ids to Codec adapters. Adapters wrap the existing static
 *  codec classes verbatim — no wire change. */
public final class CodecRegistry {
    private CodecRegistry() {}

    public static final Map<Compression, Codec> CODEC_REGISTRY = build();

    private static byte[] bytes(DecodedChannel v) {
        return ((DecodedChannel.Bytes) v).data();
    }
    private static byte[] payloadBytes(ChannelPayload p) {
        return ((ChannelPayload.BytesPayload) p).bytes();
    }

    static final class RansCodec implements Codec {
        private final Compression id;
        private final int order;
        RansCodec(Compression id, int order) { this.id = id; this.order = order; }
        public Compression id() { return id; }
        public boolean isContextAware() { return false; }
        public boolean needsEmbeddedReference() { return false; }
        public DecodedChannel decode(ChannelPayload p, CodecContext ctx) {
            return new DecodedChannel.Bytes(Rans.decode(payloadBytes(p)));
        }
        public EncodedChannel encode(DecodedChannel v, CodecContext ctx) {
            return new EncodedChannel.DatasetBytes(Rans.encode(bytes(v), order));
        }
    }

    static final class BasePackCodec implements Codec {
        public Compression id() { return Compression.BASE_PACK; }
        public boolean isContextAware() { return false; }
        public boolean needsEmbeddedReference() { return false; }
        public DecodedChannel decode(ChannelPayload p, CodecContext ctx) {
            return new DecodedChannel.Bytes(BasePack.decode(payloadBytes(p)));
        }
        public EncodedChannel encode(DecodedChannel v, CodecContext ctx) {
            return new EncodedChannel.DatasetBytes(BasePack.encode(bytes(v)));
        }
    }

    static final class QualityCodec implements Codec {
        public Compression id() { return Compression.QUALITY_BINNED; }
        public boolean isContextAware() { return false; }
        public boolean needsEmbeddedReference() { return false; }
        public DecodedChannel decode(ChannelPayload p, CodecContext ctx) {
            return new DecodedChannel.Bytes(Quality.decode(payloadBytes(p)));
        }
        public EncodedChannel encode(DecodedChannel v, CodecContext ctx) {
            return new EncodedChannel.DatasetBytes(Quality.encode(bytes(v)));
        }
    }

    static final class DeltaRansCodec implements Codec {
        public Compression id() { return Compression.DELTA_RANS_ORDER0; }
        public boolean isContextAware() { return false; }
        public boolean needsEmbeddedReference() { return false; }
        public DecodedChannel decode(ChannelPayload p, CodecContext ctx) {
            return new DecodedChannel.Bytes(DeltaRans.decode(payloadBytes(p)));
        }
        public EncodedChannel encode(DecodedChannel v, CodecContext ctx) {
            if (ctx.elementSize() == null) {
                throw new IllegalArgumentException(
                    "DELTA_RANS encode requires CodecContext.elementSize");
            }
            return new EncodedChannel.DatasetBytes(DeltaRans.encode(bytes(v), ctx.elementSize()));
        }
    }

    private static Map<Compression, Codec> build() {
        EnumMap<Compression, Codec> m = new EnumMap<>(Compression.class);
        m.put(Compression.RANS_ORDER0, new RansCodec(Compression.RANS_ORDER0, 0));
        m.put(Compression.RANS_ORDER1, new RansCodec(Compression.RANS_ORDER1, 1));
        m.put(Compression.BASE_PACK, new BasePackCodec());
        m.put(Compression.QUALITY_BINNED, new QualityCodec());
        m.put(Compression.DELTA_RANS_ORDER0, new DeltaRansCodec());
        return m;
    }
}
