#ifndef TTIO_SPECTRAL_DATASET_H
#define TTIO_SPECTRAL_DATASET_H

#import <Foundation/Foundation.h>
#import "Protocols/TTIOEncryptable.h"
#import "Protocols/TTIORun.h"
#import "ValueClasses/TTIOEnums.h"

@class TTIOAcquisitionRun;
@class TTIOWrittenRun;
@class TTIONMRSpectrum;
@class TTIOIdentification;
@class TTIOQuantification;
@class TTIOProvenanceRecord;
@class TTIOTransitionList;
@class TTIOAccessPolicy;
@class TTIOHDF5Group;
@class TTIOGenomicRun;
@class TTIOWrittenGenomicRun;
@protocol TTIOStorageProvider;

/**
 * <p><em>Inherits From:</em> NSObject</p>
 * <p><em>Conforms To:</em> TTIOEncryptable</p>
 * <p><em>Declared In:</em> Dataset/TTIOSpectralDataset.h</p>
 *
 * <p>Root container for a TTI-O <code>.tio</code> file. Owns a
 * top-level <code>study/</code> group plus zero or more named MS
 * acquisition runs, NMR spectrum collections, genomic runs, and the
 * dataset-wide identifications, quantifications, provenance
 * records, and an optional transition list.</p>
 *
 * <p>Persistence is via
 * <code>-writeToFilePath:error:</code> /
 * <code>+readFromFilePath:error:</code> which open or create the
 * underlying HDF5 file directly. The class also provides several
 * <code>+writeMinimalToPath:</code> overloads — flat-buffer fast
 * paths that bypass per-spectrum object construction for callers
 * with already-flattened channel data (importers, numerical
 * producers).</p>
 *
 * <p><strong>API status:</strong> Stable.</p>
 *
 * <p><strong>Cross-language equivalents:</strong><br/>
 * Python: <code>ttio.spectral_dataset.SpectralDataset</code><br/>
 * Java: <code>global.thalion.ttio.SpectralDataset</code></p>
 */
@interface TTIOSpectralDataset : NSObject <TTIOEncryptable>

/** Free-form dataset title. */
@property (readonly, copy) NSString *title;

/** ISA-Tab investigation identifier this dataset belongs to. */
@property (readonly, copy) NSString *isaInvestigationId;

/** MS acquisition runs keyed by name. */
@property (readonly, copy) NSDictionary<NSString *, TTIOAcquisitionRun *> *msRuns;

/** NMR spectrum collections keyed by name. */
@property (readonly, copy) NSDictionary<NSString *, NSArray<TTIONMRSpectrum *> *> *nmrRuns;

/** Genomic runs keyed by name. Empty for files without genomic
 *  content. */
@property (readonly, copy) NSDictionary<NSString *, TTIOGenomicRun *> *genomicRuns;

/** Dataset-wide identifications. */
@property (readonly, copy) NSArray<TTIOIdentification *> *identifications;

/** Dataset-wide quantifications. */
@property (readonly, copy) NSArray<TTIOQuantification *> *quantifications;

/** Dataset-wide provenance records. */
@property (readonly, copy) NSArray<TTIOProvenanceRecord *> *provenanceRecords;

/** Optional SRM/MRM transition list; <code>nil</code> when absent. */
@property (readonly, strong) TTIOTransitionList *transitions;

/** <code>YES</code> iff this dataset carries an
 *  <code>encrypted</code> root attribute. */
@property (readonly) BOOL isEncrypted;

/** Algorithm identifier stored in the root <code>encrypted</code>
 *  attribute (e.g. <code>@"aes-256-gcm"</code>); empty when not
 *  encrypted. */
@property (readonly, copy) NSString *encryptedAlgorithm;

/**
 * Designated initialiser.
 *
 * @param title           Dataset title.
 * @param isaId           ISA-Tab investigation identifier.
 * @param msRuns          MS acquisition runs.
 * @param nmrRuns         NMR spectrum collections.
 * @param identifications Dataset-wide identifications.
 * @param quantifications Dataset-wide quantifications.
 * @param provenance      Dataset-wide provenance records.
 * @param transitions     Optional transition list.
 * @return An initialised dataset.
 */
