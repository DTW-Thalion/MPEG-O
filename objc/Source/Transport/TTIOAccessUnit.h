/*
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
#ifndef TTIO_ACCESS_UNIT_H
#define TTIO_ACCESS_UNIT_H

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/**
 * <p><em>Inherits From:</em> NSObject</p>
 * <p><em>Conforms To:</em> NSObject (NSObject)</p>
 * <p><em>Declared In:</em> Transport/TTIOAccessUnit.h</p>
 *
 * <p>One signal channel inside a <code>TTIOAccessUnit</code>:
 * channel name, precision, optional compression, element count, and
 * the encoded payload bytes.</p>
 */
@interface TTIOTransportChannelData : NSObject

@property (nonatomic, readonly, copy) NSString *name;
@property (nonatomic, readonly) uint8_t precision;    // TTIOPrecision
@property (nonatomic, readonly) uint8_t compression;  // TTIOCompression
@property (nonatomic, readonly) uint32_t nElements;
@property (nonatomic, readonly, strong) NSData *data;  // encoded bytes

/**
 * Designated initialiser.
 *
 * @param name          Channel name (e.g. ``mz``, ``intensity``).
 * @param precision     Element precision; mirrors ``TTIOPrecision``.
 * @param compression   Compression codec id; mirrors
 *                      ``TTIOCompression``. Zero means uncompressed.
 * @param nElements     Number of decoded elements the payload
 *                      encodes.
 * @param data          Encoded payload bytes. Treated as immutable.
 * @return An initialised channel value object.
 */
- (instancetype)initWithName:(NSString *)name
                   precision:(uint8_t)precision
                 compression:(uint8_t)compression
                   nElements:(uint32_t)nElements
                        data:(NSData *)data;

/**
 * Append this channel's wire bytes onto ``buf``.
 *
 * @param buf  Destination buffer. The channel header and payload
 *             are appended in-place; ``buf`` is grown as needed.
 */
- (void)appendToBuffer:(NSMutableData *)buf;

/**
 * Decode one channel starting at ``offset``.
 *
 * @param bytes    Pointer to the start of the enclosing AU payload.
 * @param length   Total bytes available at ``bytes``.
 * @param offset   In/out cursor. On entry, points at the channel's
 *                 first byte; on success, advanced past the channel.
 * @return The decoded channel, or ``nil`` if ``length - *offset`` is
 *         too small for the channel header or its payload.
 */
+ (nullable instancetype)decodeFromBytes:(const uint8_t *)bytes
                                   length:(NSUInteger)length
                                   offset:(NSUInteger *)offset;

@end


/**
 * <p><em>Inherits From:</em> NSObject</p>
 * <p><em>Conforms To:</em> NSObject (NSObject)</p>
 * <p><em>Declared In:</em> Transport/TTIOAccessUnit.h</p>
 *
 * <p>Transport-layer Access Unit: one spectrum (or one genomic read)
 * as a transport payload. Carries filter keys (RT, MS level,
 * polarity, precursor m/z, ion mobility, base-peak intensity)
 * followed by N signal channels.</p>
 *
 * <p><strong>spectrumClass</strong> wire values:</p>
 * <ul>
 *  <li>0 = MassSpectrum</li>
 *  <li>1 = NMRSpectrum</li>
 *  <li>2 = NMR2D</li>
 *  <li>3 = FID</li>
 *  <li>4 = MSImagePixel</li>
 *  <li>5 = GenomicRead</li>
 * </ul>
 *
 * <p><strong>polarity</strong> wire values (differs from
 * <code>TTIOPolarity</code> which uses <code>-1</code> for negative;
 * the wire uses non-negative only):</p>
 * <ul>
 *  <li>0 = positive</li>
 *  <li>1 = negative</li>
 *  <li>2 = unknown</li>
 * </ul>
 *
 * <p><strong>Cross-language equivalents:</strong><br/>
 * Python: <code>ttio.transport.packets.AccessUnit</code><br/>
 * Java:
 * <code>global.thalion.ttio.transport.AccessUnit</code></p>
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

// GenomicRead extension (written only when spectrumClass == 5).
// Wire layout (transport-spec §4.3.4): chromosome (uint16-len-prefixed
// UTF-8) + position (i64 LE) + mappingQuality (u8) + flags (u16 LE).
// position is signed to match BAM's -1 unmapped sentinel.
@property (nonatomic, readonly, copy) NSString *chromosome;
@property (nonatomic, readonly) int64_t position;
@property (nonatomic, readonly) uint8_t mappingQuality;
@property (nonatomic, readonly) uint16_t flags;
// Mate extension fields. Optional on the wire — when absent the
// values default to BAM unmapped sentinels (-1 matePosition,
// 0 templateLength). Wire layout: appended after the genomic fixed
// suffix as int64 matePosition + int32 templateLength (12 bytes).
@property (nonatomic, readonly) int64_t matePosition;
@property (nonatomic, readonly) int32_t templateLength;

/**
 * MS-only / NMR-only / MSImage initialiser. Delegates to the mate-
 * aware designated initialiser with empty genomic fields,
 * ``position = -1``, ``matePosition = -1``, and
 * ``templateLength = 0``.
 *
 * @param spectrumClass      Wire enum value (0 = MassSpectrum,
 *                           1 = NMRSpectrum, etc.).
 * @param acquisitionMode    Acquisition-mode tag.
 * @param msLevel            MS level (0 when not applicable).
 * @param polarity           Wire polarity value (0 / 1 / 2).
 * @param retentionTime      Retention time in seconds.
 * @param precursorMz        Precursor m/z (0 when not applicable).
 * @param precursorCharge    Precursor charge.
 * @param ionMobility        Ion mobility (0 when not applicable).
 * @param basePeakIntensity  Base-peak intensity (0 when not
 *                           applicable).
 * @param channels           Signal channels carried by the AU.
 * @param pixelX, pixelY, pixelZ  MSImage pixel coordinates;
 *                           ignored unless
 *                           ``spectrumClass == 4``.
 * @return An initialised AU.
 */
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

/** Genomic-aware initialiser including the GenomicRead suffix
 *  fields. Delegates to the designated initialiser with
 *  <code>matePosition = -1</code>,
 *  <code>templateLength = 0</code>. */
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

/** Designated initialiser including the mate extension fields
 *  (<code>matePosition</code> + <code>templateLength</code>). Older
 *  initialisers delegate here with
 *  <code>matePosition = -1</code>,
 *  <code>templateLength = 0</code>. */
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

/**
 * Serialise the AU to its on-wire byte form.
 *
 * @return Encoded payload bytes (excluding the enclosing packet
 *         header).
 */
- (NSData *)encode;

/**
 * Decode an AU payload from a raw byte buffer.
 *
 * @param bytes   Pointer to the AU payload (after the packet header).
 * @param length  Total bytes available at ``bytes``.
 * @param error   On failure, populated with an ``NSError`` in the
 *                ``TTIOTransportErrorDomain``. May be ``NULL``.
 * @return A decoded ``TTIOAccessUnit`` on success; ``nil`` on
 *         malformed input.
 */
+ (nullable instancetype)decodeFromBytes:(const uint8_t *)bytes
                                   length:(NSUInteger)length
                                    error:(NSError * _Nullable *)error;

@end

NS_ASSUME_NONNULL_END

#endif
