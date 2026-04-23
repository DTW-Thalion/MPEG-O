/*
 * MPGOMzTabWriter — mzTab exporter (v0.9+).
 *
 * Reverses MPGOMzTabReader: takes identifications + quantifications
 * (plus optional features, M78) and emits a mzTab file. Supports both
 * proteomics (1.0, PSH/PSM + PRH/PRT + PEH/PEP sections) and
 * metabolomics (2.0.0-M, SMH/SML + SFH/SMF + SEH/SME) dialects.
 *
 * Cross-language equivalents:
 *   Python: mpeg_o.exporters.mztab
 *   Java:   com.dtwthalion.mpgo.exporters.MzTabWriter
 *
 * SPDX-License-Identifier: Apache-2.0
 */
#import <Foundation/Foundation.h>

@class MPGOFeature;
@class MPGOIdentification;
@class MPGOQuantification;
@class MPGOProvenanceRecord;

NS_ASSUME_NONNULL_BEGIN

@interface MPGOMzTabWriteResult : NSObject
@property (nonatomic, readonly, copy) NSString *path;
@property (nonatomic, readonly, copy) NSString *version;
@property (nonatomic, readonly) NSUInteger nPSMRows;
@property (nonatomic, readonly) NSUInteger nPRTRows;
@property (nonatomic, readonly) NSUInteger nSMLRows;
@property (nonatomic, readonly) NSUInteger nPEPRows;
@property (nonatomic, readonly) NSUInteger nSMFRows;
@property (nonatomic, readonly) NSUInteger nSMERows;
@end


@interface MPGOMzTabWriter : NSObject

/** Backwards-compat — writes without features. */
+ (nullable MPGOMzTabWriteResult *)writeToPath:(NSString *)path
                                identifications:(nullable NSArray<MPGOIdentification *> *)idents
                                quantifications:(nullable NSArray<MPGOQuantification *> *)quants
                                         version:(NSString *)version
                                           title:(nullable NSString *)title
                                    description:(nullable NSString *)description
                                          error:(NSError * _Nullable * _Nullable)error;

/** Features-aware writer (M78). */
+ (nullable MPGOMzTabWriteResult *)writeToPath:(NSString *)path
                                identifications:(nullable NSArray<MPGOIdentification *> *)idents
                                quantifications:(nullable NSArray<MPGOQuantification *> *)quants
                                        features:(nullable NSArray<MPGOFeature *> *)features
                                         version:(NSString *)version
                                           title:(nullable NSString *)title
                                    description:(nullable NSString *)description
                                          error:(NSError * _Nullable * _Nullable)error;

@end

NS_ASSUME_NONNULL_END
