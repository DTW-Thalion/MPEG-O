#ifndef TTIO_ACQUISITION_RUN_H
#define TTIO_ACQUISITION_RUN_H

#import <Foundation/Foundation.h>
#import "Protocols/TTIOIndexable.h"
#import "Protocols/TTIOStreamable.h"
#import "Protocols/TTIOProvenanceable.h"
#import "Protocols/TTIOEncryptable.h"
#import "Protocols/TTIORun.h"
#import "ValueClasses/TTIOEnums.h"

#import "Providers/TTIOStorageProtocols.h"

@class TTIOSpectrum;
@class TTIOMassSpectrum;
@class TTIOChromatogram;
@class TTIOInstrumentConfig;
@class TTIOSpectrumIndex;
@class TTIOValueRange;
@class TTIOProvenanceRecord;
@class TTIOAccessPolicy;

/**
 * An ordered run of spectra sharing an instrument configuration and
 * acquisition mode. Maps to the MPEG-G Dataset concept; each spectrum
 * is an Access Unit.
 *
 * v0.2 update: runs accept any TTIOSpectrum subclass (mass spectra,
 * NMR spectra, ...). Signal channel serialization is name-driven, so
 * an MS run writes mz_values + intensity_values (binary-identical to
 * v0.1) and an NMR run writes chemical_shift_values + intensity_values.
 * The run group carries a spectrum_class attribute identifying the
 * subclass; absence of that attribute triggers v0.1 fallback
 * (TTIOMassSpectrum with hardcoded channel names).
 *
 * Conformances (v0.2): TTIOProvenanceable (per-run provenance chain),
 * TTIOEncryptable (delegates to TTIOEncryptionManager when the run
 * carries persistence context set by TTIOSpectralDataset after load).
 *
 * API status: Stable (Encryptable surface deferred to M41.5 in
 * non-ObjC implementations).
 *
 * Cross-language equivalents:
 *   Python: ttio.acquisition_run.AcquisitionRun
 *   Java:   global.thalion.ttio.AcquisitionRun
 */
@interface TTIOAcquisitionRun : NSObject <TTIOIndexable,
                                          TTIOStreamable,
                                          TTIOProvenanceable,
                                          TTIOEncryptable,
                                          TTIORun>

/** Phase 1: run identifier as stored in the .tio file (e.g.
 *  ``@"run_0001"``). Set after load by -setPersistenceFilePath:runName:
 *  or by the in-memory write path; defaults to the empty string for
 *  freshly constructed in-memory runs that have not yet been persisted.
 *  Required by the TTIORun protocol so callers can iterate uniformly
 *  across modalities. */
@property (readonly, copy) NSString *name;

@property (readonly) TTIOAcquisitionMode acquisitionMode;
@property (readonly, strong) TTIOInstrumentConfig *instrumentConfig;
@property (readonly, strong) TTIOSpectrumIndex *spectrumIndex;

/** Name of the dominant spectrum class for this run, e.g.
 *  @"TTIOMassSpectrum" or @"TTIONMRSpectrum". Set from the first
 *  spectrum at init or read from the HDF5 attribute. */
@property (readonly, copy) NSString *spectrumClassName;

/** v0.11 M79: omics modality this run carries. Wire/storage attribute
 *  ``@modality`` (UTF-8 string). Defaults to ``@"mass_spectrometry"``;
 *  pre-v0.11 files lack the attribute and are interpreted as mass-spec
 *  runs. v0.11 M74 will introduce ``@"genomics"`` for genomic-read
 *  runs. */
@property (readonly, copy) NSString *modality;

/** NMR-only run-level metadata (zero/nil for MS runs). Propagated to
 *  every reconstructed TTIONMRSpectrum. */
@property (readonly, copy) NSString *nucleusType;
@property (readonly) double spectrometerFrequencyMHz;

