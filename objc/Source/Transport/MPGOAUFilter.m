/*
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
#import "MPGOAUFilter.h"

@implementation MPGOAUFilter

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
    MPGOAUFilter *out = [[MPGOAUFilter alloc] init];
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
    return out;
}

- (BOOL)matches:(MPGOAccessUnit *)au datasetId:(uint16_t)datasetId
{
    if (_datasetId && datasetId != _datasetId.unsignedIntValue) return NO;
    if (_rtMin && au.retentionTime < _rtMin.doubleValue) return NO;
    if (_rtMax && au.retentionTime > _rtMax.doubleValue) return NO;
    if (_msLevel && au.msLevel != _msLevel.intValue) return NO;
    if (_precursorMzMin && au.precursorMz < _precursorMzMin.doubleValue) return NO;
    if (_precursorMzMax && au.precursorMz > _precursorMzMax.doubleValue) return NO;
    if (_polarity && au.polarity != _polarity.intValue) return NO;
    return YES;
}

@end
