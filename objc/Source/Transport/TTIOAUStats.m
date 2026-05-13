/*
 * TTIOAUStats.m
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
#import "TTIOAUStats.h"
#import "Core/TTIOPortability.h"

#define TTIO_SPECTRUM_CLASS_MS_IMAGE_PIXEL 4
#define TTIO_SPECTRUM_CLASS_GENOMIC_READ   5

@implementation TTIOAUStats

- (instancetype)initWithAccessUnit:(TTIOAccessUnit *)au
                        auSequence:(uint32_t)auSequence
{
    self = [super init];
    if (!self) return nil;

    _auSequence        = auSequence;
    _spectrumClass     = au.spectrumClass;
    _msLevel           = au.msLevel;
    _polarity          = au.polarity;
    _retentionTime     = au.retentionTime;
    _precursorMz       = au.precursorMz;
    _precursorCharge   = au.precursorCharge;
    _ionMobility       = au.ionMobility;
    _basePeakIntensity = au.basePeakIntensity;

    uint64_t totalElements = 0;
    uint64_t payloadBytes  = 0;
    for (TTIOTransportChannelData *ch in au.channels) {
        totalElements += (uint64_t)ch.nElements;
        payloadBytes  += (uint64_t)ch.data.length;
    }
    _channelCount  = (uint32_t)au.channels.count;
    _totalElements = totalElements;
    _payloadBytes  = payloadBytes;

    if (au.spectrumClass == TTIO_SPECTRUM_CLASS_GENOMIC_READ) {
        _chromosome     = [au.chromosome copy];
        _position       = au.position;
        _mappingQuality = au.mappingQuality;
        _flags          = au.flags;
    } else {
        _chromosome     = nil;
        _position       = 0;
        _mappingQuality = 0;
        _flags          = 0;
    }

    if (au.spectrumClass == TTIO_SPECTRUM_CLASS_MS_IMAGE_PIXEL) {
        _pixelX = au.pixelX;
        _pixelY = au.pixelY;
        _pixelZ = au.pixelZ;
    } else {
        _pixelX = 0;
        _pixelY = 0;
        _pixelZ = 0;
    }

    return self;
}

+ (instancetype)statsForAccessUnit:(TTIOAccessUnit *)au
                        auSequence:(uint32_t)auSequence
{
    return [[self alloc] initWithAccessUnit:au auSequence:auSequence];
}

- (NSDictionary<NSString *, id> *)JSONDictionary
{
    NSMutableDictionary<NSString *, id> *d = [NSMutableDictionary dictionary];
    d[@"au_sequence"]         = @(_auSequence);
    d[@"spectrum_class"]      = @(_spectrumClass);
    d[@"ms_level"]            = @(_msLevel);
    d[@"polarity"]            = @(_polarity);
    d[@"retention_time"]      = @(_retentionTime);
    d[@"precursor_mz"]        = @(_precursorMz);
    d[@"precursor_charge"]    = @(_precursorCharge);
    d[@"ion_mobility"]        = @(_ionMobility);
    d[@"base_peak_intensity"] = @(_basePeakIntensity);
    d[@"channel_count"]       = @(_channelCount);
    d[@"total_elements"]      = @(_totalElements);
    d[@"payload_bytes"]       = @(_payloadBytes);
    if (_spectrumClass == TTIO_SPECTRUM_CLASS_GENOMIC_READ) {
        d[@"chromosome"]      = _chromosome ?: @"";
        d[@"position"]        = @(_position);
        d[@"mapping_quality"] = @(_mappingQuality);
        d[@"flags"]           = @(_flags);
    }
    if (_spectrumClass == TTIO_SPECTRUM_CLASS_MS_IMAGE_PIXEL) {
        d[@"pixel_x"] = @(_pixelX);
        d[@"pixel_y"] = @(_pixelY);
        d[@"pixel_z"] = @(_pixelZ);
    }
    return d;
}

+ (NSString *)JSONStringForAccessUnit:(TTIOAccessUnit *)au
                            auSequence:(uint32_t)auSequence
{
    TTIOAUStats *s = [self statsForAccessUnit:au auSequence:auSequence];
    NSData *data = [NSJSONSerialization
        dataWithJSONObject:[s JSONDictionary]
                   options:TTIO_JSON_SORTED_KEYS
                     error:NULL];
    if (!data) return @"{}";
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}

@end
