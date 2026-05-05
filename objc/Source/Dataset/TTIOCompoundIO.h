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
 * <heading>TTIOCompoundIO</heading>
 *
 * <p><em>Inherits From:</em> NSObject</p>
 * <p><em>Declared In:</em> Dataset/TTIOCompoundIO.h</p>
 *
 * <p>Compound-type persistence helpers for the on-disk format.
 * Writes and reads native HDF5 compound datasets that hold
 * identifications, quantifications, provenance records, and the
 * optional <code>spectrum_index/headers</code> compound. Variable-
 * length C strings are used inside the records so
 * <code>h5dump</code> can visualise the rows directly.</p>
 *
 * <p>The class also provides a generic schema-driven writer / reader
 * (<code>+writeGeneric:intoGroup:datasetNamed:fields:error:</code>)
 * used by the storage-provider adapter layer.</p>
 *
 * <p><strong>API status:</strong> Stable (internal helper).</p>
 *
 * <p><strong>Cross-language equivalents:</strong><br/>
 * Python: <code>ttio._hdf5_io</code> (private helper module)<br/>
 * Java: <code>global.thalion.ttio.hdf5.Hdf5CompoundIO</code></p>
 */
@interface TTIOCompoundIO : NSObject

#pragma mark - Identifications

/**
 * Writes identifications as a compound dataset under
 * <code>parent/name</code>.
 */
+ (BOOL)writeIdentifications:(NSArray<TTIOIdentification *> *)idents
                   intoGroup:(TTIOHDF5Group *)parent
                datasetNamed:(NSString *)name
                       error:(NSError **)error;

/**
 * Reads identifications previously written by
 * <code>+writeIdentifications:intoGroup:datasetNamed:error:</code>.
 */
+ (NSArray<TTIOIdentification *> *)readIdentificationsFromGroup:(TTIOHDF5Group *)parent
                                                   datasetNamed:(NSString *)name
                                                          error:(NSError **)error;

#pragma mark - Quantifications

/** Writes quantifications as a compound dataset. */
+ (BOOL)writeQuantifications:(NSArray<TTIOQuantification *> *)quants
                   intoGroup:(TTIOHDF5Group *)parent
                datasetNamed:(NSString *)name
                       error:(NSError **)error;

/** Reads quantifications. */
+ (NSArray<TTIOQuantification *> *)readQuantificationsFromGroup:(TTIOHDF5Group *)parent
                                                   datasetNamed:(NSString *)name
                                                          error:(NSError **)error;

#pragma mark - Provenance

/** Writes provenance records as a compound dataset. */
+ (BOOL)writeProvenance:(NSArray<TTIOProvenanceRecord *> *)records
              intoGroup:(TTIOHDF5Group *)parent
           datasetNamed:(NSString *)name
                  error:(NSError **)error;

/** Reads provenance records. */
+ (NSArray<TTIOProvenanceRecord *> *)readProvenanceFromGroup:(TTIOHDF5Group *)parent
                                                datasetNamed:(NSString *)name
                                                       error:(NSError **)error;

#pragma mark - Spectrum-index compound headers

/**
 * Writes a <code>headers</code> compound dataset alongside the
 * existing parallel 1-D datasets under
 * <code>spectrum_index/</code>. Purely additive; the read path
 * still uses the parallel arrays. Exists primarily for
 * external-tool readability (<code>h5dump</code>, schema-aware
 * viewers).
 */
+ (BOOL)writeCompoundHeadersForIndex:(TTIOSpectrumIndex *)index
                           intoGroup:(TTIOHDF5Group *)parent
                               error:(NSError **)error;

/**
 * Reads a single header row from the compound dataset.
 *
 * @param row    Zero-based row index.
 * @param parent Parent group containing
 *               <code>spectrum_index/</code>.
 * @param error  Out-parameter populated on failure.
 * @return Dictionary keyed by field name (<code>offset</code>,
 *         <code>length</code>, <code>retention_time</code>,
 *         <code>ms_level</code>, <code>polarity</code>,
 *         <code>precursor_mz</code>, <code>precursor_charge</code>,
 *         <code>base_peak_intensity</code>).
 */
+ (NSDictionary *)readCompoundHeaderRow:(NSUInteger)row
                              fromGroup:(TTIOHDF5Group *)parent
                                  error:(NSError **)error;

#pragma mark - Generic schema-driven write/read

/**
 * Writes an array of dictionary rows into a compound dataset with
 * the given schema.
 *
 * @param rows         Rows; each <code>NSDictionary</code> keyed by
 *                     field name.
 * @param parent       Destination parent group.
 * @param name         Dataset name.
 * @param fields       Schema definition.
 * @param error        Out-parameter populated on failure.
 * @return <code>YES</code> on success.
 */
+ (BOOL)writeGeneric:(NSArray<NSDictionary *> *)rows
           intoGroup:(TTIOHDF5Group *)parent
        datasetNamed:(NSString *)name
              fields:(NSArray<TTIOCompoundField *> *)fields
               error:(NSError **)error;

/**
 * Reads a compound dataset, returning rows as dictionaries keyed by
 * field name.
 */
+ (NSArray<NSDictionary *> *)readGenericFromGroup:(TTIOHDF5Group *)parent
                                     datasetNamed:(NSString *)name
                                           fields:(NSArray<TTIOCompoundField *> *)fields
                                            error:(NSError **)error;

@end

#endif /* TTIO_COMPOUND_IO_H */
