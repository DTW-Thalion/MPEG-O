#ifndef MPGO_FEATURE_FLAGS_H
#define MPGO_FEATURE_FLAGS_H

#import <Foundation/Foundation.h>

@class MPGOHDF5File;
@class MPGOHDF5Group;

/**
 * Versioning and feature-flag utility for MPGO file format v0.2+.
 *
 * Every file written by v0.2+ carries two root-group attributes:
 *
 *     @mpeg_o_format_version = "1.1"   (major.minor string)
 *     @mpeg_o_features       = JSON array of feature strings
 *
 * v0.1 files have @mpeg_o_version = "1.0.0" instead and no
 * @mpeg_o_features — readers detect the old format by the absence of
 * the feature-flags attribute and fall back to the v0.1 JSON paths.
 *
 * Features without an `opt_` prefix are required: a reader must
 * refuse a file that names a required feature it does not support.
 * Features with `opt_` are informational — readers may skip them.
 */
@interface MPGOFeatureFlags : NSObject

#pragma mark - Standard feature strings

+ (NSString *)featureBaseV1;                 // @"base_v1"
+ (NSString *)featureCompoundIdentifications;// @"compound_identifications"
+ (NSString *)featureCompoundQuantifications;// @"compound_quantifications"
+ (NSString *)featureCompoundProvenance;     // @"compound_provenance"
+ (NSString *)featureCompoundHeaders;        // @"opt_compound_headers"
+ (NSString *)featureDatasetEncryption;      // @"opt_dataset_encryption"
+ (NSString *)featureNative2DNMR;            // @"opt_native_2d_nmr"
+ (NSString *)featureNativeMSImageCube;      // @"opt_native_msimage_cube"
+ (NSString *)featureDigitalSignatures;      // @"opt_digital_signatures"
+ (NSString *)featureCompoundPerRunProvenance; // @"compound_per_run_provenance" (M17)

#pragma mark - Read

+ (NSString *)formatVersionForRoot:(MPGOHDF5Group *)root;

+ (NSArray<NSString *> *)featuresForRoot:(MPGOHDF5Group *)root;

+ (BOOL)root:(MPGOHDF5Group *)root supportsFeature:(NSString *)feature;

/** A v0.1 file has neither @mpeg_o_format_version nor
 *  @mpeg_o_features; it only has @mpeg_o_version. */
+ (BOOL)isLegacyV1File:(MPGOHDF5Group *)root;

#pragma mark - Write

/** Write format version + feature list to the root group. */
+ (BOOL)writeFormatVersion:(NSString *)version
                  features:(NSArray<NSString *> *)features
                    toRoot:(MPGOHDF5Group *)root
                     error:(NSError **)error;

@end

#endif /* MPGO_FEATURE_FLAGS_H */
