/*
 * Licensed under the Apache License, Version 2.0.
 * SPDX-License-Identifier: Apache-2.0
 */
#import <Foundation/Foundation.h>

@class TTIOFeature;
@class TTIOIdentification;
@class TTIOQuantification;
@class TTIOProvenanceRecord;

NS_ASSUME_NONNULL_BEGIN

/**
 * <p><em>Inherits From:</em> NSObject</p>
 * <p><em>Conforms To:</em> NSObject (NSObject)</p>
 * <p><em>Declared In:</em> Export/TTIOMzTabWriter.h</p>
 *
 * <p>Pure value object describing a successful mzTab write: output
 * path, mzTab version, and per-section row counts.</p>
 */
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


/**
 * <p><em>Inherits From:</em> NSObject</p>
 * <p><em>Conforms To:</em> NSObject (NSObject)</p>
 * <p><em>Declared In:</em> Export/TTIOMzTabWriter.h</p>
 *
 * <p>mzTab exporter. Reverses <code>TTIOMzTabReader</code>: takes
 * identifications + quantifications (plus optional features) and
 * emits a mzTab file. Supports both proteomics
 * (<code>1.0</code>, PSH/PSM + PRH/PRT + PEH/PEP sections) and
 * metabolomics (<code>2.0.0-M</code>, SMH/SML + SFH/SMF + SEH/SME)
 * dialects.</p>
 *
 * <p><strong>API status:</strong> Provisional.</p>
 *
 * <p><strong>Cross-language equivalents:</strong><br/>
 * Python: <code>ttio.exporters.mztab</code><br/>
 * Java: <code>global.thalion.ttio.exporters.MzTabWriter</code></p>
 */
@interface TTIOMzTabWriter : NSObject

/**
 * Backwards-compatible writer that omits features.
 *
 * @param path        Output mzTab path.
 * @param idents      Identifications to emit (may be nil).
 * @param quants      Quantifications to emit (may be nil).
 * @param version     mzTab version (<code>"1.0"</code> or
 *                    <code>"2.0.0-M"</code>).
 * @param title       Optional dataset title.
 * @param description Optional dataset description.
 * @param error       Out-parameter populated on failure.
 * @return Write result on success, or <code>nil</code> on failure.
 */
+ (nullable TTIOMzTabWriteResult *)writeToPath:(NSString *)path
                                identifications:(nullable NSArray<TTIOIdentification *> *)idents
                                quantifications:(nullable NSArray<TTIOQuantification *> *)quants
                                         version:(NSString *)version
                                           title:(nullable NSString *)title
                                    description:(nullable NSString *)description
                                          error:(NSError * _Nullable * _Nullable)error;

/**
 * Features-aware writer.
 *
 * @param path        Output mzTab path.
 * @param idents      Identifications to emit (may be nil).
 * @param quants      Quantifications to emit (may be nil).
 * @param features    Features to emit (may be nil).
 * @param version     mzTab version.
 * @param title       Optional dataset title.
 * @param description Optional dataset description.
 * @param error       Out-parameter populated on failure.
 * @return Write result on success, or <code>nil</code> on failure.
 */
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
