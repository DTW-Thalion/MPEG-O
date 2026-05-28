#ifndef TTIO_SPECTRAL_DATASET_H
#define TTIO_SPECTRAL_DATASET_H

#import <Foundation/Foundation.h>
#import "Protocols/TTIOEncryptable.h"
#import "Protocols/TTIORun.h"
#import "ValueClasses/TTIOEnums.h"
#import "Core/TTIOProgressSink.h"

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
@class TTIOReferenceImport;
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

/**
 * Map of reference URI &rarr; <code>TTIOReferenceImport</code> for
 * embedded references found under <code>/study/references/</code>.
 *
 * <p>Empty dictionary when no references were embedded at write
 * time (writer flag <code>embedReference=NO</code>, the run was
 * not eligible for a context-aware codec, or the file pre-dates
 * the embedding feature). The setter is private; callers cannot
 * mutate the returned dictionary.</p>
 *
 * @since 1.1.0
 */
@property (readonly, copy) NSDictionary<NSString *, TTIOReferenceImport *> *references;

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
 * Progress-aware overload of the canonical
 * <code>+writeMinimalToPath:...mixedRuns:</code> write API.
 *
 * <p>Emits a baseline {@code (0, total)} fire + one {@code (idx, total)}
 * fire per non-empty section in §5.4 order
 * (encryption / provenance / subjects / samples / references /
 * image / identifications / quantifications / runs). Empty sections
 * are skipped. Pass {@code nil} for {@code progress} to skip
 * callbacks. Mirrors Java + Python.</p>
 */
+ (BOOL)writeMinimalToPath:(NSString *)path
                     title:(NSString *)title
        isaInvestigationId:(NSString *)isaId
                 mixedRuns:(NSDictionary<NSString *, id> *)mixedRuns
               genomicRuns:(nullable NSDictionary<NSString *, TTIOWrittenGenomicRun *> *)genomicRuns
           identifications:(nullable NSArray *)identifications
           quantifications:(nullable NSArray *)quantifications
         provenanceRecords:(nullable NSArray *)provenance
                  progress:(nullable TTIOProgressBlock)progress
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

/**
 * Encrypt the dataset's intensity payload in place under
 * AES-256-GCM. After this call the dataset's HDF5 file holds
 * ciphertext instead of plaintext intensity channels and
 * <code>-isEncrypted</code> returns <code>YES</code>.
 *
 * @param key   32-byte AES-256 key material.
 * @param level Granularity: per-dataset, per-run, or per-AU.
 * @param error On failure, populated with an NSError describing the
 *              cause. May be NULL.
 * @return      <code>YES</code> on success, <code>NO</code> on
 *              failure.
 */
- (BOOL)encryptWithKey:(NSData *)key
                 level:(TTIOEncryptionLevel)level
                 error:(NSError **)error;

/**
 * In-process decrypt overlay for an encrypted dataset. The plaintext
 * intensity channels become visible to subsequent reads on this
 * instance; the on-disk file is not modified (call
 * <code>+decryptInPlaceAtPath:withKey:error:</code> for persistent
 * decrypt).
 *
 * @param key   32-byte AES-256 key matching the one used at encrypt
 *              time.
 * @param error On failure (e.g. wrong key, tag mismatch), populated
 *              with an NSError describing the cause. May be NULL.
 * @return      <code>YES</code> on success, <code>NO</code> on
 *              failure.
 */
- (BOOL)decryptWithKey:(NSData *)key error:(NSError **)error;

/**
 * @return The dataset's access policy, or <code>nil</code> if none
 *         is attached. Mirrors the policy embedded under
 *         <code>/study/@access_policy</code> when present.
 */
- (TTIOAccessPolicy *)accessPolicy;

/**
 * Attach an access policy to the dataset for subsequent persistence.
 *
 * @param policy The access policy to attach, or <code>nil</code> to
 *               clear the in-memory policy.
 */
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

@end


@class TTIOMSImage;
@class TTIORamanImage;
@class TTIOIRImage;
@class TTIOSubject;
@class TTIOSample;

@interface TTIOSpectralDataset (SubjectsSamples)
/** Stage 6 (transport-spec v0.11, Deferral 2): every
 *  <code>TTIOSubject</code> persisted under
 *  <code>/study/subjects/</code> on this dataset, in on-disk
 *  iteration order. Empty array when no Subjects were written
 *  (which is most pre-Stage-6 files). Lazily materialised from the
 *  HDF5 file on first access and cached via
 *  <code>objc_setAssociatedObject</code>.
 *
 *  <p>Java parity: <code>SpectralDataset.subjects()</code>. Python
 *  parity: <code>SpectralDataset.subjects</code>.</p>
 *
 *  @since 1.4.0 */
@property (readonly, copy) NSArray<TTIOSubject *> *subjects;

/** Stage 6 (transport-spec v0.11, Deferral 2): every
 *  <code>TTIOSample</code> persisted under
 *  <code>/study/samples/</code> on this dataset, in on-disk
 *  iteration order. Empty array when no Samples were written.
 *
 *  <p>Java parity: <code>SpectralDataset.samples()</code>. Python
 *  parity: <code>SpectralDataset.samples</code>.</p>
 *
 *  @since 1.4.0 */
@property (readonly, copy) NSArray<TTIOSample *> *samples;

/**
 * Stage 6 pre-write validation (design spec §4.4):
 *
 * <ul>
 *   <li>Duplicate <code>Subject.externalId</code> or
 *       <code>Sample.sampleId</code> raises
 *       <code>NSInvalidArgumentException</code>.</li>
 *   <li><code>Sample.subjectExternalId</code> that does not match any
 *       Subject in <code>subjects</code> logs a WARNING (via
 *       <code>NSLog</code>) but does not raise. Anonymous /
 *       cross-dataset samples are valid.</li>
 * </ul>
 *
 * <p>Called by the transport reader before persisting per-row groups,
 * and exposed publicly so writers can pre-flight any
 * <code>TTIOSubject</code> / <code>TTIOSample</code> list pair
 * without having to materialise to disk first.</p>
 */
+ (void)validateSubjects:(NSArray<TTIOSubject *> *)subjects
                  samples:(NSArray<TTIOSample *> *)samples;
@end

@interface TTIOSpectralDataset (Image)
/** The embedded MSImage when /study/image_cube is present; nil otherwise.
 *  Reads and materialises the image from the file when called on a plain
 *  TTIOSpectralDataset.
 *  @since 1.2.0 */
@property (readonly, nullable) TTIOMSImage *msImage;

/** The embedded RamanImage when /study/raman_image_cube is present; nil
 *  otherwise. Mirrors <code>msImage</code> — reads and materialises the
 *  image lazily from the dataset file on first access. Java parity:
 *  <code>SpectralDataset.ramanImage()</code>. Python parity:
 *  <code>SpectralDataset.raman_image</code>.
 *  @since 1.2.0 */
@property (readonly, nullable) TTIORamanImage *ramanImage;

/** The embedded IRImage when /study/ir_image_cube is present; nil
 *  otherwise. Mirrors <code>msImage</code> / <code>ramanImage</code> for
 *  the third imaging modality. Java parity:
 *  <code>SpectralDataset.irImage()</code> (commit
 *  <code>97fb065e</code>). Python parity:
 *  <code>SpectralDataset.ir_image</code> (commit
 *  <code>8b57baa7</code>).
 *  @since 1.2.0 */
@property (readonly, nullable) TTIOIRImage *irImage;
@end

#endif
