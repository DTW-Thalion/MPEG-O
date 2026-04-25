/*
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
#import "TTIOTransportClient.h"
#import "TTIOTransportPacket.h"
#import "TTIOAccessUnit.h"

#include <libwebsockets.h>
#include <string.h>

@interface TTIOTransportClient ()
{
    NSString *_url;
    NSString *_queryJSON;
    NSMutableData *_pendingFrame;  // accumulates fragmented frames
    NSMutableArray<TTIOTransportPacketRecord *> *_packets;
    BOOL _sawEndOfStream;
    BOOL _connectionEstablished;
    BOOL _connectionClosed;
    BOOL _queryPending;
    NSError *_protocolError;
}
- (void)_onEstablished;
- (NSString *)_takePendingQuery;
- (void)_onReceiveFragment:(const void *)bytes
                     length:(size_t)len
                      first:(BOOL)first
                      final:(BOOL)final;
- (void)_onConnectionError:(NSString *)message;
- (void)_onClosed;
@end


static NSString *queryJSONFromFilters(NSDictionary<NSString *, id> *filters)
{
    NSDictionary *envelope = @{@"type": @"query",
                                @"filters": filters ?: @{}};
    NSData *data = [NSJSONSerialization dataWithJSONObject:envelope
                                                     options:0
                                                       error:nil];
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}


static int lwsCallback(struct lws *wsi,
                        enum lws_callback_reasons reason,
                        void *user, void *in, size_t len)
{
    (void)user;
    void *opaque = wsi ? lws_get_opaque_user_data(wsi) : NULL;
    TTIOTransportClient *client = opaque ? (__bridge TTIOTransportClient *)opaque : nil;
    if (!client) return 0;

    switch (reason) {
        case LWS_CALLBACK_CLIENT_ESTABLISHED: {
            [client _onEstablished];
            lws_callback_on_writable(wsi);
            break;
        }
        case LWS_CALLBACK_CLIENT_WRITEABLE: {
            NSString *pending = [client _takePendingQuery];
            if (pending) {
                NSData *utf8 = [pending dataUsingEncoding:NSUTF8StringEncoding];
                unsigned char *buf = calloc(LWS_PRE + utf8.length, 1);
                memcpy(buf + LWS_PRE, utf8.bytes, utf8.length);
                int wrote = lws_write(wsi, buf + LWS_PRE, utf8.length, LWS_WRITE_TEXT);
                free(buf);
                if (wrote < (int)utf8.length) return -1;
            }
            break;
        }
        case LWS_CALLBACK_CLIENT_RECEIVE: {
            BOOL first = lws_is_first_fragment(wsi) != 0;
            BOOL final = lws_is_final_fragment(wsi) != 0;
            [client _onReceiveFragment:in length:len first:first final:final];
            break;
        }
        case LWS_CALLBACK_CLIENT_CONNECTION_ERROR: {
            NSString *msg = in ? [NSString stringWithUTF8String:(const char *)in] : @"connect error";
            [client _onConnectionError:msg];
            return -1;
        }
        case LWS_CALLBACK_CLIENT_CLOSED:
        case LWS_CALLBACK_CLOSED: {
            [client _onClosed];
            break;
        }
        default:
            break;
    }
    return 0;
}


static const struct lws_protocols lwsProtocols[] = {
    {
        "ttio-transport",
        lwsCallback,
        0,      // per_session_data_size — we use lws_set_opaque_user_data
        65536,  // rx_buffer_size
        0, NULL, 0
    },
    LWS_PROTOCOL_LIST_TERM
};


@implementation TTIOTransportClient

- (instancetype)initWithURL:(NSString *)url
{
    if ((self = [super init])) {
        _url = [url copy];
        _pendingFrame = [NSMutableData data];
        _packets = [NSMutableArray array];
    }
    return self;
}

// ---------------------------------------------------------------- fetch

- (NSArray<TTIOTransportPacketRecord *> *)
    fetchPacketsWithFilters:(NSDictionary<NSString *, id> *)filters
                    timeout:(NSTimeInterval)timeoutSeconds
                      error:(NSError **)error
{
    _queryJSON = queryJSONFromFilters(filters);
    _queryPending = YES;
    _sawEndOfStream = NO;
    _connectionEstablished = NO;
    _connectionClosed = NO;
    _protocolError = nil;
    [_pendingFrame setLength:0];
    [_packets removeAllObjects];

    // Parse URL → host + port + path.
    NSURLComponents *components = [NSURLComponents componentsWithString:_url];
    if (!components || !components.host) {
        if (error) *error = [NSError errorWithDomain:TTIOTransportErrorDomain
                                                 code:TTIOTransportErrorUnexpectedPayload
                                             userInfo:@{NSLocalizedDescriptionKey:
                             [NSString stringWithFormat:@"invalid URL: %@", _url]}];
        return nil;
    }
    NSString *scheme = components.scheme ?: @"ws";
    int usessl = [scheme isEqualToString:@"wss"] ? 1 : 0;
    int port = components.port ? components.port.intValue : (usessl ? 443 : 80);
    NSString *path = components.path.length ? components.path : @"/";

    // Silence libwebsockets log spam for tests.
    lws_set_log_level(LLL_ERR, NULL);

    struct lws_context_creation_info info;
    memset(&info, 0, sizeof(info));
    info.port = CONTEXT_PORT_NO_LISTEN;
    info.protocols = lwsProtocols;
    info.gid = -1;
    info.uid = -1;
    info.options = LWS_SERVER_OPTION_DO_SSL_GLOBAL_INIT;

    struct lws_context *ctx = lws_create_context(&info);
    if (!ctx) {
        if (error) *error = [NSError errorWithDomain:TTIOTransportErrorDomain
                                                 code:TTIOTransportErrorUnexpectedPayload
                                             userInfo:@{NSLocalizedDescriptionKey:
                             @"lws_create_context failed"}];
        return nil;
    }

    // Hold onto the C strings so their lifetime exceeds the lws
    // connect-info struct.
    NSString *hostStr = [components.host copy];
    NSString *pathStr = [path copy];
    const char *hostC = [hostStr UTF8String];
    const char *pathC = [pathStr UTF8String];

    struct lws_client_connect_info cinfo;
    memset(&cinfo, 0, sizeof(cinfo));
    cinfo.context = ctx;
    cinfo.address = hostC;
    cinfo.port = port;
    cinfo.path = pathC;
    cinfo.host = hostC;
    cinfo.origin = hostC;
    cinfo.protocol = "ttio-transport";
    cinfo.ssl_connection = usessl;
    cinfo.opaque_user_data = (__bridge void *)self;

    struct lws *wsi = lws_client_connect_via_info(&cinfo);
    if (!wsi) {
        lws_context_destroy(ctx);
        (void)hostStr; (void)pathStr;
        if (error) *error = [NSError errorWithDomain:TTIOTransportErrorDomain
                                                 code:TTIOTransportErrorUnexpectedPayload
                                             userInfo:@{NSLocalizedDescriptionKey:
                             @"lws_client_connect_via_info failed"}];
        return nil;
    }

    NSDate *deadline = (timeoutSeconds > 0)
        ? [NSDate dateWithTimeIntervalSinceNow:timeoutSeconds]
        : [NSDate distantFuture];

    // Service loop — 50 ms quanta, stops on EOS / close / timeout.
    while (!_sawEndOfStream && !_connectionClosed) {
        if ([deadline timeIntervalSinceNow] <= 0) {
            lws_context_destroy(ctx);
            if (error) *error = [NSError errorWithDomain:TTIOTransportErrorDomain
                                                     code:TTIOTransportErrorTruncated
                                                 userInfo:@{NSLocalizedDescriptionKey:
                                 @"fetch timed out"}];
            return nil;
        }
        int rc = lws_service(ctx, 50);
        if (rc < 0) break;
    }

    lws_context_destroy(ctx);

    if (_protocolError) {
        if (error) *error = _protocolError;
        return nil;
    }
    return [_packets copy];
}

// ---------------------------------------------------------------- materialize

- (BOOL)streamToFilePath:(NSString *)outputPath
                  filters:(NSDictionary<NSString *, id> *)filters
                    error:(NSError **)error
{
    NSArray<TTIOTransportPacketRecord *> *packets =
        [self fetchPacketsWithFilters:filters timeout:30.0 error:error];
    if (!packets) return NO;

    // Serialize packets back into a byte buffer and feed through
    // TTIOTransportReader for materialization.
    NSMutableData *buf = [NSMutableData data];
    for (TTIOTransportPacketRecord *rec in packets) {
        [buf appendData:[rec.header encode]];
        [buf appendData:rec.payload];
        if (rec.header.flags & TTIOTransportPacketFlagHasChecksum) {
            uint32_t crc = TTIOTransportCRC32C((const uint8_t *)rec.payload.bytes,
                                                 rec.payload.length);
            uint8_t crcBuf[4];
            crcBuf[0] = (uint8_t)(crc & 0xFFu);
            crcBuf[1] = (uint8_t)((crc >> 8) & 0xFFu);
            crcBuf[2] = (uint8_t)((crc >> 16) & 0xFFu);
            crcBuf[3] = (uint8_t)((crc >> 24) & 0xFFu);
            [buf appendBytes:crcBuf length:4];
        }
    }
    TTIOTransportReader *reader = [[TTIOTransportReader alloc] initWithData:buf];
    return [reader writeTtioToPath:outputPath error:error];
}

// ---------------------------------------------------------------- callbacks

- (void)_onEstablished
{
    _connectionEstablished = YES;
}

- (NSString *)_takePendingQuery
{
    if (!_queryPending) return nil;
    _queryPending = NO;
    return _queryJSON;
}

- (void)_onReceiveFragment:(const void *)bytes
                     length:(size_t)len
                      first:(BOOL)first
                      final:(BOOL)final
{
    if (first) [_pendingFrame setLength:0];
    if (bytes && len > 0) [_pendingFrame appendBytes:bytes length:len];
    if (final) {
        [self _onFrame:_pendingFrame];
        [_pendingFrame setLength:0];
    }
}

- (void)_onFrame:(NSData *)raw
{
    if (raw.length < TTIOTransportHeaderSize) {
        _protocolError = [NSError errorWithDomain:TTIOTransportErrorDomain
                                               code:TTIOTransportErrorTruncated
                                           userInfo:@{NSLocalizedDescriptionKey:
                           @"server frame shorter than packet header"}];
        _connectionClosed = YES;
        return;
    }
    const uint8_t *bytes = (const uint8_t *)raw.bytes;
    NSError *err = nil;
    TTIOTransportPacketHeader *header =
        [TTIOTransportPacketHeader decodeFromBytes:bytes length:raw.length error:&err];
    if (!header) {
        _protocolError = err;
        _connectionClosed = YES;
        return;
    }
    NSUInteger consumed = TTIOTransportHeaderSize + header.payloadLength;
    if (raw.length < consumed) {
        _protocolError = [NSError errorWithDomain:TTIOTransportErrorDomain
                                               code:TTIOTransportErrorTruncated
                                           userInfo:@{NSLocalizedDescriptionKey:
                           @"server frame truncated vs payload_length"}];
        _connectionClosed = YES;
        return;
    }
    NSData *payload = [NSData dataWithBytes:bytes + TTIOTransportHeaderSize
                                      length:header.payloadLength];

    if (header.flags & TTIOTransportPacketFlagHasChecksum) {
        if (raw.length < consumed + 4) {
            _protocolError = [NSError errorWithDomain:TTIOTransportErrorDomain
                                                   code:TTIOTransportErrorTruncated
                                               userInfo:@{NSLocalizedDescriptionKey:
                               @"server frame missing CRC-32C"}];
            _connectionClosed = YES;
            return;
        }
        uint32_t expected = (uint32_t)bytes[consumed]
                           | ((uint32_t)bytes[consumed + 1] << 8)
                           | ((uint32_t)bytes[consumed + 2] << 16)
                           | ((uint32_t)bytes[consumed + 3] << 24);
        uint32_t actual = TTIOTransportCRC32C((const uint8_t *)payload.bytes,
                                                payload.length);
        if (expected != actual) {
            _protocolError = [NSError errorWithDomain:TTIOTransportErrorDomain
                                                   code:TTIOTransportErrorChecksumFailed
                                               userInfo:@{NSLocalizedDescriptionKey:
                               @"CRC-32C mismatch on streamed packet"}];
            _connectionClosed = YES;
            return;
        }
    }

    TTIOTransportPacketRecord *rec =
        [[TTIOTransportPacketRecord alloc] initWithHeader:header payload:payload];
    [_packets addObject:rec];
    if (header.packetType == TTIOTransportPacketEndOfStream) {
        _sawEndOfStream = YES;
    }
}

- (void)_onConnectionError:(NSString *)message
{
    _protocolError = [NSError errorWithDomain:TTIOTransportErrorDomain
                                           code:TTIOTransportErrorUnexpectedPayload
                                       userInfo:@{NSLocalizedDescriptionKey:
                       [NSString stringWithFormat:@"websocket connect failed: %@", message]}];
    _connectionClosed = YES;
}

- (void)_onClosed
{
    _connectionClosed = YES;
}

@end
