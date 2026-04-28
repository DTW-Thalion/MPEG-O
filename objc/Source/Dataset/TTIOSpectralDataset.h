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
@class TTIOGenomicRun;          // v0.11 M82
@class TTIOWrittenGenomicRun;   // v0.11 M82
@protocol TTIOStorageProvider;

/**
 * Root container for an TTI-O `.tio` file. Owns a top-level `study/`
 * group plus zero or more named MS acquisition runs, zero or more named
 * NMR-spectrum collections, and the dataset-wide identifications,
 * quantifications, provenance records, and (optionally) a transition list.
 *
 * Persistence is via -writeToFilePath:error: / +readFromFilePath:error:
 * which open or create the underlying HDF5 file directly.
 *
 * API status: Stable. Encryptable conformance delivered in
 * M41.5 in non-ObjC implementations.
 *
 * Cross-language equivalents:
 *   Python: ttio.spectral_dataset.SpectralDataset
 *   Java:   global.thalion.ttio.SpectralDataset
 */
@interface TTIOSpectralDataset : NSObject <TTIOEncryptable>

@property (readonly, copy) NSString *title;
@property (readonly, copy) NSString *isaInvestigationId;

@property (readonly, copy) NSDictionary<NSString *, TTIOAcquisitionRun *> *msRuns;
@property (readonly, copy) NSDictionary<NSString *, NSArray<TTIONMRSpectrum *> *> *nmrRuns;

/** v0.11 M82: zero or more named genomic runs. Empty for pre-M82
 *  files; populated when /study/genomic_runs/ is present. */
@property (readonly, copy) NSDictionary<NSString *, TTIOGenomicRun *> *genomicRuns;

@property (readonly, copy) NSArray<TTIOIdentification *>   *identifications;
@property (readonly, copy) NSArray<TTIOQuantification *>   *quantifications;
@property (readonly, copy) NSArray<TTIOProvenanceRecord *> *provenanceRecords;
@property (readonly, strong) TTIOTransitionList *transitions;       // nullable

/** YES iff this dataset carries an `encrypted` root attribute (written
 *  by -encryptWithKey:level:error: via -markRootEncryptedWithError:).
 *  Value is derived from -encryptedAlgorithm so the two stay consistent.
 *  Mirrors Python `SpectralDataset.is_encrypted` / Java
 *  `SpectralDataset.isEncrypted()`. */
@property (readonly) BOOL isEncrypted;

/** The algorithm identifier stored in the root `encrypted` attribute,
 *  or the empty string when the dataset is not encrypted. Typical value
 *  is @"aes-256-gcm". Mirrors Python
 *  `SpectralDataset.encrypted_algorithm` / Java
 *  `SpectralDataset.encryptedAlgorithm()`. */
@property (readonly, copy) NSString *encryptedAlgorithm;

- (instancetype)initWithTitle:(NSString *)title
           isaInvestigationId:(NSString *)isaId
                       msRuns:(NSDictionary *)msRuns
                      nmrRuns:(NSDictionary *)nmrRuns
              identifications:(NSArray *)identifications
              quantifications:(NSArray *)quantifications
            provenanceRecords:(NSArray *)provenance
                  transitions:(TTIOTransitionList *)transitions;

- (BOOL)writeToFilePath:(NSString *)path error:(NSError **)error;
+ (instancetype)readFromFilePath:(NSString *)path error:(NSError **)error;

/** Flat-buffer fast path. Bypasses per-spectrum object construction
 *  and the write-time channel concat that -writeToFilePath:error:
 *  performs when given an TTIOAcquisitionRun of TTIOMassSpectrum
 *  objects. Callers that already have flat buffers (e.g. importers
 *  reading mzML in bulk, numerical producers) pass TTIOWrittenRun
 *  instances and skip both costs.
 *
 *  Writes the same on-disk layout as -writeToFilePath:, so readers
 *  don't distinguish files produced by the two paths. Mirrors Python
 *  +[SpectralDataset write_minimal] and gives the ObjC implementation
 *  parity with Python's fastest write API. v1.1.
 */
+ (BOOL)writeMinimalToPath:(NSString *)path
                      title:(NSString *)title
        isaInvestigationId:(NSString *)isaId
                    msRuns:(NSDictionary<NSString *, TTIOWrittenRun *> *)runs
            identifications:(nullable NSArray *)identifications
            quantifications:(nullable NSArray *)quantifications
          provenanceRecords:(nullable NSArray *)provenance
                      error:(NSError * _Nullable * _Nullable)error;

/** v0.11 M82: extended write_minimal accepting genomic runs alongside
 *  MS runs. Setting genomicRuns to a non-empty dict adds the
 *  `opt_genomic` feature flag and bumps format_version to 1.4. The
 *  shorter overload above delegates here with genomicRuns:nil. */
+ (BOOL)writeMinimalToPath:(NSString *)path
                      title:(NSString *)title
        isaInvestigationId:(NSString *)isaId
                    msRuns:(NSDictionary<NSString *, TTIOWrittenRun *> *)runs
                genomicRuns:(nullable NSDictionary<NSString *, TTIOWrittenGenomicRun *> *)genomicRuns
            identifications:(nullable NSArray *)identifications
            quantifications:(nullable NSArray *)quantifications
          provenanceRecords:(nullable NSArray *)provenance
                      error:(NSError * _Nullable * _Nullable)error;

