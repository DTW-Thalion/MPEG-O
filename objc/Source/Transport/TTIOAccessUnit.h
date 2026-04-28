/*
 * TTIOAccessUnit — v0.10 M67 transport-layer Access Unit value class.
 *
 * One spectrum as a transport-format packet payload. Carries filter
 * keys (RT, MS level, polarity, precursor m/z, ion mobility, base peak
 * intensity) followed by N signal channels.
 *
 * Cross-language equivalents:
 *   Python: ttio.transport.packets.AccessUnit
 *   Java:   global.thalion.ttio.transport.AccessUnit
 *
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
#ifndef TTIO_ACCESS_UNIT_H
#define TTIO_ACCESS_UNIT_H

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/** One signal channel inside an TTIOAccessUnit. */
@interface TTIOTransportChannelData : NSObject

@property (nonatomic, readonly, copy) NSString *name;
@property (nonatomic, readonly) uint8_t precision;    // TTIOPrecision
@property (nonatomic, readonly) uint8_t compression;  // TTIOCompression
@property (nonatomic, readonly) uint32_t nElements;
@property (nonatomic, readonly, strong) NSData *data;  // encoded bytes

- (instancetype)initWithName:(NSString *)name
                   precision:(uint8_t)precision
                 compression:(uint8_t)compression
                   nElements:(uint32_t)nElements
                        data:(NSData *)data;

/** Append this channel's wire bytes onto ``buf``. */
- (void)appendToBuffer:(NSMutableData *)buf;

/** Decode one channel starting at ``offset``; on return, ``*offset``
 *  is advanced past the channel. Returns nil on truncation. */
+ (nullable instancetype)decodeFromBytes:(const uint8_t *)bytes
                                   length:(NSUInteger)length
                                   offset:(NSUInteger *)offset;

@end


/**
 * Transport-layer Access Unit: one spectrum as a transport payload.
 *
 * ``spectrumClass`` wire values:
 *   0 = MassSpectrum, 1 = NMRSpectrum, 2 = NMR2D,
 *   3 = FID, 4 = MSImagePixel, 5 = GenomicRead
 *
 * ``polarity`` wire values (differs from TTIOPolarity which uses -1
 * for negative; the wire uses nonneg only):
 *   0 = positive, 1 = negative, 2 = unknown
 */
@interface TTIOAccessUnit : NSObject

@property (nonatomic, readonly) uint8_t spectrumClass;
@property (nonatomic, readonly) uint8_t acquisitionMode;
@property (nonatomic, readonly) uint8_t msLevel;
@property (nonatomic, readonly) uint8_t polarity;
@property (nonatomic, readonly) double retentionTime;
@property (nonatomic, readonly) double precursorMz;
@property (nonatomic, readonly) uint8_t precursorCharge;
@property (nonatomic, readonly) double ionMobility;
@property (nonatomic, readonly) double basePeakIntensity;
@property (nonatomic, readonly, copy) NSArray<TTIOTransportChannelData *> *channels;

// MSImagePixel extension (written only when spectrumClass == 4).
@property (nonatomic, readonly) uint32_t pixelX;
@property (nonatomic, readonly) uint32_t pixelY;
@property (nonatomic, readonly) uint32_t pixelZ;

// GenomicRead extension (written only when spectrumClass == 5). M89.1.
// Wire layout (transport-spec §4.3.4): chromosome (uint16-len-prefixed
// UTF-8) + position (i64 LE) + mappingQuality (u8) + flags (u16 LE).
// position is signed to match BAM's -1 unmapped sentinel.
@property (nonatomic, readonly, copy) NSString *chromosome;
@property (nonatomic, readonly) int64_t position;
@property (nonatomic, readonly) uint8_t mappingQuality;
@property (nonatomic, readonly) uint16_t flags;
// M90.9: mate extension fields. Optional on the wire — when absent
// (M89.1 file or empty AU) they default to BAM unmapped sentinels
// (-1 matePosition, 0 templateLength). Wire layout: appended after
// the M89.1 fixed suffix as int64 matePosition + int32 templateLength
// (12 bytes total).
@property (nonatomic, readonly) int64_t matePosition;
@property (nonatomic, readonly) int32_t templateLength;

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
                               pixelZ:(uint32_t)pixelZ;

/** M89.1 initialiser including the GenomicRead suffix fields.
 *  Delegates to the M90.9 designated initialiser with
 *  matePosition=-1, templateLength=0. */
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
                                  flags:(uint16_t)flags;

/** M90.9 designated initialiser including the mate extension fields
 *  (matePosition + templateLength). Older initialisers delegate here
 *  with matePosition=-1, templateLength=0. */
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
                       templateLength:(int32_t)templateLength;

- (NSData *)encode;

+ (nullable instancetype)decodeFromBytes:(const uint8_t *)bytes
                                   length:(NSUInteger)length
                                    error:(NSError * _Nullable *)error;

@end

NS_ASSUME_NONNULL_END

#endif
