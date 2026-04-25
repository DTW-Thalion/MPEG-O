/*
 * Licensed under the Apache License, Version 2.0.
 * SPDX-License-Identifier: Apache-2.0
 */

#ifndef TTIO_MZTAB_READER_H
#define TTIO_MZTAB_READER_H

#import <Foundation/Foundation.h>

@class TTIOFeature;
@class TTIOIdentification;
@class TTIOQuantification;

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
@interface TTIOMzTabImport : NSObject

@property (nonatomic, readonly, copy) NSString *version;
@property (nonatomic, readonly, copy) NSString *importDescription;
@property (nonatomic, readonly, copy) NSString *title;
/** ms_run index (1-based) → location URI from `MTD ms_run[N]-location`. */
@property (nonatomic, readonly, copy) NSDictionary<NSNumber *, NSString *> *msRunLocations;
@property (nonatomic, readonly, copy) NSArray<NSString *> *sampleRefs;
@property (nonatomic, readonly, copy) NSArray<NSString *> *software;
@property (nonatomic, readonly, copy) NSArray<NSString *> *searchEngines;
@property (nonatomic, readonly, copy) NSArray<TTIOIdentification *> *identifications;
@property (nonatomic, readonly, copy) NSArray<TTIOQuantification *> *quantifications;
@property (nonatomic, readonly, copy) NSArray<TTIOFeature *> *features;
@property (nonatomic, readonly, copy) NSString *sourcePath;

@property (nonatomic, readonly) BOOL isMetabolomics;

@end

/**
 * mzTab importer — v0.9 M60.
 *
 * Tab-separated text reader that maps PSM / PRT / SML rows into
 * {@link TTIOIdentification} and {@link TTIOQuantification} records
 * suitable for inclusion in an `.tio` container's compound
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
 * with an `NSError` in `TTIOMzTabReaderErrorDomain`.
 *
 * Cross-language equivalents:
 *   Python: ttio.importers.mztab
 *   Java:   com.dtwthalion.ttio.importers.MzTabReader
 */
@interface TTIOMzTabReader : NSObject

+ (nullable TTIOMzTabImport *)readFromFilePath:(NSString *)path
                                          error:(NSError **)error;

@end

extern NSString *const TTIOMzTabReaderErrorDomain;

typedef NS_ENUM(NSInteger, TTIOMzTabReaderErrorCode) {
    TTIOMzTabReaderErrorMissingFile     = 1,
    TTIOMzTabReaderErrorMissingVersion  = 2,
    TTIOMzTabReaderErrorParseFailed     = 3
};

NS_ASSUME_NONNULL_END

#endif /* TTIO_MZTAB_READER_H */
