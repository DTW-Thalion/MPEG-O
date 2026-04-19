/*
 * MPGOMzTabWriter — mzTab exporter (v0.9+).
 *
 * Reverses MPGOMzTabReader: takes identifications + quantifications
 * and emits a mzTab file. Supports both proteomics (1.0, PSH/PSM +
 * PRH/PRT sections) and metabolomics (2.0.0-M, SMH/SML) dialects.
 *
 * Cross-language equivalents:
 *   Python: mpeg_o.exporters.mztab
 *   Java:   com.dtwthalion.mpgo.exporters.MzTabWriter
 *
 * SPDX-License-Identifier: Apache-2.0
 */
#import <Foundation/Foundation.h>

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
@end


@interface MPGOMzTabWriter : NSObject

/** Write mzTab text to @p path. */
+ (nullable MPGOMzTabWriteResult *)writeToPath:(NSString *)path
                                identifications:(nullable NSArray<MPGOIdentification *> *)idents
                                quantifications:(nullable NSArray<MPGOQuantification *> *)quants
                                         version:(NSString *)version
                                           title:(nullable NSString *)title
                                    description:(nullable NSString *)description
                                          error:(NSError * _Nullable * _Nullable)error;

@end

NS_ASSUME_NONNULL_END
