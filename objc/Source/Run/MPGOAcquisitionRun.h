#ifndef MPGO_ACQUISITION_RUN_H
#define MPGO_ACQUISITION_RUN_H

#import <Foundation/Foundation.h>
#import "Protocols/MPGOIndexable.h"
#import "Protocols/MPGOStreamable.h"
#import "Protocols/MPGOProvenanceable.h"
#import "Protocols/MPGOEncryptable.h"
#import "ValueClasses/MPGOEnums.h"

@class MPGOSpectrum;
@class MPGOMassSpectrum;
@class MPGOInstrumentConfig;
@class MPGOSpectrumIndex;
@class MPGOHDF5Group;
@class MPGOValueRange;
@class MPGOProvenanceRecord;
@class MPGOAccessPolicy;

/**
 * An ordered run of spectra sharing an instrument configuration and
 * acquisition mode. Maps to the MPEG-G Dataset concept; each spectrum
 * is an Access Unit.
 *
 * v0.2 update: runs accept any MPGOSpectrum subclass (mass spectra,
 * NMR spectra, ...). Signal channel serialization is name-driven, so
 * an MS run writes mz_values + intensity_values (binary-identical to
 * v0.1) and an NMR run writes chemical_shift_values + intensity_values.
 * The run group carries a spectrum_class attribute identifying the
 * subclass; absence of that attribute triggers v0.1 fallback
 * (MPGOMassSpectrum with hardcoded channel names).
 *
 * Conformances (v0.2): MPGOProvenanceable (per-run provenance chain),
 * MPGOEncryptable (delegates to MPGOEncryptionManager when the run
 * carries persistence context set by MPGOSpectralDataset after load).
 */
@interface MPGOAcquisitionRun : NSObject <MPGOIndexable,
                                          MPGOStreamable,
                                          MPGOProvenanceable,
                                          MPGOEncryptable>

@property (readonly) MPGOAcquisitionMode acquisitionMode;
@property (readonly, strong) MPGOInstrumentConfig *instrumentConfig;
@property (readonly, strong) MPGOSpectrumIndex *spectrumIndex;

/** Name of the dominant spectrum class for this run, e.g.
 *  @"MPGOMassSpectrum" or @"MPGONMRSpectrum". Set from the first
 *  spectrum at init or read from the HDF5 attribute. */
@property (readonly, copy) NSString *spectrumClassName;

/** NMR-only run-level metadata (zero/nil for MS runs). Propagated to
 *  every reconstructed MPGONMRSpectrum. */
@property (readonly, copy) NSString *nucleusType;
@property (readonly) double spectrometerFrequencyMHz;

#pragma mark - In-memory construction

/** v0.2 generalized initializer. Accepts any MPGOSpectrum subclass,
 *  but all spectra in the same run must share a single subclass. */
- (instancetype)initWithSpectra:(NSArray *)spectra
                acquisitionMode:(MPGOAcquisitionMode)mode
               instrumentConfig:(MPGOInstrumentConfig *)config;

#pragma mark - HDF5

- (BOOL)writeToGroup:(MPGOHDF5Group *)parent
                name:(NSString *)name
               error:(NSError **)error;

+ (instancetype)readFromGroup:(MPGOHDF5Group *)parent
                         name:(NSString *)name
                        error:(NSError **)error;

#pragma mark - Random access

/** v0.2: returns whatever MPGOSpectrum subclass the run holds. */
- (id)spectrumAtIndex:(NSUInteger)index error:(NSError **)error;

/** Indices in the given retention-time range, in ascending order. */
- (NSArray<NSNumber *> *)indicesInRetentionTimeRange:(MPGOValueRange *)range;

#pragma mark - Persistence context (used by MPGOSpectralDataset)

/** Attach file-path + run-name context after load so protocol
 *  encryption methods have something to delegate to. Internal API. */
- (void)setPersistenceFilePath:(NSString *)path runName:(NSString *)runName;

#pragma mark - MPGOProvenanceable

- (void)addProcessingStep:(MPGOProvenanceRecord *)step;
- (NSArray<MPGOProvenanceRecord *> *)provenanceChain;
- (NSArray<NSString *> *)inputEntities;
- (NSArray<NSString *> *)outputEntities;

#pragma mark - MPGOEncryptable

- (BOOL)encryptWithKey:(NSData *)key
                 level:(MPGOEncryptionLevel)level
                 error:(NSError **)error;
- (BOOL)decryptWithKey:(NSData *)key error:(NSError **)error;
- (MPGOAccessPolicy *)accessPolicy;
- (void)setAccessPolicy:(MPGOAccessPolicy *)policy;

@end

#endif
