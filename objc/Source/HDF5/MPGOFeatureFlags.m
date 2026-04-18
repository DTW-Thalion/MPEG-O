#import "MPGOFeatureFlags.h"
#import "MPGOHDF5Group.h"

@implementation MPGOFeatureFlags

+ (NSString *)featureBaseV1                  { return @"base_v1"; }
+ (NSString *)featureCompoundIdentifications { return @"compound_identifications"; }
+ (NSString *)featureCompoundQuantifications { return @"compound_quantifications"; }
+ (NSString *)featureCompoundProvenance      { return @"compound_provenance"; }
+ (NSString *)featureCompoundHeaders         { return @"opt_compound_headers"; }
+ (NSString *)featureDatasetEncryption       { return @"opt_dataset_encryption"; }
+ (NSString *)featureNative2DNMR             { return @"opt_native_2d_nmr"; }
+ (NSString *)featureNativeMSImageCube       { return @"opt_native_msimage_cube"; }
+ (NSString *)featureDigitalSignatures       { return @"opt_digital_signatures"; }
+ (NSString *)featureCompoundPerRunProvenance { return @"compound_per_run_provenance"; }
+ (NSString *)featureCanonicalSignatures     { return @"opt_canonical_signatures"; }
+ (NSString *)featureKeyRotation             { return @"opt_key_rotation"; }
+ (NSString *)featureAnonymized              { return @"opt_anonymized"; }
+ (NSString *)featurePQCPreview              { return @"opt_pqc_preview"; }

+ (NSString *)formatVersionForRoot:(MPGOHDF5Group *)root
{
    if ([root hasAttributeNamed:@"mpeg_o_format_version"]) {
        return [root stringAttributeNamed:@"mpeg_o_format_version" error:NULL];
    }
    if ([root hasAttributeNamed:@"mpeg_o_version"]) {
        return [root stringAttributeNamed:@"mpeg_o_version" error:NULL];
    }
    return nil;
}

+ (NSArray<NSString *> *)featuresForRoot:(MPGOHDF5Group *)root
{
    if (![root hasAttributeNamed:@"mpeg_o_features"]) return @[];
    NSString *json = [root stringAttributeNamed:@"mpeg_o_features" error:NULL];
    if (json.length == 0) return @[];
    NSData *data = [json dataUsingEncoding:NSUTF8StringEncoding];
    NSError *err = nil;
    id parsed = [NSJSONSerialization JSONObjectWithData:data options:0 error:&err];
    if (![parsed isKindOfClass:[NSArray class]]) return @[];
    return (NSArray *)parsed;
}

+ (BOOL)root:(MPGOHDF5Group *)root supportsFeature:(NSString *)feature
{
    NSArray *features = [self featuresForRoot:root];
    return [features containsObject:feature];
}

+ (BOOL)isLegacyV1File:(MPGOHDF5Group *)root
{
    return ![root hasAttributeNamed:@"mpeg_o_features"];
}

+ (BOOL)writeFormatVersion:(NSString *)version
                  features:(NSArray<NSString *> *)features
                    toRoot:(MPGOHDF5Group *)root
                     error:(NSError **)error
{
    if (![root setStringAttribute:@"mpeg_o_format_version"
                            value:version
                            error:error]) return NO;

    NSError *jErr = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:features
                                                    options:0
                                                      error:&jErr];
    if (!data) {
        if (error) *error = jErr;
        return NO;
    }
    NSString *json = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    return [root setStringAttribute:@"mpeg_o_features" value:json error:error];
}

@end
