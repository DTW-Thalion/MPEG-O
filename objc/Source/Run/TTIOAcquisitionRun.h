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
 * <heading>TTIOAcquisitionRun</heading>
 *
 * <p><em>Inherits From:</em> NSObject</p>
 * <p><em>Conforms To:</em> TTIOIndexable, TTIOStreamable,
 * TTIOProvenanceable, TTIOEncryptable, TTIORun</p>
 * <p><em>Declared In:</em> Run/TTIOAcquisitionRun.h</p>
 *
 * <p>An ordered run of spectra sharing an instrument configuration
 * and acquisition mode. The non-genomic counterpart of
 * <code>TTIOGenomicRun</code>; both conform to <code>TTIORun</code>
 * so cross-modality code can iterate uniformly.</p>
 *
 * <p>A run accepts any <code>TTIOSpectrum</code> subclass (mass
 * spectra, NMR spectra, Raman, IR, UV-Vis, ...) but every spectrum
 * within a single run must share a single subclass. Signal-channel
 * serialisation is name-driven, so an MS run writes
 * <code>mz_values</code> + <code>intensity_values</code> and an NMR
 * run writes <code>chemical_shift_values</code> +
 * <code>intensity_values</code>. The run group carries a
 * <code>spectrum_class</code> attribute identifying the subclass.</p>
 *
 * <p><strong>API status:</strong> Stable.</p>
 *
 * <p><strong>Cross-language equivalents:</strong><br/>
 * Python: <code>ttio.acquisition_run.AcquisitionRun</code><br/>
 * Java: <code>global.thalion.ttio.AcquisitionRun</code></p>
 */
@interface TTIOAcquisitionRun : NSObject <TTIOIndexable,
                                          TTIOStreamable,
                                          TTIOProvenanceable,
                                          TTIOEncryptable,
                                          TTIORun>

/** Run identifier as stored in the .tio file (e.g.
 *  <code>@"run_0001"</code>). Defaults to the empty string for
 *  freshly constructed in-memory runs that have not yet been
 *  persisted. */
@property (readonly, copy) NSString *name;

/** Acquisition mode enum value identifying the protocol context. */
@property (readonly) TTIOAcquisitionMode acquisitionMode;

/** Instrument-configuration metadata. */
@property (readonly, strong) TTIOInstrumentConfig *instrumentConfig;

/** Per-spectrum offsets, lengths, and queryable scan metadata. */
@property (readonly, strong) TTIOSpectrumIndex *spectrumIndex;

/** Name of the dominant spectrum class for this run, e.g.
 *  <code>@"TTIOMassSpectrum"</code> or
 *  <code>@"TTIONMRSpectrum"</code>. */
@property (readonly, copy) NSString *spectrumClassName;

/** Omics modality this run carries. Storage attribute
 *  <code>@modality</code> (UTF-8). Defaults to
 *  <code>@"mass_spectrometry"</code>. */
@property (readonly, copy) NSString *modality;

/** Nucleus identifier for NMR runs (zero / <code>nil</code> for
 *  non-NMR). Propagated to every reconstructed
 *  <code>TTIONMRSpectrum</code>. */
@property (readonly, copy) NSString *nucleusType;

/** Spectrometer frequency in MHz for NMR runs. */
@property (readonly) double spectrometerFrequencyMHz;

/** Compression codec applied to signal-channel datasets when
 *  persisting this run. Defaults to <code>TTIOCompressionZlib</code>;
 *  writers may set <code>LZ4</code> or <code>NumpressDelta</code>
 *  explicitly before calling <code>-writeToGroup:</code>. */
@property (nonatomic) TTIOCompression signalCompression;

/** Chromatogram traces associated with this run (TIC / XIC / SRM).
 *  Empty by default. */
@property (readonly, copy) NSArray<TTIOChromatogram *> *chromatograms;

#pragma mark - In-memory construction

/**
 * Convenience initialiser without chromatograms.
 *
 * @param spectra Array of any single <code>TTIOSpectrum</code>
 *                subclass.
 * @param mode    Acquisition mode.
 * @param config  Instrument configuration.
 * @return An initialised run.
 */
- (instancetype)initWithSpectra:(NSArray *)spectra
                acquisitionMode:(TTIOAcquisitionMode)mode
               instrumentConfig:(TTIOInstrumentConfig *)config;

/**
 * Designated initialiser.
 *
 * @param spectra        Array of any single <code>TTIOSpectrum</code>
 *                       subclass.
 * @param chromatograms  Optional chromatograms; pass <code>nil</code>
 *                       or empty array for none.
 * @param mode           Acquisition mode.
 * @param config         Instrument configuration.
 * @return An initialised run.
 */
- (instancetype)initWithSpectra:(NSArray *)spectra
                  chromatograms:(NSArray<TTIOChromatogram *> *)chromatograms
                acquisitionMode:(TTIOAcquisitionMode)mode
               instrumentConfig:(TTIOInstrumentConfig *)config;

#pragma mark - Storage round-trip

/**
 * Writes this run into a new sub-group named <code>name</code>
 * under <code>parent</code> via the
 * <code>TTIOStorageGroup</code> protocol.
 */
- (BOOL)writeToGroup:(id<TTIOStorageGroup>)parent
                name:(NSString *)name
               error:(NSError **)error;

/**
 * Reads a run from <code>parent/name</code>.
 */
+ (instancetype)readFromGroup:(id<TTIOStorageGroup>)parent
                         name:(NSString *)name
                        error:(NSError **)error;

/**
 * Legacy alias for
 * <code>+readFromGroup:name:error:</code>; identical behaviour,
 * retained for source compatibility.
 */
+ (instancetype)readFromStorageGroup:(id)parent
                                name:(NSString *)name
                               error:(NSError **)error;

#pragma mark - Random access

/**
 * @param index Zero-based position; must satisfy
 *              <code>index &lt; count</code>.
 * @param error Out-parameter populated on failure.
 * @return The materialised spectrum (concrete subclass), or
 *         <code>nil</code> on failure.
 */
- (id)spectrumAtIndex:(NSUInteger)index error:(NSError **)error;

/**
 * @param range Closed retention-time range in seconds.
 * @return Indices in ascending order whose retention time falls
 *         inside the range.
 */
- (NSArray<NSNumber *> *)indicesInRetentionTimeRange:(TTIOValueRange *)range;

#pragma mark - Persistence context

/**
 * Attaches file-path + run-name context after load so protocol
 * encryption methods can delegate to the in-place encryption
 * manager. Internal API.
 */
- (void)setPersistenceFilePath:(NSString *)path runName:(NSString *)runName;

/**
 * Releases all cached HDF5 handles (group + per-channel datasets).
 * After this call <code>-spectrumAtIndex:error:</code> fails; the
 * run keeps its index metadata so <code>count</code> / headers
 * remain queryable.
 */
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
