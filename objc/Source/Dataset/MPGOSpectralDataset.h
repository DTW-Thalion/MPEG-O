#ifndef MPGO_SPECTRAL_DATASET_H
#define MPGO_SPECTRAL_DATASET_H

#import <Foundation/Foundation.h>

@class MPGOAcquisitionRun;
@class MPGONMRSpectrum;
@class MPGOIdentification;
@class MPGOQuantification;
@class MPGOProvenanceRecord;
@class MPGOTransitionList;

/**
 * Root container for an MPEG-O `.mpgo` file. Owns a top-level `study/`
 * group plus zero or more named MS acquisition runs, zero or more named
 * NMR-spectrum collections, and the dataset-wide identifications,
 * quantifications, provenance records, and (optionally) a transition list.
 *
 * Persistence is via -writeToFilePath:error: / +readFromFilePath:error:
 * which open or create the underlying HDF5 file directly.
 */
@interface MPGOSpectralDataset : NSObject

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

/** Provenance records whose inputRefs contain `ref`. */
- (NSArray<MPGOProvenanceRecord *> *)provenanceRecordsForInputRef:(NSString *)ref;

@end

#endif
