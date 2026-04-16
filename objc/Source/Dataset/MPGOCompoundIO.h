#ifndef MPGO_COMPOUND_IO_H
#define MPGO_COMPOUND_IO_H

#import <Foundation/Foundation.h>

@class MPGOHDF5Group;
@class MPGOIdentification;
@class MPGOQuantification;
@class MPGOProvenanceRecord;
@class MPGOSpectrumIndex;
@class MPGOCompoundField;

/**
 * Compound-type persistence helpers for MPEG-O v0.2+ on-disk format.
 *
 * These helpers write and read native HDF5 compound datasets that replace
 * the v0.1 JSON-encoded string attributes. v0.1 files (detected by the
 * absence of @mpeg_o_features on the root) are read via the old JSON path;
 * v0.2+ writers always emit compound datasets and tag the root with the
 * appropriate feature flag.
 *
 * All functions use variable-length C strings inside the compound records
 * so h5dump can visualize them directly and external tools that understand
 * compound types can introspect without a bespoke reader.
 */
@interface MPGOCompoundIO : NSObject

#pragma mark - Identifications

+ (BOOL)writeIdentifications:(NSArray<MPGOIdentification *> *)idents
                    intoGroup:(MPGOHDF5Group *)parent
                 datasetNamed:(NSString *)name
                        error:(NSError **)error;

+ (NSArray<MPGOIdentification *> *)readIdentificationsFromGroup:(MPGOHDF5Group *)parent
                                                    datasetNamed:(NSString *)name
                                                           error:(NSError **)error;

#pragma mark - Quantifications

+ (BOOL)writeQuantifications:(NSArray<MPGOQuantification *> *)quants
                    intoGroup:(MPGOHDF5Group *)parent
                 datasetNamed:(NSString *)name
                        error:(NSError **)error;

+ (NSArray<MPGOQuantification *> *)readQuantificationsFromGroup:(MPGOHDF5Group *)parent
                                                    datasetNamed:(NSString *)name
                                                           error:(NSError **)error;

#pragma mark - Provenance (dataset-level chain)

+ (BOOL)writeProvenance:(NSArray<MPGOProvenanceRecord *> *)records
               intoGroup:(MPGOHDF5Group *)parent
            datasetNamed:(NSString *)name
                   error:(NSError **)error;

+ (NSArray<MPGOProvenanceRecord *> *)readProvenanceFromGroup:(MPGOHDF5Group *)parent
                                                 datasetNamed:(NSString *)name
                                                        error:(NSError **)error;

#pragma mark - Spectrum index compound headers (write only, opt_compound_headers)

/** Writes a single compound `headers` dataset alongside the existing
 *  parallel 1-D datasets under `spectrum_index/`. Purely additive; read
 *  path still uses the parallel arrays. This dataset exists primarily
 *  for external tooling / h5dump readability. */
+ (BOOL)writeCompoundHeadersForIndex:(MPGOSpectrumIndex *)index
                            intoGroup:(MPGOHDF5Group *)parent
                                error:(NSError **)error;

/** Verify the compound headers dataset exists and returns row i as an
 *  NSDictionary {offset, length, retention_time, ms_level, polarity,
 *  precursor_mz, precursor_charge, base_peak_intensity}. Used only by
 *  tests; main query paths still use the parallel datasets. */
+ (NSDictionary *)readCompoundHeaderRow:(NSUInteger)row
                               fromGroup:(MPGOHDF5Group *)parent
                                   error:(NSError **)error;

#pragma mark - Generic schema-driven write/read (M39 provider adapter)

/** Write an array of rows (each NSDictionary keyed by field name)
 *  into a compound dataset with the given schema. */
+ (BOOL)writeGeneric:(NSArray<NSDictionary *> *)rows
            intoGroup:(MPGOHDF5Group *)parent
         datasetNamed:(NSString *)name
               fields:(NSArray<MPGOCompoundField *> *)fields
                error:(NSError **)error;

/** Read an existing compound dataset, returning rows as NSDictionary
 *  keyed by field name. */
+ (NSArray<NSDictionary *> *)readGenericFromGroup:(MPGOHDF5Group *)parent
                                       datasetNamed:(NSString *)name
                                             fields:(NSArray<MPGOCompoundField *> *)fields
                                              error:(NSError **)error;

@end

#endif /* MPGO_COMPOUND_IO_H */
