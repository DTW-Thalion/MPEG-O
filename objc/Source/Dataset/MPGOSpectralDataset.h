#ifndef MPGO_SPECTRAL_DATASET_H
#define MPGO_SPECTRAL_DATASET_H

#import <Foundation/Foundation.h>
#import "Protocols/MPGOEncryptable.h"
#import "ValueClasses/MPGOEnums.h"

@class MPGOAcquisitionRun;
@class MPGONMRSpectrum;
@class MPGOIdentification;
@class MPGOQuantification;
@class MPGOProvenanceRecord;
@class MPGOTransitionList;
@class MPGOAccessPolicy;
@class MPGOHDF5Group;
@protocol MPGOStorageProvider;

/**
 * Root container for an MPEG-O `.mpgo` file. Owns a top-level `study/`
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
 *   Python: mpeg_o.spectral_dataset.SpectralDataset
 *   Java:   com.dtwthalion.mpgo.SpectralDataset
 */
@interface MPGOSpectralDataset : NSObject <MPGOEncryptable>

@property (readonly, copy) NSString *title;
@property (readonly, copy) NSString *isaInvestigationId;

@property (readonly, copy) NSDictionary<NSString *, MPGOAcquisitionRun *> *msRuns;
@property (readonly, copy) NSDictionary<NSString *, NSArray<MPGONMRSpectrum *> *> *nmrRuns;

@property (readonly, copy) NSArray<MPGOIdentification *>   *identifications;
@property (readonly, copy) NSArray<MPGOQuantification *>   *quantifications;
@property (readonly, copy) NSArray<MPGOProvenanceRecord *> *provenanceRecords;
@property (readonly, strong) MPGOTransitionList *transitions;       // nullable

- (instancetype)initWithTitle:(NSString *)title
           isaInvestigationId:(NSString *)isaId
                       msRuns:(NSDictionary *)msRuns
                      nmrRuns:(NSDictionary *)nmrRuns
              identifications:(NSArray *)identifications
              quantifications:(NSArray *)quantifications
            provenanceRecords:(NSArray *)provenance
                  transitions:(MPGOTransitionList *)transitions;

- (BOOL)writeToFilePath:(NSString *)path error:(NSError **)error;
+ (instancetype)readFromFilePath:(NSString *)path error:(NSError **)error;

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
@property (readonly, strong) id<MPGOStorageProvider> provider;

/** Provenance records whose inputRefs contain `ref`. */
- (NSArray<MPGOProvenanceRecord *> *)provenanceRecordsForInputRef:(NSString *)ref;

#pragma mark - MPGOEncryptable

- (BOOL)encryptWithKey:(NSData *)key
                 level:(MPGOEncryptionLevel)level
                 error:(NSError **)error;
- (BOOL)decryptWithKey:(NSData *)key error:(NSError **)error;
- (MPGOAccessPolicy *)accessPolicy;
- (void)setAccessPolicy:(MPGOAccessPolicy *)policy;

#pragma mark - Subclass hooks

/** Subclasses (e.g. MPGOMSImage) override to add their own datasets
 *  under /study/ after the base dataset has been written. The default
 *  is a no-op. Return NO to abort the write. */
- (BOOL)writeAdditionalStudyContent:(MPGOHDF5Group *)studyGroup
                              error:(NSError **)error;

/** Subclasses override to read their own datasets under /study/ after
 *  the base dataset has been loaded. Default is a no-op. */
- (BOOL)readAdditionalStudyContent:(MPGOHDF5Group *)studyGroup
                             error:(NSError **)error;

@end

#endif
