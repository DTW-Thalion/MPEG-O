/*
 * TTIOTransportIngest.m
 * TTI-O Objective-C Implementation
 *
 * Class:         TTIOTransportIngest
 * Declared In:   Transport/TTIOTransportIngest.h
 *
 * Implementation: rolling NSMutableData buffer + a tight parser loop
 * that consumes packets as they become complete. Validation mirrors
 * TTIOTransportReader.m's logic, but each packet is emitted to the
 * delegate as soon as its bytes land instead of being held for an
 * end-of-stream return.
 *
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
#import "TTIOTransportIngest.h"

@interface TTIOTransportIngest ()
@property (nonatomic, strong) NSMutableData *buffer;
@property (nonatomic, assign) uint32_t lastAUSequence;
@property (nonatomic, assign) BOOL sawStreamHeader;
@end

@implementation TTIOTransportIngest

- (instancetype)init
{
    self = [super init];
    if (self) {
        _buffer = [NSMutableData data];
        _packetCount = 0;
        _bufferedBytes = 0;
        _isFinished = NO;
        _lastAUSequence = 0;
        _sawStreamHeader = NO;
    }
    return self;
}

#pragma mark - Helpers (must match TTIOTransportReader.m byte order)

static inline uint32_t readU32LE(const uint8_t *b)
{
    return (uint32_t)b[0]
         | ((uint32_t)b[1] << 8)
         | ((uint32_t)b[2] << 16)
         | ((uint32_t)b[3] << 24);
}

- (NSError *)errorWithCode:(TTIOTransportErrorCode)code message:(NSString *)msg
{
    return [NSError errorWithDomain:TTIOTransportErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: msg}];
}

- (void)moveToFailedStateWithError:(NSError *)error
{
    _isFinished = YES;
    _buffer = [NSMutableData data];
    _bufferedBytes = 0;
    if ([self.delegate respondsToSelector:@selector(ingest:didFailWithError:)]) {
        [self.delegate ingest:self didFailWithError:error];
    }
}

#pragma mark - Feed

- (BOOL)feedData:(NSData *)data error:(NSError **)error
{
    return [self feedBytes:data.bytes length:data.length error:error];
}

- (BOOL)feedBytes:(const void *)bytes
           length:(NSUInteger)length
            error:(NSError **)error
{
    if (_isFinished) {
        NSError *err = [self errorWithCode:TTIOTransportErrorTruncated
                                   message:@"feed on finished ingest"];
        if (error) *error = err;
        return NO;
    }
    if (length == 0) return YES;

    [_buffer appendBytes:bytes length:length];
    _bufferedBytes = _buffer.length;
    return [self drainBufferWithError:error];
}

#pragma mark - Drain (parse complete packets out of _buffer)

- (BOOL)drainBufferWithError:(NSError **)error
{
    while (_buffer.length >= TTIOTransportHeaderSize) {
        const uint8_t *hdrPtr = (const uint8_t *)_buffer.bytes;

        // Decode the 24-byte header. TTIOTransportPacketHeader's own
        // decoder validates magic + version; we trust its result here
        // because the same library produces the packets.
        NSError *hdrErr = nil;
        TTIOTransportPacketHeader *hdr =
            [TTIOTransportPacketHeader decodeFromBytes:hdrPtr
                                                length:TTIOTransportHeaderSize
                                                 error:&hdrErr];
        if (!hdr) {
            if (error) *error = hdrErr ?: [self errorWithCode:TTIOTransportErrorBadMagic
                                                      message:@"header decode failed"];
            [self moveToFailedStateWithError:*error];
            return NO;
        }

        // First packet MUST be a StreamHeader. Subsequent packets
        // before the StreamHeader is seen are rejected — same rule
        // as TTIOTransportReader.
        if (!_sawStreamHeader && hdr.packetType != TTIOTransportPacketStreamHeader) {
            NSError *err = [self errorWithCode:TTIOTransportErrorMissingStreamHeader
                                       message:@"first packet must be StreamHeader"];
            if (error) *error = err;
            [self moveToFailedStateWithError:err];
            return NO;
        }

        uint32_t payloadLen = hdr.payloadLength;
        BOOL hasCRC = (hdr.flags & TTIOTransportPacketFlagHasChecksum) != 0;
        NSUInteger trailing = hasCRC ? 4 : 0;
        NSUInteger needed = TTIOTransportHeaderSize + payloadLen + trailing;

        if (_buffer.length < needed) {
            // Wait for more bytes.
            return YES;
        }

        // Payload bytes (independent copy so the buffer can recycle).
        NSData *payload = [_buffer subdataWithRange:NSMakeRange(
            TTIOTransportHeaderSize, payloadLen)];

        // CRC validation (mirrors TTIOTransportReader.m's logic).
        if (hasCRC) {
            const uint8_t *crcBytes = (const uint8_t *)_buffer.bytes
                                    + TTIOTransportHeaderSize + payloadLen;
            uint32_t advertisedCRC = readU32LE(crcBytes);
            uint32_t computedCRC = TTIOTransportCRC32C(
                (const uint8_t *)payload.bytes, payload.length);
            if (advertisedCRC != computedCRC) {
                NSError *err = [self errorWithCode:TTIOTransportErrorChecksumFailed
                                           message:[NSString stringWithFormat:
                                               @"CRC32C mismatch on packet type 0x%02x "
                                               @"(advertised 0x%08x, computed 0x%08x)",
                                               (unsigned)hdr.packetType,
                                               advertisedCRC, computedCRC]];
                if (error) *error = err;
                [self moveToFailedStateWithError:err];
                return NO;
            }
        }

        // AU-sequence monotonicity check (only on AccessUnit packets).
        if (hdr.packetType == TTIOTransportPacketAccessUnit) {
            if (_packetCount > 0 && hdr.auSequence <= _lastAUSequence) {
                NSError *err = [self errorWithCode:TTIOTransportErrorNonMonotonicAU
                                           message:[NSString stringWithFormat:
                                               @"AU sequence regressed: got %u, "
                                               @"last seen %u", hdr.auSequence,
                                               _lastAUSequence]];
                if (error) *error = err;
                [self moveToFailedStateWithError:err];
                return NO;
            }
            _lastAUSequence = hdr.auSequence;
        }

        if (hdr.packetType == TTIOTransportPacketStreamHeader) {
            _sawStreamHeader = YES;
        }

        // Emit + advance buffer.
        TTIOTransportPacketRecord *record =
            [[TTIOTransportPacketRecord alloc] initWithHeader:hdr payload:payload];
        _packetCount++;

        // Slide the buffer forward. NSMutableData -replaceBytesInRange:
        // with a zero-length insertion deletes the consumed prefix in
        // amortised O(1) since GNUstep moves the tail pointer rather
        // than memmoving on every call.
        [_buffer replaceBytesInRange:NSMakeRange(0, needed)
                           withBytes:NULL
                              length:0];
        _bufferedBytes = _buffer.length;

        if ([self.delegate respondsToSelector:@selector(ingest:didReceivePacket:)]) {
            [self.delegate ingest:self didReceivePacket:record];
        }

        if (hdr.packetType == TTIOTransportPacketEndOfStream) {
            _isFinished = YES;
            if ([self.delegate respondsToSelector:@selector(ingestDidReceiveEndOfStream:)]) {
                [self.delegate ingestDidReceiveEndOfStream:self];
            }
            // Tolerate trailing bytes after EndOfStream — some
            // producers pad. We just don't parse them.
            _buffer = [NSMutableData data];
            _bufferedBytes = 0;
            return YES;
        }
    }
    return YES;
}

#pragma mark - Finish

- (BOOL)finishWithError:(NSError **)error
{
    if (_isFinished) return YES;
    if (_buffer.length == 0) {
        // Producer signalled EOF with nothing pending — that's
        // still a truncated stream because EndOfStream never landed.
        NSError *err = [self errorWithCode:TTIOTransportErrorTruncated
                                   message:@"stream ended without EndOfStream packet"];
        if (error) *error = err;
        [self moveToFailedStateWithError:err];
        return NO;
    }
    NSError *err = [self errorWithCode:TTIOTransportErrorTruncated
                               message:[NSString stringWithFormat:
                                   @"stream ended with %lu bytes buffered "
                                   @"(partial packet)", (unsigned long)_buffer.length]];
    if (error) *error = err;
    [self moveToFailedStateWithError:err];
    return NO;
}

@end