- (instancetype)initWithTitle:(NSString *)title
           isaInvestigationId:(NSString *)isaId
                       msRuns:(NSDictionary *)msRuns
                      nmrRuns:(NSDictionary *)nmrRuns
              identifications:(NSArray *)identifications
              quantifications:(NSArray *)quantifications
            provenanceRecords:(NSArray *)provenance
                  transitions:(TTIOTransitionList *)transitions;

/**
 * Writes the dataset to <code>path</code>, opening or truncating
 * the underlying HDF5 file.
 */
- (BOOL)writeToFilePath:(NSString *)path error:(NSError **)error;

/**
 * Reads a dataset from <code>path</code>.
 */
+ (instancetype)readFromFilePath:(NSString *)path error:(NSError **)error;

/**
 * Flat-buffer fast write path. Bypasses per-spectrum object
 * construction and the channel-concat that
 * <code>-writeToFilePath:error:</code> performs when given a
 * <code>TTIOAcquisitionRun</code> of <code>TTIOMassSpectrum</code>
 * objects. Callers that already have flat buffers (e.g. importers
 * reading mzML in bulk, numerical producers) pass
 * <code>TTIOWrittenRun</code> instances and skip both costs.
 *
 * <p>Writes the same on-disk layout as
 * <code>-writeToFilePath:</code>, so readers do not distinguish
 * files produced by the two paths.</p>
 */
+ (BOOL)writeMinimalToPath:(NSString *)path
                     title:(NSString *)title
        isaInvestigationId:(NSString *)isaId
                    msRuns:(NSDictionary<NSString *, TTIOWrittenRun *> *)runs
           identifications:(nullable NSArray *)identifications
           quantifications:(nullable NSArray *)quantifications
         provenanceRecords:(nullable NSArray *)provenance
                     error:(NSError * _Nullable * _Nullable)error;

/**
 * Extended <code>+writeMinimalToPath:</code> accepting genomic
 * runs alongside MS runs. Setting <code>genomicRuns</code> to a
 * non-empty dictionary adds the <code>opt_genomic</code> feature
 * flag. The shorter overload above delegates here with
 * <code>genomicRuns:nil</code>.
 */
+ (BOOL)writeMinimalToPath:(NSString *)path
                     title:(NSString *)title
        isaInvestigationId:(NSString *)isaId
                    msRuns:(NSDictionary<NSString *, TTIOWrittenRun *> *)runs
               genomicRuns:(nullable NSDictionary<NSString *, TTIOWrittenGenomicRun *> *)genomicRuns
           identifications:(nullable NSArray *)identifications
           quantifications:(nullable NSArray *)quantifications
         provenanceRecords:(nullable NSArray *)provenance
                     error:(NSError * _Nullable * _Nullable)error;

/**
 * Canonical mixed-dictionary write API. Accepts a single
 * <code>mixedRuns</code> dict whose values may be either
 * <code>TTIOWrittenRun</code> (MS) or
 * <code>TTIOWrittenGenomicRun</code> (genomic); dispatches per-value
 * via <code>-isKindOfClass:</code> to the right write path.
 *
 * <p><code>genomicRuns</code> may also be supplied; a name appearing
 * in BOTH dicts populates <code>error</code> rather than silently
 * picking one. Unsupported value classes in <code>mixedRuns</code>
 * also produce an error.</p>
 */
+ (BOOL)writeMinimalToPath:(NSString *)path
                     title:(NSString *)title
        isaInvestigationId:(NSString *)isaId
                 mixedRuns:(NSDictionary<NSString *, id> *)mixedRuns
               genomicRuns:(nullable NSDictionary<NSString *, TTIOWrittenGenomicRun *> *)genomicRuns
           identifications:(nullable NSArray *)identifications
           quantifications:(nullable NSArray *)quantifications
         provenanceRecords:(nullable NSArray *)provenance
                     error:(NSError * _Nullable * _Nullable)error;

/**
 * Releases the underlying HDF5 file handle. After this call any
 * further lazy hyperslab reads on contained runs will fail.
 * Required before calling
 * <code>-encryptWithKey:level:error:</code> so the encryption
 * manager can reopen the file read-write. Idempotent.
 */
