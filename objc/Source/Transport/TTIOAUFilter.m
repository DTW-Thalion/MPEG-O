/*
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
#import "TTIOAUFilter.h"

@implementation TTIOAUFilter

+ (instancetype)emptyFilter { return [[self alloc] init]; }

+ (instancetype)filterFromQueryJSON:(NSString *)json
{
    if (!json.length) return [self emptyFilter];
    NSError *err = nil;
    NSData *data = [json dataUsingEncoding:NSUTF8StringEncoding];
    id root = [NSJSONSerialization JSONObjectWithData:data options:0 error:&err];
    if (![root isKindOfClass:[NSDictionary class]]) return [self emptyFilter];
    id filters = ((NSDictionary *)root)[@"filters"];
    if (![filters isKindOfClass:[NSDictionary class]]) return [self emptyFilter];
    NSDictionary *f = (NSDictionary *)filters;
    TTIOAUFilter *out = [[TTIOAUFilter alloc] init];
    out->_rtMin         = [f[@"rt_min"] isKindOfClass:[NSNumber class]] ? f[@"rt_min"] : nil;
    out->_rtMax         = [f[@"rt_max"] isKindOfClass:[NSNumber class]] ? f[@"rt_max"] : nil;
    out->_msLevel       = [f[@"ms_level"] isKindOfClass:[NSNumber class]] ? f[@"ms_level"] : nil;
    out->_precursorMzMin = [f[@"precursor_mz_min"] isKindOfClass:[NSNumber class]]
                            ? f[@"precursor_mz_min"] : nil;
    out->_precursorMzMax = [f[@"precursor_mz_max"] isKindOfClass:[NSNumber class]]
                            ? f[@"precursor_mz_max"] : nil;
    out->_polarity      = [f[@"polarity"] isKindOfClass:[NSNumber class]] ? f[@"polarity"] : nil;
    out->_datasetId     = [f[@"dataset_id"] isKindOfClass:[NSNumber class]] ? f[@"dataset_id"] : nil;
    out->_maxAU         = [f[@"max_au"] isKindOfClass:[NSNumber class]] ? f[@"max_au"] : nil;
    // M89.3: genomic predicates. chromosome is a string; position_min /
    // position_max are integers (NSJSONSerialization yields NSNumber
    // for both ints and floats, so we accept either).
    out->_chromosome    = [f[@"chromosome"] isKindOfClass:[NSString class]] ? f[@"chromosome"] : nil;
    out->_positionMin   = [f[@"position_min"] isKindOfClass:[NSNumber class]]
                            ? f[@"position_min"] : nil;
    out->_positionMax   = [f[@"position_max"] isKindOfClass:[NSNumber class]]
                            ? f[@"position_max"] : nil;
    return out;
}

- (BOOL)matches:(TTIOAccessUnit *)au datasetId:(uint16_t)datasetId
{
    if (_datasetId && datasetId != _datasetId.unsignedIntValue) return NO;
    if (_rtMin && au.retentionTime < _rtMin.doubleValue) return NO;
    if (_rtMax && au.retentionTime > _rtMax.doubleValue) return NO;
    if (_msLevel && au.msLevel != _msLevel.intValue) return NO;
    if (_precursorMzMin && au.precursorMz < _precursorMzMin.doubleValue) return NO;
    if (_precursorMzMax && au.precursorMz > _precursorMzMax.doubleValue) return NO;
    if (_polarity && au.polarity != _polarity.intValue) return NO;
    // M89.3: genomic predicates. A chromosome predicate excludes any
    // AU whose chromosome differs (MS AUs default to "" and are
    // therefore excluded). Position predicates first require
    // spectrumClass==5 — MS AUs have no notion of position.
    if (_chromosome && ![au.chromosome isEqualToString:_chromosome]) return NO;
    if (_positionMin || _positionMax) {
        if (au.spectrumClass != 5) return NO;
        if (_positionMin && au.position < _positionMin.longLongValue) return NO;
        if (_positionMax && au.position > _positionMax.longLongValue) return NO;
    }
    return YES;
}

@end
