/*
 * TTIOMzTabWriter — mzTab exporter (v0.9+).
 *
 * Reverses TTIOMzTabReader: takes identifications + quantifications
 * (plus optional features, M78) and emits a mzTab file. Supports both
 * proteomics (1.0, PSH/PSM + PRH/PRT + PEH/PEP sections) and
 * metabolomics (2.0.0-M, SMH/SML + SFH/SMF + SEH/SME) dialects.
 *
 * Cross-language equivalents:
 *   Python: ttio.exporters.mztab
 *   Java:   com.dtwthalion.ttio.exporters.MzTabWriter
 *
 * SPDX-License-Identifier: Apache-2.0
 */
#import <Foundation/Foundation.h>

@class TTIOFeature;
@class TTIOIdentification;
@class TTIOQuantification;
@class TTIOProvenanceRecord;

NS_ASSUME_NONNULL_BEGIN

@interface TTIOMzTabWriteResult : NSObject
@property (nonatomic, readonly, copy) NSString *path;
@property (nonatomic, readonly, copy) NSString *version;
@property (nonatomic, readonly) NSUInteger nPSMRows;
@property (nonatomic, readonly) NSUInteger nPRTRows;
@property (nonatomic, readonly) NSUInteger nSMLRows;
@property (nonatomic, readonly) NSUInteger nPEPRows;
@property (nonatomic, readonly) NSUInteger nSMFRows;
@property (nonatomic, readonly) NSUInteger nSMERows;
@end


@interface TTIOMzTabWriter : NSObject

/** Backwards-compat — writes without features. */
+ (nullable TTIOMzTabWriteResult *)writeToPath:(NSString *)path
                                identifications:(nullable NSArray<TTIOIdentification *> *)idents
                                quantifications:(nullable NSArray<TTIOQuantification *> *)quants
                                         version:(NSString *)version
                                           title:(nullable NSString *)title
                                    description:(nullable NSString *)description
                                          error:(NSError * _Nullable * _Nullable)error;

/** Features-aware writer (M78). */
+ (nullable TTIOMzTabWriteResult *)writeToPath:(NSString *)path
                                identifications:(nullable NSArray<TTIOIdentification *> *)idents
                                quantifications:(nullable NSArray<TTIOQuantification *> *)quants
                                        features:(nullable NSArray<TTIOFeature *> *)features
                                         version:(NSString *)version
                                           title:(nullable NSString *)title
                                    description:(nullable NSString *)description
                                          error:(NSError * _Nullable * _Nullable)error;

@end

NS_ASSUME_NONNULL_END