- (BOOL)closeFile;

/** Path from which the dataset was last read or written;
 *  <code>nil</code> until persistence has happened at least once. */
@property (readonly, copy) NSString *filePath;

/** Owning storage provider, set when the dataset was opened or
 *  written via <code>+readFromFilePath:</code> /
 *  <code>-writeToFilePath:</code>. Byte-level code continues to use
 *  the underlying native handle (<code>provider.nativeHandle</code>). */
@property (readonly, strong) id<TTIOStorageProvider> provider;

/**
 * @param ref Entity URI to query.
 * @return Provenance records whose <code>inputRefs</code> contain
 *         <code>ref</code>.
 */
- (NSArray<TTIOProvenanceRecord *> *)provenanceRecordsForInputRef:(NSString *)ref;

#pragma mark - Modality-agnostic run accessors

/**
 * @return Every run in the file (MS + genomic) keyed by run name.
 *         Values conform to <code>TTIORun</code> so callers can
 *         iterate uniformly across modalities. NMR runs (legacy
 *         plain <code>NSArray</code> values) are omitted because
 *         they do not yet conform to <code>TTIORun</code>.
 */
- (NSDictionary<NSString *, id<TTIORun>> *)runs;

/**
 * Alias for <code>-runs</code> retained for source compatibility.
 */
- (NSDictionary<NSString *, id<TTIORun>> *)allRunsUnified;

/**
 * @param sampleURI Sample URI to filter by.
 * @return Every run whose
 *         <code>-[TTIORun provenanceChain]</code> carries
 *         <code>sampleURI</code> in any record's
 *         <code>inputRefs</code>. Walks all modalities uniformly via
 *         the <code>TTIORun</code> protocol. Empty when no run
 *         matches.
 */
- (NSDictionary<NSString *, id<TTIORun>> *)runsForSample:(NSString *)sampleURI;

/**
 * @param runClass A class object — pass
 *                 <code>[TTIOAcquisitionRun class]</code> to filter
 *                 to MS runs, <code>[TTIOGenomicRun class]</code>
 *                 for genomic runs.
 * @return Runs whose value is an instance of <code>runClass</code>.
 */
- (NSDictionary<NSString *, id<TTIORun>> *)runsOfModality:(Class)runClass;

#pragma mark - TTIOEncryptable

- (BOOL)encryptWithKey:(NSData *)key
                 level:(TTIOEncryptionLevel)level
                 error:(NSError **)error;
- (BOOL)decryptWithKey:(NSData *)key error:(NSError **)error;
- (TTIOAccessPolicy *)accessPolicy;
- (void)setAccessPolicy:(TTIOAccessPolicy *)policy;

/**
 * Persist-to-disk decrypt. Strips AES-256-GCM encryption from the
 * <code>.tio</code> file at <code>path</code>: for every MS run
 * with an encrypted intensity channel, writes the plaintext back
 * as <code>intensity_values</code> and removes the encrypted
 * siblings. Finally clears the root <code>@encrypted</code>
 * attribute so <code>-isEncrypted</code> returns <code>NO</code>
 * when the file is reopened.
 *
 * <p>Symmetric with <code>-encryptWithKey:level:error:</code> (which
 * leaves the root attribute set). After this call the file is
 * byte-compatible with the pre-encryption layout. The file must
 * not be held open by another writer.</p>
 */
+ (BOOL)decryptInPlaceAtPath:(NSString *)path
                     withKey:(NSData *)key
                       error:(NSError **)error;

#pragma mark - Subclass hooks

/**
 * Override hook for subclasses (e.g. <code>TTIOMSImage</code>) to
 * write their own datasets under <code>/study/</code> after the
 * base dataset has been written. Default is a no-op. Return
 * <code>NO</code> to abort the write.
 */
- (BOOL)writeAdditionalStudyContent:(TTIOHDF5Group *)studyGroup
                              error:(NSError **)error;

/**
 * Override hook for subclasses to read their own datasets under
 * <code>/study/</code> after the base dataset has been loaded.
 * Default is a no-op.
 */
- (BOOL)readAdditionalStudyContent:(TTIOHDF5Group *)studyGroup
                             error:(NSError **)error;

@end

#endif
