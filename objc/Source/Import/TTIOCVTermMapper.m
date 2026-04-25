/*
 * Licensed under the Apache License, Version 2.0.
 * See LICENSE-IMPORT-EXPORT in the repository root.
 *
 * SPDX-License-Identifier: Apache-2.0
 */

#import "TTIOCVTermMapper.h"

@implementation TTIOCVTermMapper

+ (TTIOPrecision)precisionForAccession:(NSString *)acc
{
    if ([acc isEqualToString:@"MS:1000521"]) return TTIOPrecisionFloat32;
    if ([acc isEqualToString:@"MS:1000523"]) return TTIOPrecisionFloat64;
    if ([acc isEqualToString:@"MS:1000519"]) return TTIOPrecisionInt32;
    if ([acc isEqualToString:@"MS:1000522"]) return TTIOPrecisionInt64;
    return TTIOPrecisionFloat64;
}

+ (TTIOCompression)compressionForAccession:(NSString *)acc
{
    if ([acc isEqualToString:@"MS:1000574"]) return TTIOCompressionZlib;
    if ([acc isEqualToString:@"MS:1000576"]) return TTIOCompressionNone;
    return TTIOCompressionNone;
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

#pragma mark - M74: MS/MS activation-method accessions

+ (TTIOActivationMethod)activationMethodForAccession:(NSString *)acc
{
    if ([acc isEqualToString:@"MS:1000133"]) return TTIOActivationMethodCID;
    if ([acc isEqualToString:@"MS:1000422"]) return TTIOActivationMethodHCD;
    if ([acc isEqualToString:@"MS:1000598"]) return TTIOActivationMethodETD;
    if ([acc isEqualToString:@"MS:1000250"]) return TTIOActivationMethodECD;
    if ([acc isEqualToString:@"MS:1003246"]) return TTIOActivationMethodUVPD;
    if ([acc isEqualToString:@"MS:1003181"]) return TTIOActivationMethodEThcD;
    return TTIOActivationMethodNone;
}

+ (BOOL)isActivationMethodAccession:(NSString *)acc
{
    return [acc isEqualToString:@"MS:1000133"]
        || [acc isEqualToString:@"MS:1000422"]
        || [acc isEqualToString:@"MS:1000598"]
        || [acc isEqualToString:@"MS:1000250"]
        || [acc isEqualToString:@"MS:1003246"]
        || [acc isEqualToString:@"MS:1003181"];
}

+ (NSString *)activationAccessionForMethod:(TTIOActivationMethod)method
{
    switch (method) {
        case TTIOActivationMethodCID:   return @"MS:1000133";
        case TTIOActivationMethodHCD:   return @"MS:1000422";
        case TTIOActivationMethodETD:   return @"MS:1000598";
        case TTIOActivationMethodECD:   return @"MS:1000250";
        case TTIOActivationMethodUVPD:  return @"MS:1003246";
        case TTIOActivationMethodEThcD: return @"MS:1003181";
        case TTIOActivationMethodNone:  return nil;
    }
    return nil;
}

+ (NSString *)activationNameForMethod:(TTIOActivationMethod)method
{
    switch (method) {
        case TTIOActivationMethodCID:   return @"collision-induced dissociation";
        case TTIOActivationMethodHCD:   return @"beam-type collision-induced dissociation";
        case TTIOActivationMethodETD:   return @"electron transfer dissociation";
        case TTIOActivationMethodECD:   return @"electron capture dissociation";
        case TTIOActivationMethodUVPD:  return @"ultraviolet photodissociation";
        case TTIOActivationMethodEThcD: return @"electron transfer/higher-energy collision dissociation";
        case TTIOActivationMethodNone:  return nil;
    }
    return nil;
}

#pragma mark - M74: isolation-window cvParam accessions

+ (BOOL)isIsolationWindowTargetMzAccession:(NSString *)acc
{ return [acc isEqualToString:@"MS:1000827"]; }

+ (BOOL)isIsolationWindowLowerOffsetAccession:(NSString *)acc
{ return [acc isEqualToString:@"MS:1000828"]; }

+ (BOOL)isIsolationWindowUpperOffsetAccession:(NSString *)acc
{ return [acc isEqualToString:@"MS:1000829"]; }

#pragma mark - nmrCV (Milestone 13)

+ (BOOL)isSpectrometerFrequencyAccession:(NSString *)acc
{ return [acc isEqualToString:@"NMR:1000001"]; }

+ (BOOL)isNucleusAccession:(NSString *)acc
{ return [acc isEqualToString:@"NMR:1000002"]; }

+ (BOOL)isNumberOfScansAccession:(NSString *)acc
{ return [acc isEqualToString:@"NMR:1000003"]; }

+ (BOOL)isDwellTimeAccession:(NSString *)acc
{ return [acc isEqualToString:@"NMR:1000004"]; }

+ (BOOL)isSweepWidthAccession:(NSString *)acc
{ return [acc isEqualToString:@"NMR:1400014"]; }

+ (TTIOCVParam *)cvParamFromAccession:(NSString *)acc
                                 name:(NSString *)name
                                value:(NSString *)value
                          ontologyRef:(NSString *)ontRef
                                 unit:(NSString *)unitAcc
{
    return [TTIOCVParam paramWithOntologyRef:(ontRef ?: @"MS")
                                   accession:acc
                                        name:(name ?: @"")
                                       value:value
                                        unit:unitAcc];
}

@end
