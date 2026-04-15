/*
 * Licensed under the Apache License, Version 2.0.
 * See LICENSE-IMPORT-EXPORT in the repository root.
 *
 * SPDX-License-Identifier: Apache-2.0
 */

#import "MPGOCVTermMapper.h"

@implementation MPGOCVTermMapper

+ (MPGOPrecision)precisionForAccession:(NSString *)acc
{
    if ([acc isEqualToString:@"MS:1000521"]) return MPGOPrecisionFloat32;
    if ([acc isEqualToString:@"MS:1000523"]) return MPGOPrecisionFloat64;
    if ([acc isEqualToString:@"MS:1000519"]) return MPGOPrecisionInt32;
    if ([acc isEqualToString:@"MS:1000522"]) return MPGOPrecisionInt64;
    return MPGOPrecisionFloat64;
}

+ (MPGOCompression)compressionForAccession:(NSString *)acc
{
    if ([acc isEqualToString:@"MS:1000574"]) return MPGOCompressionZlib;
    if ([acc isEqualToString:@"MS:1000576"]) return MPGOCompressionNone;
    return MPGOCompressionNone;
}

+ (NSString *)signalArrayNameForAccession:(NSString *)acc
{
    if ([acc isEqualToString:@"MS:1000514"]) return @"mz";
    if ([acc isEqualToString:@"MS:1000515"]) return @"intensity";
    if ([acc isEqualToString:@"MS:1000516"]) return @"charge";
    if ([acc isEqualToString:@"MS:1000517"]) return @"signal_to_noise";
    if ([acc isEqualToString:@"MS:1000595"]) return @"time";
    if ([acc isEqualToString:@"MS:1000617"]) return @"wavelength";
    if ([acc isEqualToString:@"MS:1000820"]) return @"ion_mobility";
    return nil;
}

+ (BOOL)isMSLevelAccession:(NSString *)acc
{ return [acc isEqualToString:@"MS:1000511"]; }

+ (BOOL)isPositivePolarityAccession:(NSString *)acc
{ return [acc isEqualToString:@"MS:1000130"]; }

+ (BOOL)isNegativePolarityAccession:(NSString *)acc
{ return [acc isEqualToString:@"MS:1000129"]; }

+ (BOOL)isScanWindowLowerAccession:(NSString *)acc
{ return [acc isEqualToString:@"MS:1000501"]; }

+ (BOOL)isScanWindowUpperAccession:(NSString *)acc
{ return [acc isEqualToString:@"MS:1000500"]; }

+ (BOOL)isTotalIonCurrentAccession:(NSString *)acc
{ return [acc isEqualToString:@"MS:1000285"]; }

+ (BOOL)isBasePeakMzAccession:(NSString *)acc
{ return [acc isEqualToString:@"MS:1000504"]; }

+ (BOOL)isBasePeakIntensityAccession:(NSString *)acc
{ return [acc isEqualToString:@"MS:1000505"]; }

+ (BOOL)isScanStartTimeAccession:(NSString *)acc
{ return [acc isEqualToString:@"MS:1000016"]; }

+ (BOOL)isSelectedIonMzAccession:(NSString *)acc
{ return [acc isEqualToString:@"MS:1000744"]; }

+ (BOOL)isChargeStateAccession:(NSString *)acc
{ return [acc isEqualToString:@"MS:1000041"]; }

+ (BOOL)isTotalIonChromatogramAccession:(NSString *)acc
{ return [acc isEqualToString:@"MS:1000235"]; }

+ (BOOL)isSelectedReactionMonitoringAccession:(NSString *)acc
{ return [acc isEqualToString:@"MS:1001473"]; }

+ (MPGOCVParam *)cvParamFromAccession:(NSString *)acc
                                 name:(NSString *)name
                                value:(NSString *)value
                          ontologyRef:(NSString *)ontRef
                                 unit:(NSString *)unitAcc
{
    return [MPGOCVParam paramWithOntologyRef:(ontRef ?: @"MS")
                                   accession:acc
                                        name:(name ?: @"")
                                       value:value
                                        unit:unitAcc];
}

@end
