package global.thalion.ttio.codecs.registry;

import static org.junit.jupiter.api.Assertions.*;

import java.util.List;
import java.util.Map;
import org.junit.jupiter.api.Test;

class CodecRegistryTest {

    @Test
    void decodedChannelBytesVariant() {
        DecodedChannel d = new DecodedChannel.Bytes(new byte[]{1, 2, 3});
        assertInstanceOf(DecodedChannel.Bytes.class, d);
        assertArrayEquals(new byte[]{1, 2, 3}, ((DecodedChannel.Bytes) d).data());
    }

    @Test
    void decodedChannelStrListVariant() {
        DecodedChannel d = new DecodedChannel.StrList(List.of("r1", "r2"));
        assertEquals(List.of("r1", "r2"), ((DecodedChannel.StrList) d).names());
    }

    @Test
    void encodedChannelVariants() {
        EncodedChannel a = new EncodedChannel.DatasetBytes(new byte[]{9});
        assertArrayEquals(new byte[]{9}, ((EncodedChannel.DatasetBytes) a).bytes());
        EncodedChannel b = new EncodedChannel.GroupLayout(
            Map.of("refdiff_v2", new byte[]{7}), Map.of());
        assertTrue(((EncodedChannel.GroupLayout) b).children().containsKey("refdiff_v2"));
    }

    @Test
    void channelPayloadBytesVariant() {
        ChannelPayload p = new ChannelPayload.BytesPayload(new byte[]{4});
        assertArrayEquals(new byte[]{4}, ((ChannelPayload.BytesPayload) p).bytes());
    }

    @Test
    void codecContextEmptyIsAllNull() {
        CodecContext ctx = CodecContext.empty();
        assertNull(ctx.readLengths());
        assertNull(ctx.elementSize());
        assertNull(ctx.referenceResolver());
        assertNull(ctx.cigarsProvider());
    }

    @Test
    void codecContextBuilderSetsFields() {
        CodecContext ctx = CodecContext.builder()
            .elementSize(4).readCount(10).build();
        assertEquals(Integer.valueOf(4), ctx.elementSize());
        assertEquals(Integer.valueOf(10), ctx.readCount());
        assertNull(ctx.positions());
    }

    @Test
    void plainCodecsRegisteredAndRoundTrip() {
        var ctx = CodecContext.empty();
        for (var cid : java.util.List.of(
                global.thalion.ttio.Enums.Compression.RANS_ORDER0,
                global.thalion.ttio.Enums.Compression.RANS_ORDER1,
                global.thalion.ttio.Enums.Compression.BASE_PACK)) {
            Codec codec = CodecRegistry.CODEC_REGISTRY.get(cid);
            assertNotNull(codec, "registered: " + cid);
            assertEquals(cid, codec.id());
            assertFalse(codec.isContextAware());
            byte[] data = new byte[256];
            for (int i = 0; i < 256; i++) data[i] = (byte) i;
            var enc = codec.encode(new DecodedChannel.Bytes(data), ctx);
            byte[] encBytes = ((EncodedChannel.DatasetBytes) enc).bytes();
            var dec = codec.decode(new ChannelPayload.BytesPayload(encBytes), ctx);
            assertArrayEquals(data, ((DecodedChannel.Bytes) dec).data());
        }
    }

    @Test
    void deltaRansNeedsElementSize() {
        Codec codec = CodecRegistry.CODEC_REGISTRY.get(
            global.thalion.ttio.Enums.Compression.DELTA_RANS_ORDER0);
        assertNotNull(codec);
        byte[] data = new byte[40];
        assertThrows(IllegalArgumentException.class,
            () -> codec.encode(new DecodedChannel.Bytes(data), CodecContext.empty()));
    }

    @Test
    void registryKeyMatchesId() {
        CodecRegistry.CODEC_REGISTRY.forEach((cid, codec) -> assertEquals(cid, codec.id()));
    }
}
