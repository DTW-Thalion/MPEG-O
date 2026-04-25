#ifndef TTIO_FEATURE_FLAGS_H
#define TTIO_FEATURE_FLAGS_H

#import <Foundation/Foundation.h>

@class TTIOHDF5File;
@class TTIOHDF5Group;

/**
 * Versioning and feature-flag utility for TTIO file format v0.2+.
 *
 * Every file written by v0.2+ carries two root-group attributes:
 *
 *     @ttio_format_version = "1.1"   (major.minor string)
 *     @ttio_features       = JSON array of feature strings
 *
 * v0.1 files have @ttio_version = "1.0.0" instead and no
 * @ttio_features — readers detect the old format by the absence of
 * the feature-flags attribute and fall back to the v0.1 JSON paths.
 *
 * Features without an `opt_` prefix are required: a reader must
 * refuse a file that names a required feature it does not support.
 * Features with `opt_` are informational — readers may skip them.
 */
@interface TTIOFeatureFlags : NSObject

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
+ (NSString *)featureCanonicalSignatures;      // @"opt_canonical_signatures" (M18)
+ (NSString *)featureKeyRotation;              // @"opt_key_rotation" (M25)
+ (NSString *)featureAnonymized;               // @"opt_anonymized" (M28)
+ (NSString *)featurePQCPreview;               // @"opt_pqc_preview" (v0.8 M49)
+ (NSString *)featureMS2ActivationDetail;      // @"opt_ms2_activation_detail" (v0.12 M74)

#pragma mark - Read

+ (NSString *)formatVersionForRoot:(TTIOHDF5Group *)root;

+ (NSArray<NSString *> *)featuresForRoot:(TTIOHDF5Group *)root;

+ (BOOL)root:(TTIOHDF5Group *)root supportsFeature:(NSString *)feature;

/** A v0.1 file has neither @ttio_format_version nor
 *  @ttio_features; it only has @ttio_version. */
+ (BOOL)isLegacyV1File:(TTIOHDF5Group *)root;

#pragma mark - Write

/** Write format version + feature list to the root group. */
+ (BOOL)writeFormatVersion:(NSString *)version
                  features:(NSArray<NSString *> *)features
                    toRoot:(TTIOHDF5Group *)root
                     error:(NSError **)error;

@end

#endif /* TTIO_FEATURE_FLAGS_H */
