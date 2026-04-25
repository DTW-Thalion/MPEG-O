#ifndef TTIO_COMPOUND_IO_H
#define TTIO_COMPOUND_IO_H

#import <Foundation/Foundation.h>

@class TTIOHDF5Group;
@class TTIOIdentification;
@class TTIOQuantification;
@class TTIOProvenanceRecord;
@class TTIOSpectrumIndex;
@class TTIOCompoundField;

/**
 * Compound-type persistence helpers for TTI-O v0.2+ on-disk format.
 *
 * These helpers write and read native HDF5 compound datasets that replace
 * the v0.1 JSON-encoded string attributes. v0.1 files (detected by the
 * absence of @ttio_features on the root) are read via the old JSON path;
 * v0.2+ writers always emit compound datasets and tag the root with the
 * appropriate feature flag.
 *
 * All functions use variable-length C strings inside the compound records
 * so h5dump can visualize them directly and external tools that understand
 * compound types can introspect without a bespoke reader.
 *
 * API status: Stable (internal helper).
 *
 * Cross-language equivalents:
 *   Python: ttio._hdf5_io (private helper module)
 *   Java:   com.dtwthalion.ttio.hdf5.Hdf5CompoundIO
 *
 * Each language exposes these differently due to HDF5 binding
 * shapes; see docs/api-review-v0.6.md for the documented stylistic
 * difference.
 */
@interface TTIOCompoundIO : NSObject

#pragma mark - Identifications

+ (BOOL)writeIdentifications:(NSArray<TTIOIdentification *> *)idents
                    intoGroup:(TTIOHDF5Group *)parent
                 datasetNamed:(NSString *)name
                        error:(NSError **)error;

+ (NSArray<TTIOIdentification *> *)readIdentificationsFromGroup:(TTIOHDF5Group *)parent
                                                    datasetNamed:(NSString *)name
                                                           error:(NSError **)error;

#pragma mark - Quantifications

+ (BOOL)writeQuantifications:(NSArray<TTIOQuantification *> *)quants
                    intoGroup:(TTIOHDF5Group *)parent
                 datasetNamed:(NSString *)name
                        error:(NSError **)error;

+ (NSArray<TTIOQuantification *> *)readQuantificationsFromGroup:(TTIOHDF5Group *)parent
                                                    datasetNamed:(NSString *)name
                                                           error:(NSError **)error;

#pragma mark - Provenance (dataset-level chain)

+ (BOOL)writeProvenance:(NSArray<TTIOProvenanceRecord *> *)records
               intoGroup:(TTIOHDF5Group *)parent
            datasetNamed:(NSString *)name
                   error:(NSError **)error;

+ (NSArray<TTIOProvenanceRecord *> *)readProvenanceFromGroup:(TTIOHDF5Group *)parent
                                                 datasetNamed:(NSString *)name
                                                        error:(NSError **)error;

#pragma mark - Spectrum index compound headers (write only, opt_compound_headers)

/** Writes a single compound `headers` dataset alongside the existing
 *  parallel 1-D datasets under `spectrum_index/`. Purely additive; read
 *  path still uses the parallel arrays. This dataset exists primarily
 *  for external tooling / h5dump readability. */
+ (BOOL)writeCompoundHeadersForIndex:(TTIOSpectrumIndex *)index
                            intoGroup:(TTIOHDF5Group *)parent
                                error:(NSError **)error;

/** Verify the compound headers dataset exists and returns row i as an
 *  NSDictionary {offset, length, retention_time, ms_level, polarity,
 *  precursor_mz, precursor_charge, base_peak_intensity}. Used only by
 *  tests; main query paths still use the parallel datasets. */
+ (NSDictionary *)readCompoundHeaderRow:(NSUInteger)row
                               fromGroup:(TTIOHDF5Group *)parent
                                   error:(NSError **)error;

#pragma mark - Generic schema-driven write/read (M39 provider adapter)

/** Write an array of rows (each NSDictionary keyed by field name)
 *  into a compound dataset with the given schema. */
+ (BOOL)writeGeneric:(NSArray<NSDictionary *> *)rows
            intoGroup:(TTIOHDF5Group *)parent
         datasetNamed:(NSString *)name
               fields:(NSArray<TTIOCompoundField *> *)fields
                error:(NSError **)error;

/** Read an existing compound dataset, returning rows as NSDictionary
 *  keyed by field name. */
+ (NSArray<NSDictionary *> *)readGenericFromGroup:(TTIOHDF5Group *)parent
                                       datasetNamed:(NSString *)name
                                             fields:(NSArray<TTIOCompoundField *> *)fields
                                              error:(NSError **)error;

@end

#endif /* TTIO_COMPOUND_IO_H */
