package global.thalion.ttio.codecs.registry;

import static org.junit.jupiter.api.Assertions.*;

import java.util.List;
import java.util.Map;
import org.junit.jupiter.api.Test;

class CodecRegistryTest {

    @Test
    void genomicRunHasCodecContextHelper() throws Exception {
        var m = global.thalion.ttio.genomics.GenomicRun.class
            .getDeclaredMethod("codecContext");
        assertNotNull(m);
    }

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

    @Test
    void nameTokenizedRoundTrip() {
        Codec codec = CodecRegistry.CODEC_REGISTRY.get(
            global.thalion.ttio.Enums.Compression.NAME_TOKENIZED_V2);
        assertNotNull(codec);
        assertFalse(codec.isContextAware());
        java.util.List<String> names = new java.util.ArrayList<>();
        for (int i = 0; i < 200; i++) names.add("read" + i);
        var enc = codec.encode(new DecodedChannel.StrList(names), CodecContext.empty());
        var dec = codec.decode(new ChannelPayload.BytesPayload(
            ((EncodedChannel.DatasetBytes) enc).bytes()), CodecContext.empty());
        assertEquals(names, ((DecodedChannel.StrList) dec).names());
    }

    @Test
    void contextAwareFlags() {
        var R = CodecRegistry.CODEC_REGISTRY;
        assertTrue(R.get(global.thalion.ttio.Enums.Compression.REF_DIFF_V2).isContextAware());
        assertTrue(R.get(global.thalion.ttio.Enums.Compression.FQZCOMP_NX16_Z).isContextAware());
        assertTrue(R.get(global.thalion.ttio.Enums.Compression.MATE_INLINE_V2).isContextAware());
        assertTrue(R.get(global.thalion.ttio.Enums.Compression.REF_DIFF_V2).needsEmbeddedReference());
        assertFalse(R.get(global.thalion.ttio.Enums.Compression.FQZCOMP_NX16_Z).needsEmbeddedReference());
    }

    @Test
    void qualityBinnedRegisteredLossy() {
        Codec codec = CodecRegistry.CODEC_REGISTRY.get(
            global.thalion.ttio.Enums.Compression.QUALITY_BINNED);
        byte[] data = new byte[256];
        for (int i = 0; i < 256; i++) data[i] = (byte) i;
        byte[] once = ((DecodedChannel.Bytes) codec.decode(new ChannelPayload.BytesPayload(
            ((EncodedChannel.DatasetBytes) codec.encode(new DecodedChannel.Bytes(data),
                CodecContext.empty())).bytes()), CodecContext.empty())).data();
        byte[] twice = ((DecodedChannel.Bytes) codec.decode(new ChannelPayload.BytesPayload(
            ((EncodedChannel.DatasetBytes) codec.encode(new DecodedChannel.Bytes(once),
                CodecContext.empty())).bytes()), CodecContext.empty())).data();
        assertEquals(data.length, once.length);
        assertArrayEquals(once, twice);
    }

    @Test
    void needsEmbeddedReferenceOnlyRefDiff() {
        var embed = new java.util.HashSet<global.thalion.ttio.Enums.Compression>();
        CodecRegistry.CODEC_REGISTRY.forEach((cid, c) -> {
            if (c.needsEmbeddedReference()) embed.add(cid);
        });
        assertEquals(java.util.Set.of(global.thalion.ttio.Enums.Compression.REF_DIFF_V2), embed);
    }

    @Test
    void registryGetSafeForUnregisteredValidCodecs() {
        // NONE/ZLIB/LZ4 are valid Compression members but not registered codecs;
        // .get(...) must return null (no exception) — membership-safe.
        for (var c : java.util.List.of(global.thalion.ttio.Enums.Compression.NONE,
                global.thalion.ttio.Enums.Compression.ZLIB,
                global.thalion.ttio.Enums.Compression.LZ4)) {
            assertNull(CodecRegistry.CODEC_REGISTRY.get(c));
        }
    }
}