/** v0.3 M21: compression codec applied to signal channel datasets
 *  when persisting this run. Defaults to ``TTIOCompressionZlib`` so
 *  existing callers are unaffected. Writers may set LZ4 or
 *  Numpress-delta explicitly before calling ``writeToGroup:``. */
@property (nonatomic) TTIOCompression signalCompression;

/** v0.4 M24: chromatogram traces associated with this run (TIC / XIC /
 *  SRM). Empty by default so v0.3 files read back as zero-chromatogram
 *  runs without a schema bump. Persisted under
 *  ``&lt;run&gt;/chromatograms/`` with concatenated ``time_values`` +
 *  ``intensity_values`` datasets and a ``chromatogram_index/`` subgroup
 *  of parallel metadata arrays. */
@property (readonly, copy) NSArray<TTIOChromatogram *> *chromatograms;

#pragma mark - In-memory construction

/** v0.2 generalized initializer. Accepts any TTIOSpectrum subclass,
 *  but all spectra in the same run must share a single subclass. */
- (instancetype)initWithSpectra:(NSArray *)spectra
                acquisitionMode:(TTIOAcquisitionMode)mode
               instrumentConfig:(TTIOInstrumentConfig *)config;

/** v0.4 M24 initializer. ``chromatograms`` may be nil/empty. */
- (instancetype)initWithSpectra:(NSArray *)spectra
                  chromatograms:(NSArray<TTIOChromatogram *> *)chromatograms
                acquisitionMode:(TTIOAcquisitionMode)mode
               instrumentConfig:(TTIOInstrumentConfig *)config;

#pragma mark - Storage round-trip (provider-agnostic)

/** v0.7 M44 / Task 31: I/O routed through StorageGroup / StorageDataset. */
- (BOOL)writeToGroup:(id<TTIOStorageGroup>)parent
                name:(NSString *)name
               error:(NSError **)error;

+ (instancetype)readFromGroup:(id<TTIOStorageGroup>)parent
                         name:(NSString *)name
                        error:(NSError **)error;

/** v0.9 M64.5-objc-java: legacy alias for the storage-protocol read
 *  path. Now identical to +readFromGroup:name:error:; retained for
 *  source compatibility with v0.9 callers. */
+ (instancetype)readFromStorageGroup:(id)parent
                                 name:(NSString *)name
                                error:(NSError **)error;

#pragma mark - Random access

/** v0.2: returns whatever TTIOSpectrum subclass the run holds. */
- (id)spectrumAtIndex:(NSUInteger)index error:(NSError **)error;

/** Indices in the given retention-time range, in ascending order. */
- (NSArray<NSNumber *> *)indicesInRetentionTimeRange:(TTIOValueRange *)range;

#pragma mark - Persistence context (used by TTIOSpectralDataset)

/** Attach file-path + run-name context after load so protocol
 *  encryption methods have something to delegate to. Internal API. */
- (void)setPersistenceFilePath:(NSString *)path runName:(NSString *)runName;

/** Release all cached HDF5 handles (group + per-channel datasets).
 *  After this call, spectrumAtIndex: fails; the run keeps its index
 *  metadata so count/headers remain queryable. Used by
 *  TTIOSpectralDataset.closeFile to fully release the underlying file
 *  before an encrypt/decrypt reopen. */
- (void)releaseHDF5Handles;

#pragma mark - TTIOProvenanceable

- (void)addProcessingStep:(TTIOProvenanceRecord *)step;
- (NSArray<TTIOProvenanceRecord *> *)provenanceChain;
- (NSArray<NSString *> *)inputEntities;
- (NSArray<NSString *> *)outputEntities;

#pragma mark - TTIOEncryptable

- (BOOL)encryptWithKey:(NSData *)key
                 level:(TTIOEncryptionLevel)level
                 error:(NSError **)error;
- (BOOL)decryptWithKey:(NSData *)key error:(NSError **)error;
- (TTIOAccessPolicy *)accessPolicy;
- (void)setAccessPolicy:(TTIOAccessPolicy *)policy;

@end

#endif