/** Phase 2 (post-M91) canonical mixed-dict write API. Accepts a
 *  single ``mixedRuns`` dict whose values may be either
 *  TTIOWrittenRun (MS) or TTIOWrittenGenomicRun (genomic);
 *  dispatches per-value via -isKindOfClass: to the right write path.
 *  ``genomicRuns`` may also be supplied for backward compatibility;
 *  a name appearing in BOTH dicts raises NSError (returns NO with
 *  the error populated) rather than silently picking one — matches
 *  Python's ValueError on collision. Other-typed values in
 *  ``mixedRuns`` produce an NSError.
 *
 *  Mirrors Python's Phase 2 ``SpectralDataset.write_minimal(runs=…)``
 *  shape where ``runs`` may carry both kinds. */
+ (BOOL)writeMinimalToPath:(NSString *)path
                      title:(NSString *)title
        isaInvestigationId:(NSString *)isaId
                  mixedRuns:(NSDictionary<NSString *, id> *)mixedRuns
                genomicRuns:(nullable NSDictionary<NSString *, TTIOWrittenGenomicRun *> *)genomicRuns
            identifications:(nullable NSArray *)identifications
            quantifications:(nullable NSArray *)quantifications
          provenanceRecords:(nullable NSArray *)provenance
                      error:(NSError * _Nullable * _Nullable)error;

/** Release the underlying HDF5 file handle. After this call, any
 *  further lazy hyperslab reads on contained runs will fail. Required
 *  before calling encryptWithKey: so the encryption manager can
 *  reopen the file read-write. Idempotent. */
- (BOOL)closeFile;

/** The path from which the dataset was last read or written. nil
 *  until persistence has happened at least once. */
@property (readonly, copy) NSString *filePath;

/** M39: owning storage provider, set when this dataset was opened or
 *  written via +readFromFilePath: / -writeToFilePath:. New call sites
 *  should reach for this; byte-level code continues to use the
 *  underlying native handle (``[provider nativeHandle]``). */
@property (readonly, strong) id<TTIOStorageProvider> provider;

/** Provenance records whose inputRefs contain `ref`. */
- (NSArray<TTIOProvenanceRecord *> *)provenanceRecordsForInputRef:(NSString *)ref;

#pragma mark - Phase 1 / Phase 2: modality-agnostic run accessors

/** Phase 2 canonical accessor: every run in the file (MS + NMR +
 *  genomic) keyed by run name. Values conform to TTIORun so callers
 *  can iterate uniformly across modalities without forking on
 *  ms_runs vs genomic_runs. NMR runs (legacy plain NSArray-of-spectra
 *  values) are intentionally omitted because they do not yet conform
 *  to TTIORun in the ObjC tree; that aligns with the Python
 *  reference impl's intent that values be Run-protocol-conforming.
 *
 *  Mirrors Python ``SpectralDataset.runs``.
 *
 *  Phase 1 added :meth:`allRunsUnified` as the same intent under a
 *  longer name; Phase 2 promotes the accessor to ``runs`` and keeps
 *  the alias for the brief transition window. */
- (NSDictionary<NSString *, id<TTIORun>> *)runs;

/** Phase 1 alias for :attr:`runs`. Kept for the brief Phase 1 →
 *  Phase 2 transition window. */
- (NSDictionary<NSString *, id<TTIORun>> *)allRunsUnified;

/** Return every run associated with ``sampleURI``. A run is
 *  considered associated when its
 *  :meth:`-[TTIORun provenanceChain]` carries ``sampleURI`` in any
 *  record's ``inputRefs``. Walks all modalities (MS, genomic)
 *  uniformly via the TTIORun protocol — closes the M91 cross-
 *  modality query gap that previously had to fork on access
 *  pattern. Returns an empty dict when no run matches. */
- (NSDictionary<NSString *, id<TTIORun>> *)runsForSample:(NSString *)sampleURI;

/** Return every run whose value is an instance of ``runClass``.
 *  Pass [TTIOAcquisitionRun class] to get MS+NMR runs of the
 *  flat-buffer kind; pass [TTIOGenomicRun class] for genomic only.
 *  Thin filter over :meth:`runs`. */
- (NSDictionary<NSString *, id<TTIORun>> *)runsOfModality:(Class)runClass;

#pragma mark - TTIOEncryptable

- (BOOL)encryptWithKey:(NSData *)key
                 level:(TTIOEncryptionLevel)level
                 error:(NSError **)error;
- (BOOL)decryptWithKey:(NSData *)key error:(NSError **)error;
- (TTIOAccessPolicy *)accessPolicy;
- (void)setAccessPolicy:(TTIOAccessPolicy *)policy;

/**
 * v1.1.1: persist-to-disk decrypt. Strips AES-256-GCM encryption from
 * the `.tio` file at `path`: for every MS run with an encrypted
 * intensity channel, writes the plaintext back as `intensity_values`
 * and removes the encrypted siblings. Finally clears the root
 * `@encrypted` attribute so -isEncrypted returns NO when the file is
 * reopened.
 *
 * Symmetric with -encryptWithKey:level:error: (which leaves the root
 * attribute set). After this call the file is byte-compatible with
 * the pre-encryption layout.
 *
 * The file must not be held open by another writer.
 */
+ (BOOL)decryptInPlaceAtPath:(NSString *)path
                     withKey:(NSData *)key
                       error:(NSError **)error;

#pragma mark - Subclass hooks

/** Subclasses (e.g. TTIOMSImage) override to add their own datasets
 *  under /study/ after the base dataset has been written. The default
 *  is a no-op. Return NO to abort the write. */
- (BOOL)writeAdditionalStudyContent:(TTIOHDF5Group *)studyGroup
                              error:(NSError **)error;

/** Subclasses override to read their own datasets under /study/ after
 *  the base dataset has been loaded. Default is a no-op. */
- (BOOL)readAdditionalStudyContent:(TTIOHDF5Group *)studyGroup
                             error:(NSError **)error;

@end

#endif
