package global.thalion.ttio.codecs.registry;

import global.thalion.ttio.providers.StorageGroup;

/** Encoded payload: either flat dataset bytes or a storage group (ref_diff). */
public sealed interface ChannelPayload {
    record BytesPayload(byte[] bytes) implements ChannelPayload {}
    record GroupPayload(StorageGroup group) implements ChannelPayload {}
}
