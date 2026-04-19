/*
 * Licensed under the Apache License, Version 2.0.
 * SPDX-License-Identifier: Apache-2.0
 */

#ifndef MPGO_MZTAB_READER_H
#define MPGO_MZTAB_READER_H

#import <Foundation/Foundation.h>

@class MPGOIdentification;
@class MPGOQuantification;

NS_ASSUME_NONNULL_BEGIN

/**
 * Result of parsing an mzTab file. Pure value object.
 *
 * Mode dispatch follows the `MTD mzTab-version` line per HANDOFF
 * binding decision 47:
 *
 *   - "1.0"      → proteomics dialect (PSM/PRT sections)
 *   - "2.0.0-M"  → metabolomics dialect (SML section)
 */
@interface MPGOMzTabImport : NSObject

@property (nonatomic, readonly, copy) NSString *version;
@property (nonatomic, readonly, copy) NSString *importDescription;
@property (nonatomic, readonly, copy) NSString *title;
/** ms_run index (1-based) → location URI from `MTD ms_run[N]-location`. */
@property (nonatomic, readonly, copy) NSDictionary<NSNumber *, NSString *> *msRunLocations;
@property (nonatomic, readonly, copy) NSArray<NSString *> *sampleRefs;
@property (nonatomic, readonly, copy) NSArray<NSString *> *software;
@property (nonatomic, readonly, copy) NSArray<NSString *> *searchEngines;
@property (nonatomic, readonly, copy) NSArray<MPGOIdentification *> *identifications;
@property (nonatomic, readonly, copy) NSArray<MPGOQuantification *> *quantifications;
@property (nonatomic, readonly, copy) NSString *sourcePath;

@property (nonatomic, readonly) BOOL isMetabolomics;

@end

/**
 * mzTab importer — v0.9 M60.
 *
 * Tab-separated text reader that maps PSM / PRT / SML rows into
 * {@link MPGOIdentification} and {@link MPGOQuantification} records
 * suitable for inclusion in an `.mpgo` container's compound
 * identification / quantification datasets.
 *
 * What is parsed:
 *   - MTD section: mzTab-version, description, ms_run[N]-location,
 *     assay[N]-sample_ref, study_variable[N]-description, software,
 *     psm_search_engine_score
 *   - PSM rows: protein accession (or peptide sequence as fallback),
 *     spectrum reference (ms_run[N]:scan=K), best search-engine
 *     score, search engine name + PSM_ID as evidence chain
 *   - PRT rows: protein abundance per assay column → quantifications
 *   - SML rows: metabolite database identifier + abundance per
 *     study-variable column
 *
 * What is ignored (v0.9):
 *   - PEH/PEP peptide-level quantification (deferred to v1.0+)
 *   - SFH/SMF small-molecule features
 *   - SEH/SME small-molecule evidence rows
 *
 * On malformed input the reader returns nil and populates `error`
 * with an `NSError` in `MPGOMzTabReaderErrorDomain`.
 *
 * Cross-language equivalents:
 *   Python: mpeg_o.importers.mztab
 *   Java:   com.dtwthalion.mpgo.importers.MzTabReader
 */
@interface MPGOMzTabReader : NSObject

+ (nullable MPGOMzTabImport *)readFromFilePath:(NSString *)path
                                          error:(NSError **)error;

@end

extern NSString *const MPGOMzTabReaderErrorDomain;

typedef NS_ENUM(NSInteger, MPGOMzTabReaderErrorCode) {
    MPGOMzTabReaderErrorMissingFile     = 1,
    MPGOMzTabReaderErrorMissingVersion  = 2,
    MPGOMzTabReaderErrorParseFailed     = 3
};

NS_ASSUME_NONNULL_END

#endif /* MPGO_MZTAB_READER_H */
