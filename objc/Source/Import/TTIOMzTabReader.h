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
 * <heading>TTIOMzTabImport</heading>
 *
 * <p><em>Inherits From:</em> NSObject</p>
 * <p><em>Conforms To:</em> NSObject (NSObject)</p>
 * <p><em>Declared In:</em> Import/TTIOMzTabReader.h</p>
 *
 * <p>Result of parsing an mzTab file. Pure value object.</p>
 *
 * <p>Mode dispatch follows the <code>MTD mzTab-version</code>
 * line:</p>
 *
 * <ul>
 *  <li><code>"1.0"</code> &rarr; proteomics dialect (PSM/PRT
 *      sections).</li>
 *  <li><code>"2.0.0-M"</code> &rarr; metabolomics dialect (SML
 *      section).</li>
 * </ul>
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
 * <heading>TTIOMzTabReader</heading>
 *
 * <p><em>Inherits From:</em> NSObject</p>
 * <p><em>Conforms To:</em> NSObject (NSObject)</p>
 * <p><em>Declared In:</em> Import/TTIOMzTabReader.h</p>
 *
 * <p>Tab-separated text reader that maps PSM / PRT / SML rows into
 * <code>TTIOIdentification</code> and
 * <code>TTIOQuantification</code> records suitable for inclusion in
 * an <code>.tio</code> container's compound identification /
 * quantification datasets.</p>
 *
 * <p><strong>What is parsed:</strong></p>
 * <ul>
 *  <li>MTD section: <code>mzTab-version</code>,
 *      <code>description</code>,
 *      <code>ms_run[N]-location</code>,
 *      <code>assay[N]-sample_ref</code>,
 *      <code>study_variable[N]-description</code>,
 *      <code>software</code>, <code>psm_search_engine_score</code>.</li>
 *  <li>PSM rows: protein accession (or peptide sequence as fallback),
 *      spectrum reference (<code>ms_run[N]:scan=K</code>), best
 *      search-engine score, search engine name + PSM_ID as evidence
 *      chain.</li>
 *  <li>PRT rows: protein abundance per assay column &rarr;
 *      quantifications.</li>
 *  <li>SML rows: metabolite database identifier + abundance per
 *      study-variable column.</li>
 * </ul>
 *
 * <p><strong>What is ignored:</strong></p>
 * <ul>
 *  <li>PEH / PEP peptide-level quantification.</li>
 *  <li>SFH / SMF small-molecule features.</li>
 *  <li>SEH / SME small-molecule evidence rows.</li>
 * </ul>
 *
 * <p>On malformed input the reader returns <code>nil</code> and
 * populates <code>error</code> with an <code>NSError</code> in
 * <code>TTIOMzTabReaderErrorDomain</code>.</p>
 *
 * <p><strong>API status:</strong> Provisional.</p>
 *
 * <p><strong>Cross-language equivalents:</strong><br/>
 * Python: <code>ttio.importers.mztab</code><br/>
 * Java: <code>global.thalion.ttio.importers.MzTabReader</code></p>
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
