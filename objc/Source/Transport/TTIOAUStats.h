/*
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
#ifndef TTIO_AU_STATS_H
#define TTIO_AU_STATS_H

#import <Foundation/Foundation.h>
#import "TTIOAccessUnit.h"

NS_ASSUME_NONNULL_BEGIN

/**
 * <p><em>Inherits From:</em> NSObject</p>
 * <p><em>Conforms To:</em> NSObject (NSObject)</p>
 * <p><em>Declared In:</em> Transport/TTIOAUStats.h</p>
 *
 * <p>Per-AccessUnit summary statistics — derivable from an
 * AccessUnit without decoding any signal-channel payload. Used by
 * the workbench server's <code>stats-only</code> and
 * <code>stats-with-payload</code> download modes to give clients a
 * lightweight per-AU descriptor.</p>
 *
 * <p>JSON wire layout (sorted keys, two-decimal doubles fixed by
 * <code>NSJSONWritingSortedKeys</code> +
 * <code>+JSONStringForAccessUnit:auSequence:</code>):</p>
 *
 * <pre>
 *  {
 *    "au_sequence": 12,
 *    "spectrum_class": 5,
 *    "ms_level": 0,
 *    "polarity": 2,
 *    "retention_time": 0.0,
 *    "precursor_mz": 0.0,
 *    "precursor_charge": 0,
 *    "ion_mobility": 0.0,
 *    "base_peak_intensity": 0.0,
 *    "channel_count": 3,
 *    "total_elements": 3072,
 *    "payload_bytes": 12288,
 *    "chromosome": "chr3",
 *    "position": 12345,
 *    "mapping_quality": 60,
 *    "flags": 0
 *  }
 * </pre>
 *
 * <p>Image-pixel fields (<code>pixel_x</code>, <code>pixel_y</code>,
 * <code>pixel_z</code>) appear only when
 * <code>spectrum_class == 4</code>. Genomic fields
 * (<code>chromosome</code>, <code>position</code>,
 * <code>mapping_quality</code>, <code>flags</code>) appear only
 * when <code>spectrum_class == 5</code>. All other fields are
 * always present.</p>
 *
 * <p><strong>Cross-language equivalents:</strong><br/>
 * Python: <code>ttio.transport.stats.AUStats</code><br/>
 * Java:
 * <code>global.thalion.ttio.transport.AUStats</code></p>
 */
@interface TTIOAUStats : NSObject

/** Sequence number of this AU within the stream. Provided by the
 *  caller (encoder/server knows the AU index). */
@property (nonatomic, readonly) uint32_t auSequence;

@property (nonatomic, readonly) uint8_t  spectrumClass;
@property (nonatomic, readonly) uint8_t  msLevel;
@property (nonatomic, readonly) uint8_t  polarity;
@property (nonatomic, readonly) double   retentionTime;
@property (nonatomic, readonly) double   precursorMz;
@property (nonatomic, readonly) uint8_t  precursorCharge;
@property (nonatomic, readonly) double   ionMobility;
@property (nonatomic, readonly) double   basePeakIntensity;

/** Number of signal channels. */
@property (nonatomic, readonly) uint32_t channelCount;

/** Sum of channel <code>nElements</code> across every channel. */
@property (nonatomic, readonly) uint64_t totalElements;

/** Sum of channel <code>data.length</code> across every channel. */
@property (nonatomic, readonly) uint64_t payloadBytes;

/** GenomicRead suffix fields. Set only when
 *  <code>spectrumClass == 5</code>; <code>nil</code> /
 *  <code>0</code> otherwise. */
@property (nonatomic, readonly, copy, nullable) NSString *chromosome;
@property (nonatomic, readonly) int64_t  position;
@property (nonatomic, readonly) uint8_t  mappingQuality;
@property (nonatomic, readonly) uint16_t flags;

/** MSImagePixel coordinate fields. Set only when
 *  <code>spectrumClass == 4</code>. */
@property (nonatomic, readonly) uint32_t pixelX;
@property (nonatomic, readonly) uint32_t pixelY;
@property (nonatomic, readonly) uint32_t pixelZ;

/** Builds a stats record from an AccessUnit + its sequence number.
 *  Pure projection: never decodes channel payload, never allocates
 *  per-element. O(channels). */
+ (instancetype)statsForAccessUnit:(TTIOAccessUnit *)au
                        auSequence:(uint32_t)auSequence;

/** Serialises to the JSON dict form documented above. Pure value
 *  type. Caller wraps in <code>NSJSONSerialization</code> with
 *  <code>NSJSONWritingSortedKeys</code> for byte-stable output. */
- (NSDictionary<NSString *, id> *)JSONDictionary;

/** Convenience: serialises to a UTF-8 NSString of the JSON dict
 *  with sorted keys (byte-stable across runs and platforms). */
+ (NSString *)JSONStringForAccessUnit:(TTIOAccessUnit *)au
                            auSequence:(uint32_t)auSequence;

@end

NS_ASSUME_NONNULL_END

#endif
