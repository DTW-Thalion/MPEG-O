/*
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
#import "TTIOAccessUnit.h"
#import "TTIOTransportPacket.h"
#import <string.h>

// ---------------------------------------------------------------- LE helpers

static inline void writeU16(uint8_t *b, uint16_t v)
{
    b[0] = (uint8_t)(v & 0xFFu);
    b[1] = (uint8_t)((v >> 8) & 0xFFu);
}

static inline void writeU32(uint8_t *b, uint32_t v)
{
    b[0] = (uint8_t)(v & 0xFFu);
    b[1] = (uint8_t)((v >> 8) & 0xFFu);
    b[2] = (uint8_t)((v >> 16) & 0xFFu);
    b[3] = (uint8_t)((v >> 24) & 0xFFu);
}

static inline void writeF64(uint8_t *b, double v)
{
    uint64_t bits;
    memcpy(&bits, &v, 8);
    for (int i = 0; i < 8; i++) b[i] = (uint8_t)((bits >> (8 * i)) & 0xFFu);
}

static inline uint16_t readU16(const uint8_t *b)
{
    return (uint16_t)((uint32_t)b[0] | ((uint32_t)b[1] << 8));
}

static inline uint32_t readU32(const uint8_t *b)
{
    return (uint32_t)b[0]
         | ((uint32_t)b[1] << 8)
         | ((uint32_t)b[2] << 16)
         | ((uint32_t)b[3] << 24);
}

static inline double readF64(const uint8_t *b)
{
    uint64_t bits = 0;
    for (int i = 0; i < 8; i++) bits |= ((uint64_t)b[i]) << (8 * i);
    double v;
    memcpy(&v, &bits, 8);
    return v;
}

static inline void writeI64(uint8_t *b, int64_t v)
{
    uint64_t u = (uint64_t)v;
    for (int i = 0; i < 8; i++) b[i] = (uint8_t)((u >> (8 * i)) & 0xFFu);
}

static inline int64_t readI64(const uint8_t *b)
{
    uint64_t u = 0;
    for (int i = 0; i < 8; i++) u |= ((uint64_t)b[i]) << (8 * i);
    return (int64_t)u;
}

static inline void writeI32(uint8_t *b, int32_t v)
{
    uint32_t u = (uint32_t)v;
    b[0] = (uint8_t)(u & 0xFFu);
    b[1] = (uint8_t)((u >> 8) & 0xFFu);
    b[2] = (uint8_t)((u >> 16) & 0xFFu);
    b[3] = (uint8_t)((u >> 24) & 0xFFu);
}

static inline int32_t readI32(const uint8_t *b)
{
    uint32_t u = (uint32_t)b[0]
               | ((uint32_t)b[1] << 8)
               | ((uint32_t)b[2] << 16)
               | ((uint32_t)b[3] << 24);
    return (int32_t)u;
}

// ---------------------------------------------------------------- Channel

@implementation TTIOTransportChannelData

- (instancetype)initWithName:(NSString *)name
                   precision:(uint8_t)precision
                 compression:(uint8_t)compression
                   nElements:(uint32_t)nElements
                        data:(NSData *)data
{
    if ((self = [super init])) {
        _name = [name copy];
        _precision = precision;
        _compression = compression;
        _nElements = nElements;
        _data = [data copy];
    }
    return self;
}

- (void)appendToBuffer:(NSMutableData *)buf
{
    NSData *nameBytes = [_name dataUsingEncoding:NSUTF8StringEncoding];
    uint8_t header[2];
    writeU16(header, (uint16_t)nameBytes.length);
    [buf appendBytes:header length:2];
    [buf appendData:nameBytes];
    uint8_t tail[10];
    tail[0] = _precision;
    tail[1] = _compression;
    writeU32(&tail[2], _nElements);
    writeU32(&tail[6], (uint32_t)_data.length);
    [buf appendBytes:tail length:10];
    [buf appendData:_data];
}

+ (instancetype)decodeFromBytes:(const uint8_t *)bytes
                          length:(NSUInteger)length
                          offset:(NSUInteger *)offset
{
    NSUInteger off = *offset;
    if (off + 2 > length) return nil;
    uint16_t nameLen = readU16(&bytes[off]);
    off += 2;
    if (off + nameLen > length) return nil;
    NSString *name = [[NSString alloc] initWithBytes:&bytes[off]
                                               length:nameLen
                                             encoding:NSUTF8StringEncoding];
    off += nameLen;
    if (off + 10 > length) return nil;
    uint8_t precision = bytes[off];
    uint8_t compression = bytes[off + 1];
    uint32_t nElements = readU32(&bytes[off + 2]);
    uint32_t dataLen = readU32(&bytes[off + 6]);
    off += 10;
    if (off + dataLen > length) return nil;
    NSData *data = [NSData dataWithBytes:&bytes[off] length:dataLen];
    off += dataLen;
    *offset = off;
    return [[self alloc] initWithName:(name ?: @"")
                             precision:precision
                           compression:compression
                             nElements:nElements
                                  data:data];
}

@end

// ---------------------------------------------------------------- AccessUnit

@implementation TTIOAccessUnit

- (instancetype)initWithSpectrumClass:(uint8_t)spectrumClass
                      acquisitionMode:(uint8_t)acquisitionMode
                              msLevel:(uint8_t)msLevel
                             polarity:(uint8_t)polarity
                        retentionTime:(double)retentionTime
                          precursorMz:(double)precursorMz
                      precursorCharge:(uint8_t)precursorCharge
                          ionMobility:(double)ionMobility
                    basePeakIntensity:(double)basePeakIntensity
                             channels:(NSArray<TTIOTransportChannelData *> *)channels
                               pixelX:(uint32_t)pixelX
                               pixelY:(uint32_t)pixelY
                               pixelZ:(uint32_t)pixelZ
{
    return [self initWithSpectrumClass:spectrumClass
                       acquisitionMode:acquisitionMode
                               msLevel:msLevel
                              polarity:polarity
                         retentionTime:retentionTime
                           precursorMz:precursorMz
                       precursorCharge:precursorCharge
                           ionMobility:ionMobility
                     basePeakIntensity:basePeakIntensity
                              channels:channels
                                pixelX:pixelX
                                pixelY:pixelY
                                pixelZ:pixelZ
                            chromosome:@""
                              position:0
                        mappingQuality:0
                                 flags:0];
}

- (instancetype)initWithSpectrumClass:(uint8_t)spectrumClass
                      acquisitionMode:(uint8_t)acquisitionMode
                              msLevel:(uint8_t)msLevel
                             polarity:(uint8_t)polarity
                        retentionTime:(double)retentionTime
                          precursorMz:(double)precursorMz
                      precursorCharge:(uint8_t)precursorCharge
                          ionMobility:(double)ionMobility
                    basePeakIntensity:(double)basePeakIntensity
                             channels:(NSArray<TTIOTransportChannelData *> *)channels
                               pixelX:(uint32_t)pixelX
                               pixelY:(uint32_t)pixelY
                               pixelZ:(uint32_t)pixelZ
                            chromosome:(NSString *)chromosome
                              position:(int64_t)position
                       mappingQuality:(uint8_t)mappingQuality
                                  flags:(uint16_t)flags
{
    return [self initWithSpectrumClass:spectrumClass
                       acquisitionMode:acquisitionMode
                               msLevel:msLevel
                              polarity:polarity
                         retentionTime:retentionTime
                           precursorMz:precursorMz
                       precursorCharge:precursorCharge
                           ionMobility:ionMobility
                     basePeakIntensity:basePeakIntensity
                              channels:channels
                                pixelX:pixelX
                                pixelY:pixelY
                                pixelZ:pixelZ
                            chromosome:chromosome
                              position:position
                        mappingQuality:mappingQuality
                                 flags:flags
                          matePosition:-1
                        templateLength:0];
}

- (instancetype)initWithSpectrumClass:(uint8_t)spectrumClass
                      acquisitionMode:(uint8_t)acquisitionMode
                              msLevel:(uint8_t)msLevel
                             polarity:(uint8_t)polarity
                        retentionTime:(double)retentionTime
                          precursorMz:(double)precursorMz
                      precursorCharge:(uint8_t)precursorCharge
                          ionMobility:(double)ionMobility
                    basePeakIntensity:(double)basePeakIntensity
                             channels:(NSArray<TTIOTransportChannelData *> *)channels
                               pixelX:(uint32_t)pixelX
                               pixelY:(uint32_t)pixelY
                               pixelZ:(uint32_t)pixelZ
                            chromosome:(NSString *)chromosome
                              position:(int64_t)position
                       mappingQuality:(uint8_t)mappingQuality
                                  flags:(uint16_t)flags
                          matePosition:(int64_t)matePosition
                        templateLength:(int32_t)templateLength
{
    if ((self = [super init])) {
        _spectrumClass = spectrumClass;
        _acquisitionMode = acquisitionMode;
        _msLevel = msLevel;
        _polarity = polarity;
        _retentionTime = retentionTime;
        _precursorMz = precursorMz;
        _precursorCharge = precursorCharge;
        _ionMobility = ionMobility;
        _basePeakIntensity = basePeakIntensity;
        _channels = [channels copy];
        _pixelX = pixelX;
        _pixelY = pixelY;
        _pixelZ = pixelZ;
        _chromosome = [(chromosome ?: @"") copy];
        _position = position;
        _mappingQuality = mappingQuality;
        _flags = flags;
        _matePosition = matePosition;
        _templateLength = templateLength;
    }
    return self;
}

- (NSData *)encode
{
    NSMutableData *buf = [NSMutableData dataWithCapacity:64];
    uint8_t head[38];
    head[0] = _spectrumClass;
    head[1] = _acquisitionMode;
    head[2] = _msLevel;
    head[3] = _polarity;
    writeF64(&head[4], _retentionTime);
    writeF64(&head[12], _precursorMz);
    head[20] = _precursorCharge;
    writeF64(&head[21], _ionMobility);
    writeF64(&head[29], _basePeakIntensity);
    head[37] = (uint8_t)(_channels.count & 0xFFu);
    [buf appendBytes:head length:38];
    for (TTIOTransportChannelData *ch in _channels) {
        [ch appendToBuffer:buf];
    }
    if (_spectrumClass == 4) {
        uint8_t pix[12];
        writeU32(&pix[0], _pixelX);
        writeU32(&pix[4], _pixelY);
        writeU32(&pix[8], _pixelZ);
        [buf appendBytes:pix length:12];
    } else if (_spectrumClass == 5) {
        // M89.1: GenomicRead suffix — chromosome (uint16-len-prefixed
        // UTF-8) then position (i64 LE) + mapq (u8) + flags (u16 LE).
        NSData *chrom = [(_chromosome ?: @"") dataUsingEncoding:NSUTF8StringEncoding];
        uint8_t lenBytes[2];
        writeU16(lenBytes, (uint16_t)chrom.length);
        [buf appendBytes:lenBytes length:2];
        [buf appendData:chrom];
        uint8_t suffix[11];
        writeI64(&suffix[0], _position);
        suffix[8] = _mappingQuality;
        writeU16(&suffix[9], _flags);
        [buf appendBytes:suffix length:11];
        // M90.9 mate extension — always emitted post-M90.9 so the
        // wire is uniform. Decoders treat the extension as optional
        // and default to -1 / 0 when absent (M89.1 fixtures).
        uint8_t mate[12];
        writeI64(&mate[0], _matePosition);
        writeI32(&mate[8], _templateLength);
        [buf appendBytes:mate length:12];
    }
    return buf;
}

+ (instancetype)decodeFromBytes:(const uint8_t *)bytes
                          length:(NSUInteger)length
                           error:(NSError **)error
{
    if (length < 38) {
        if (error) *error = [NSError errorWithDomain:TTIOTransportErrorDomain
                                                 code:TTIOTransportErrorTruncated
                                             userInfo:@{NSLocalizedDescriptionKey:
                             @"access unit payload too short"}];
        return nil;
    }
    uint8_t spectrumClass = bytes[0];
    uint8_t acquisitionMode = bytes[1];
    uint8_t msLevel = bytes[2];
    uint8_t polarity = bytes[3];
    double retentionTime = readF64(&bytes[4]);
    double precursorMz = readF64(&bytes[12]);
    uint8_t precursorCharge = bytes[20];
    double ionMobility = readF64(&bytes[21]);
    double basePeakIntensity = readF64(&bytes[29]);
    uint8_t nChannels = bytes[37];

    NSUInteger offset = 38;
    NSMutableArray<TTIOTransportChannelData *> *channels =
        [NSMutableArray arrayWithCapacity:nChannels];
    for (uint8_t i = 0; i < nChannels; i++) {
        TTIOTransportChannelData *ch =
            [TTIOTransportChannelData decodeFromBytes:bytes
                                                length:length
                                                offset:&offset];
        if (!ch) {
            if (error) *error = [NSError errorWithDomain:TTIOTransportErrorDomain
                                                     code:TTIOTransportErrorTruncated
                                                 userInfo:@{NSLocalizedDescriptionKey:
                                 @"truncated channel in access unit"}];
            return nil;
        }
        [channels addObject:ch];
    }

    uint32_t pixelX = 0, pixelY = 0, pixelZ = 0;
    NSString *chromosome = @"";
    int64_t position = 0;
    uint8_t mappingQuality = 0;
    uint16_t flagsField = 0;
    // M90.9 mate extension defaults — match the property defaults so
    // M89.1 AUs (which lack the extension) decode unchanged.
    int64_t matePosition = -1;
    int32_t templateLength = 0;
    if (spectrumClass == 4) {
        if (length - offset < 12) {
            if (error) *error = [NSError errorWithDomain:TTIOTransportErrorDomain
                                                     code:TTIOTransportErrorTruncated
                                                 userInfo:@{NSLocalizedDescriptionKey:
                                 @"MSImagePixel AU missing pixel coordinates"}];
            return nil;
        }
        pixelX = readU32(&bytes[offset]);
        pixelY = readU32(&bytes[offset + 4]);
        pixelZ = readU32(&bytes[offset + 8]);
    } else if (spectrumClass == 5) {
        // M89.1: GenomicRead suffix.
        if (length - offset < 2) {
            if (error) *error = [NSError errorWithDomain:TTIOTransportErrorDomain
                                                     code:TTIOTransportErrorTruncated
                                                 userInfo:@{NSLocalizedDescriptionKey:
                                 @"GenomicRead AU missing chromosome length prefix"}];
            return nil;
        }
        uint16_t chromLen = readU16(&bytes[offset]);
        offset += 2;
        if (length - offset < chromLen) {
            if (error) *error = [NSError errorWithDomain:TTIOTransportErrorDomain
                                                     code:TTIOTransportErrorTruncated
                                                 userInfo:@{NSLocalizedDescriptionKey:
                                 @"GenomicRead AU truncated chromosome bytes"}];
            return nil;
        }
        if (chromLen > 0) {
            chromosome = [[NSString alloc] initWithBytes:&bytes[offset]
                                                   length:chromLen
                                                 encoding:NSUTF8StringEncoding] ?: @"";
        }
        offset += chromLen;
        if (length - offset < 11) {
            if (error) *error = [NSError errorWithDomain:TTIOTransportErrorDomain
                                                     code:TTIOTransportErrorTruncated
                                                 userInfo:@{NSLocalizedDescriptionKey:
                                 @"GenomicRead AU missing position/mapq/flags suffix"}];
            return nil;
        }
        position = readI64(&bytes[offset]);
        mappingQuality = bytes[offset + 8];
        flagsField = readU16(&bytes[offset + 9]);
        offset += 11;
        // M90.9 mate extension — optional. M89.1 payloads end right
        // after flags; M90.9+ payloads carry 12 more bytes.
        if (length - offset >= 12) {
            matePosition = readI64(&bytes[offset]);
            templateLength = readI32(&bytes[offset + 8]);
            offset += 12;
        }
    }

    return [[self alloc] initWithSpectrumClass:spectrumClass
                               acquisitionMode:acquisitionMode
                                       msLevel:msLevel
                                      polarity:polarity
                                 retentionTime:retentionTime
                                   precursorMz:precursorMz
                               precursorCharge:precursorCharge
                                   ionMobility:ionMobility
                             basePeakIntensity:basePeakIntensity
                                      channels:channels
                                        pixelX:pixelX
                                        pixelY:pixelY
                                        pixelZ:pixelZ
                                    chromosome:chromosome
                                      position:position
                                mappingQuality:mappingQuality
                                         flags:flagsField
                                  matePosition:matePosition
                                templateLength:templateLength];
}

@end
