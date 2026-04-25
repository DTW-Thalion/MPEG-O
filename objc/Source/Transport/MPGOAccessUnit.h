/*
 * MPGOAccessUnit — v0.10 M67 transport-layer Access Unit value class.
 *
 * One spectrum as a transport-format packet payload. Carries filter
 * keys (RT, MS level, polarity, precursor m/z, ion mobility, base peak
 * intensity) followed by N signal channels.
 *
 * Cross-language equivalents:
 *   Python: mpeg_o.transport.packets.AccessUnit
 *   Java:   com.dtwthalion.mpgo.transport.AccessUnit
 *
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
#ifndef MPGO_ACCESS_UNIT_H
#define MPGO_ACCESS_UNIT_H

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/** One signal channel inside an MPGOAccessUnit. */
@interface MPGOTransportChannelData : NSObject

@property (nonatomic, readonly, copy) NSString *name;
@property (nonatomic, readonly) uint8_t precision;    // MPGOPrecision
@property (nonatomic, readonly) uint8_t compression;  // MPGOCompression
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
 * ``polarity`` wire values (differs from MPGOPolarity which uses -1
 * for negative; the wire uses nonneg only):
 *   0 = positive, 1 = negative, 2 = unknown
 */
@interface MPGOAccessUnit : NSObject

@property (nonatomic, readonly) uint8_t spectrumClass;
@property (nonatomic, readonly) uint8_t acquisitionMode;
@property (nonatomic, readonly) uint8_t msLevel;
@property (nonatomic, readonly) uint8_t polarity;
@property (nonatomic, readonly) double retentionTime;
@property (nonatomic, readonly) double precursorMz;
@property (nonatomic, readonly) uint8_t precursorCharge;
@property (nonatomic, readonly) double ionMobility;
@property (nonatomic, readonly) double basePeakIntensity;
@property (nonatomic, readonly, copy) NSArray<MPGOTransportChannelData *> *channels;

// MSImagePixel extension (written only when spectrumClass == 4).
@property (nonatomic, readonly) uint32_t pixelX;
@property (nonatomic, readonly) uint32_t pixelY;
@property (nonatomic, readonly) uint32_t pixelZ;

- (instancetype)initWithSpectrumClass:(uint8_t)spectrumClass
                      acquisitionMode:(uint8_t)acquisitionMode
                              msLevel:(uint8_t)msLevel
                             polarity:(uint8_t)polarity
                        retentionTime:(double)retentionTime
                          precursorMz:(double)precursorMz
                      precursorCharge:(uint8_t)precursorCharge
                          ionMobility:(double)ionMobility
                    basePeakIntensity:(double)basePeakIntensity
                             channels:(NSArray<MPGOTransportChannelData *> *)channels
                               pixelX:(uint32_t)pixelX
                               pixelY:(uint32_t)pixelY
                               pixelZ:(uint32_t)pixelZ;

- (NSData *)encode;

+ (nullable instancetype)decodeFromBytes:(const uint8_t *)bytes
                                   length:(NSUInteger)length
                                    error:(NSError * _Nullable *)error;

@end

NS_ASSUME_NONNULL_END

#endif
