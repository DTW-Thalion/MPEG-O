#import <Foundation/Foundation.h>
#import "Testing.h"
#import "Dataset/MPGOFeature.h"
#import "Dataset/MPGOIdentification.h"
#import "Dataset/MPGOQuantification.h"
#import "Export/MPGOMzTabWriter.h"
#import "Import/MPGOMzTabReader.h"
#import <math.h>
#import <unistd.h>

// M78: MPGOFeature value class + mzTab PEH/PEP round-trip (1.0 dialect)
// + SFH/SMF/SEH/SME round-trip (2.0.0-M dialect). Mirrors the Python
// and Java M78 suites.

static NSString *m78ConformanceDir(void)
{
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *here = [fm currentDirectoryPath];
    for (int up = 0; up < 6; up++) {
        NSString *candidate = [[here
                stringByAppendingPathComponent:@"conformance"]
                stringByAppendingPathComponent:@"mztab_features"];
        BOOL isDir = NO;
        if ([fm fileExistsAtPath:candidate isDirectory:&isDir] && isDir) {
            return candidate;
        }
        here = [here stringByDeletingLastPathComponent];
        if ([here isEqualToString:@"/"] || here.length == 0) break;
    }
    return nil;
}

static NSString *tempPath(NSString *name)
{
    NSString *tmp = NSTemporaryDirectory();
    NSString *dir = [tmp stringByAppendingPathComponent:
        [NSString stringWithFormat:@"mpgo-m78-%d", getpid()]];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:NULL];
    return [dir stringByAppendingPathComponent:name];
}

static NSArray<MPGOFeature *> *mzTabPFeats(void)
{
    MPGOFeature *a = [[MPGOFeature alloc]
        initWithFeatureId:@"pep_1"
                  runName:@"run_a"
           chemicalEntity:@"AAAAPEPTIDER"
     retentionTimeSeconds:302.5
          expMassToCharge:615.3291
                   charge:2
                adductIon:@""
               abundances:@{@"sample_1": @1.5e6, @"sample_2": @2.25e6}
             evidenceRefs:@[@"ms_run[1]:scan=42"]];
    MPGOFeature *b = [[MPGOFeature alloc]
        initWithFeatureId:@"pep_2"
                  runName:@"run_a"
           chemicalEntity:@"QWERTYK"
     retentionTimeSeconds:450.1
          expMassToCharge:412.2012
                   charge:1
                adductIon:@""
               abundances:@{@"sample_1": @8.0e5}
             evidenceRefs:@[@"ms_run[1]:scan=51"]];
    return @[a, b];
}

static void mzTabMPayload(NSArray<MPGOFeature *> **outFeats,
                           NSArray<MPGOIdentification *> **outIdents)
{
    MPGOFeature *f1 = [[MPGOFeature alloc]
        initWithFeatureId:@"smf_1"
                  runName:@"metabolomics"
           chemicalEntity:@"CHEBI:15377"
     retentionTimeSeconds:85.3
          expMassToCharge:181.0707
                   charge:1
                adductIon:@"[M+H]1+"
               abundances:@{@"sample_a": @1.2e4, @"sample_b": @1.1e4}
             evidenceRefs:@[@"sme_1"]];
    MPGOFeature *f2 = [[MPGOFeature alloc]
        initWithFeatureId:@"smf_2"
                  runName:@"metabolomics"
           chemicalEntity:@"CHEBI:16865"
     retentionTimeSeconds:210.9
          expMassToCharge:147.0532
                   charge:1
                adductIon:@"[M+Na]1+"
               abundances:@{@"sample_a": @3.3e3}
             evidenceRefs:@[@"sme_2"]];
    *outFeats = @[f1, f2];

    MPGOIdentification *i1 = [[MPGOIdentification alloc]
        initWithRunName:@"metabolomics"
          spectrumIndex:0
         chemicalEntity:@"CHEBI:15377"
        confidenceScore:1.0
          evidenceChain:@[@"SME_ID=sme_1", @"name=glucose", @"formula=C6H12O6"]];
    MPGOIdentification *i2 = [[MPGOIdentification alloc]
        initWithRunName:@"metabolomics"
          spectrumIndex:0
         chemicalEntity:@"CHEBI:16865"
        confidenceScore:0.5
          evidenceChain:@[@"SME_ID=sme_2", @"name=glutamate"]];
    *outIdents = @[i1, i2];
}

// ── Value-class invariants ────────────────────────────────────────

static void testFeatureDefaultsAreEmpty(void)
{
    MPGOFeature *f = [MPGOFeature featureWithId:@"f1"
                                        runName:@"run_a"
                                 chemicalEntity:@"PEPTIDER"];
    pass([f.featureId isEqualToString:@"f1"], "featureId preserved");
    pass([f.runName isEqualToString:@"run_a"], "runName preserved");
    pass([f.chemicalEntity isEqualToString:@"PEPTIDER"], "chemicalEntity preserved");
    pass(f.retentionTimeSeconds == 0.0, "default retentionTimeSeconds is 0");
    pass(f.expMassToCharge == 0.0, "default expMassToCharge is 0");
    pass(f.charge == 0, "default charge is 0");
    pass([f.adductIon isEqualToString:@""], "default adductIon is empty");
    pass(f.abundances.count == 0, "default abundances is empty");
    pass(f.evidenceRefs.count == 0, "default evidenceRefs is empty");
}

static void testFeatureNilInputsCoerceToEmpty(void)
{
    MPGOFeature *f = [[MPGOFeature alloc]
        initWithFeatureId:@"f1"
                  runName:@"r"
           chemicalEntity:@"X"
     retentionTimeSeconds:0.0
          expMassToCharge:0.0
                   charge:0
                adductIon:nil
               abundances:nil
             evidenceRefs:nil];
    pass([f.adductIon isEqualToString:@""], "nil adductIon coerces to empty");
    pass(f.abundances.count == 0, "nil abundances coerces to empty");
    pass(f.evidenceRefs.count == 0, "nil evidenceRefs coerces to empty");
}

static void testFeatureEquality(void)
{
    MPGOFeature *a = [[MPGOFeature alloc]
        initWithFeatureId:@"f1" runName:@"r" chemicalEntity:@"X"
     retentionTimeSeconds:0.0 expMassToCharge:500.25 charge:2
                adductIon:@"" abundances:@{@"s1": @1.0}
             evidenceRefs:@[@"e1"]];
    MPGOFeature *b = [[MPGOFeature alloc]
        initWithFeatureId:@"f1" runName:@"r" chemicalEntity:@"X"
     retentionTimeSeconds:0.0 expMassToCharge:500.25 charge:2
                adductIon:@"" abundances:@{@"s1": @1.0}
             evidenceRefs:@[@"e1"]];
    pass([a isEqual:b], "equal features compare equal");
    pass(a.hash == b.hash, "equal features have same hash");
}

// ── mzTab-P 1.0: PEH/PEP round-trip ───────────────────────────────

static void testPepRoundTripPreservesFields(void)
{
    NSArray<MPGOFeature *> *feats = mzTabPFeats();
    NSString *out = tempPath(@"pep.mztab");
    NSError *err = nil;
    MPGOMzTabWriteResult *r = [MPGOMzTabWriter writeToPath:out
                                            identifications:@[]
                                            quantifications:@[]
                                                   features:feats
                                                    version:@"1.0"
                                                      title:@"M78 PEP round-trip"
                                                description:nil
                                                      error:&err];
    pass(r != nil && err == nil, "PEP write succeeded");
    pass(r.nPEPRows == 2, "nPEPRows == 2");
    pass(r.nPSMRows == 0, "nPSMRows == 0");

    MPGOMzTabImport *parsed = [MPGOMzTabReader readFromFilePath:out error:&err];
    pass(parsed != nil, "PEP parse succeeded");
    pass([parsed.version isEqualToString:@"1.0"], "round-trip version is 1.0");
    pass(parsed.features.count == 2, "two features round-trip");

    MPGOFeature *aaa = nil;
    for (MPGOFeature *f in parsed.features) {
        if ([f.chemicalEntity isEqualToString:@"AAAAPEPTIDER"]) { aaa = f; break; }
    }
    pass(aaa != nil, "AAAAPEPTIDER present after round-trip");
    pass(aaa.charge == 2, "charge round-trips");
    pass(fabs(aaa.expMassToCharge - 615.3291) < 1e-3, "m/z round-trips within 1e-3");
    pass(fabs(aaa.retentionTimeSeconds - 302.5) < 1e-3, "RT round-trips");
    NSArray<NSNumber *> *vals = [aaa.abundances.allValues sortedArrayUsingSelector:@selector(compare:)];
    pass(vals.count == 2, "two abundance values preserved");
    pass(fabs(vals[0].doubleValue - 1.5e6) < 1e3, "first abundance within 1e3");
    pass(fabs(vals[1].doubleValue - 2.25e6) < 1e3, "second abundance within 1e3");
}

static void testPepWriterAddsPehHeader(void)
{
    NSString *out = tempPath(@"pep_hdr.mztab");
    NSError *err = nil;
    [MPGOMzTabWriter writeToPath:out
                 identifications:@[]
                 quantifications:@[]
                        features:mzTabPFeats()
                         version:@"1.0"
                           title:nil
                     description:nil
                           error:&err];
    NSString *text = [NSString stringWithContentsOfFile:out encoding:NSUTF8StringEncoding error:NULL];
    pass([text rangeOfString:@"\nPEH\t"].location != NSNotFound
         || [text hasPrefix:@"PEH\t"], "PEH header present");

    NSString *pehLine = nil;
    for (NSString *ln in [text componentsSeparatedByString:@"\n"]) {
        if ([ln hasPrefix:@"PEH\t"]) { pehLine = ln; break; }
    }
    pass(pehLine != nil, "PEH line found");
    NSArray<NSString *> *cols = [pehLine componentsSeparatedByString:@"\t"];
    pass([cols containsObject:@"sequence"], "PEH has sequence");
    pass([cols containsObject:@"charge"], "PEH has charge");
    pass([cols containsObject:@"mass_to_charge"], "PEH has mass_to_charge");
    pass([cols containsObject:@"retention_time"], "PEH has retention_time");
    pass([cols containsObject:@"spectra_ref"], "PEH has spectra_ref");
    BOOL hasAbundance = NO;
    for (NSString *c in cols) {
        if ([c hasPrefix:@"peptide_abundance_assay["]) { hasAbundance = YES; break; }
    }
    pass(hasAbundance, "PEH has at least one peptide_abundance_assay[k] column");
}

static void testEmptyFeaturesEmitsNoPeh(void)
{
    NSString *out = tempPath(@"no_pep.mztab");
    MPGOIdentification *ident = [[MPGOIdentification alloc]
        initWithRunName:@"run_a" spectrumIndex:0
         chemicalEntity:@"PROT_X" confidenceScore:0.9
          evidenceChain:@[]];
    NSError *err = nil;
    [MPGOMzTabWriter writeToPath:out
                 identifications:@[ident]
                 quantifications:@[]
                        features:@[]
                         version:@"1.0"
                           title:nil
                     description:nil
                           error:&err];
    NSString *text = [NSString stringWithContentsOfFile:out encoding:NSUTF8StringEncoding error:NULL];
    pass([text rangeOfString:@"PEH\t"].location == NSNotFound, "no PEH header without features");
    pass([text rangeOfString:@"\nPEP\t"].location == NSNotFound, "no PEP rows without features");
}

// ── mzTab-M 2.0.0-M: SFH/SMF + SEH/SME round-trip ─────────────────

static void testSmfSmeRoundTripPreservesFields(void)
{
    NSArray<MPGOFeature *> *feats = nil;
    NSArray<MPGOIdentification *> *idents = nil;
    mzTabMPayload(&feats, &idents);
    NSString *out = tempPath(@"m.mztab");
    NSError *err = nil;
    MPGOMzTabWriteResult *r = [MPGOMzTabWriter writeToPath:out
                                            identifications:idents
                                            quantifications:@[]
                                                   features:feats
                                                    version:@"2.0.0-M"
                                                      title:nil
                                                description:nil
                                                      error:&err];
    pass(r != nil && err == nil, "SMF write succeeded");
    pass(r.nSMFRows == 2, "nSMFRows == 2");
    pass(r.nSMERows == 2, "nSMERows == 2");

    MPGOMzTabImport *parsed = [MPGOMzTabReader readFromFilePath:out error:&err];
    pass(parsed != nil, "SMF parse succeeded");
    pass([parsed.version isEqualToString:@"2.0.0-M"], "round-trip version is 2.0.0-M");
    pass(parsed.features.count == 2, "two features round-trip");

    MPGOFeature *glucose = nil;
    for (MPGOFeature *f in parsed.features) {
        if ([f.adductIon isEqualToString:@"[M+H]1+"]) { glucose = f; break; }
    }
    pass(glucose != nil, "[M+H]1+ feature present");
    pass(fabs(glucose.expMassToCharge - 181.0707) < 1e-3, "m/z round-trips");
    pass(fabs(glucose.retentionTimeSeconds - 85.3) < 1e-3, "RT round-trips");
    pass(glucose.charge == 1, "charge round-trips");
    pass([glucose.evidenceRefs containsObject:@"sme_1"], "evidenceRefs carry SME_ID");
    // After SME back-fill, chemical_entity resolves to CHEBI:15377.
    pass([glucose.chemicalEntity isEqualToString:@"CHEBI:15377"],
         "SME back-fill upgrades chemicalEntity to CHEBI:15377");
}

static void testSmfWriterAddsSfhAndSehHeaders(void)
{
    NSArray<MPGOFeature *> *feats = nil;
    NSArray<MPGOIdentification *> *idents = nil;
    mzTabMPayload(&feats, &idents);
    NSString *out = tempPath(@"m_hdr.mztab");
    NSError *err = nil;
    [MPGOMzTabWriter writeToPath:out
                 identifications:idents
                 quantifications:@[]
                        features:feats
                         version:@"2.0.0-M"
                           title:nil
                     description:nil
                           error:&err];
    NSString *text = [NSString stringWithContentsOfFile:out encoding:NSUTF8StringEncoding error:NULL];
    NSString *sfhLine = nil;
    BOOL sawSeh = NO;
    for (NSString *ln in [text componentsSeparatedByString:@"\n"]) {
        if ([ln hasPrefix:@"SFH\t"]) sfhLine = ln;
        else if ([ln hasPrefix:@"SEH\t"]) sawSeh = YES;
    }
    pass(sfhLine != nil, "SFH header present");
    pass(sawSeh, "SEH header present");
    NSArray<NSString *> *cols = [sfhLine componentsSeparatedByString:@"\t"];
    pass([cols containsObject:@"SMF_ID"], "SFH has SMF_ID");
    pass([cols containsObject:@"adduct_ion"], "SFH has adduct_ion");
    pass([cols containsObject:@"exp_mass_to_charge"], "SFH has exp_mass_to_charge");
    pass([cols containsObject:@"charge"], "SFH has charge");
    pass([cols containsObject:@"retention_time_in_seconds"], "SFH has retention_time_in_seconds");
}

static void testSmeEmitsRankFromConfidence(void)
{
    NSArray<MPGOFeature *> *feats = nil;
    NSArray<MPGOIdentification *> *idents = nil;
    mzTabMPayload(&feats, &idents);
    NSString *out = tempPath(@"m_rank.mztab");
    NSError *err = nil;
    [MPGOMzTabWriter writeToPath:out
                 identifications:idents
                 quantifications:@[]
                        features:feats
                         version:@"2.0.0-M"
                           title:nil
                     description:nil
                           error:&err];
    NSString *text = [NSString stringWithContentsOfFile:out encoding:NSUTF8StringEncoding error:NULL];
    NSMutableArray<NSNumber *> *ranks = [NSMutableArray array];
    for (NSString *ln in [text componentsSeparatedByString:@"\n"]) {
        if (![ln hasPrefix:@"SME\t"]) continue;
        NSArray<NSString *> *cols = [ln componentsSeparatedByString:@"\t"];
        [ranks addObject:@([cols.lastObject integerValue])];
    }
    pass(ranks.count == 2, "exactly two SME rows emitted");
    [ranks sortUsingSelector:@selector(compare:)];
    pass([ranks[0] integerValue] == 1, "rank 1 (confidence 1.0)");
    pass([ranks[1] integerValue] == 2, "rank 2 (confidence 0.5)");
}

static void testEmptyFeaturesMetabolomicsOmitsSfh(void)
{
    NSString *out = tempPath(@"m_plain.mztab");
    MPGOIdentification *ident = [[MPGOIdentification alloc]
        initWithRunName:@"metabolomics" spectrumIndex:0
         chemicalEntity:@"CHEBI:15377" confidenceScore:0.9
          evidenceChain:@[]];
    MPGOQuantification *q = [[MPGOQuantification alloc]
        initWithChemicalEntity:@"CHEBI:15377"
                     sampleRef:@"sample_a"
                     abundance:1.0e4
           normalizationMethod:@""];
    NSError *err = nil;
    [MPGOMzTabWriter writeToPath:out
                 identifications:@[ident]
                 quantifications:@[q]
                        features:@[]
                         version:@"2.0.0-M"
                           title:nil
                     description:nil
                           error:&err];
    NSString *text = [NSString stringWithContentsOfFile:out encoding:NSUTF8StringEncoding error:NULL];
    pass([text rangeOfString:@"SFH\t"].location == NSNotFound, "no SFH without features");
    pass([text rangeOfString:@"\nSMF\t"].location == NSNotFound, "no SMF rows without features");
    pass([text rangeOfString:@"SML\t"].location != NSNotFound, "SML row still present");
}

// ── Cross-language conformance fixture ────────────────────────────

static void testProteomicsConformanceFixture(void)
{
    NSString *dir = m78ConformanceDir();
    if (!dir) {
        pass(YES, "skip: conformance/mztab_features not reachable from CWD");
        return;
    }
    NSString *path = [dir stringByAppendingPathComponent:@"proteomics.mztab"];
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        pass(YES, "skip: proteomics.mztab fixture missing");
        return;
    }
    NSError *err = nil;
    MPGOMzTabImport *parsed = [MPGOMzTabReader readFromFilePath:path error:&err];
    pass(parsed != nil && err == nil, "proteomics fixture parses");
    pass([parsed.version isEqualToString:@"1.0"], "proteomics fixture is 1.0");
    pass(parsed.features.count == 2, "two peptide features");
    NSMutableDictionary<NSString *, MPGOFeature *> *bySeq = [NSMutableDictionary dictionary];
    for (MPGOFeature *f in parsed.features) bySeq[f.chemicalEntity] = f;
    pass(bySeq[@"AAAAPEPTIDER"] != nil, "AAAAPEPTIDER present");
    pass(bySeq[@"QWERTYK"] != nil, "QWERTYK present");
    pass(bySeq[@"AAAAPEPTIDER"].charge == 2, "AAAAPEPTIDER charge 2");
    pass(fabs(bySeq[@"AAAAPEPTIDER"].expMassToCharge - 615.329) < 1.0,
         "AAAAPEPTIDER m/z ≈ 615.329");
    pass(bySeq[@"QWERTYK"].charge == 1, "QWERTYK charge 1");
}

static void testMetabolomicsConformanceFixture(void)
{
    NSString *dir = m78ConformanceDir();
    if (!dir) {
        pass(YES, "skip: conformance/mztab_features not reachable from CWD");
        return;
    }
    NSString *path = [dir stringByAppendingPathComponent:@"metabolomics.mztab"];
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        pass(YES, "skip: metabolomics.mztab fixture missing");
        return;
    }
    NSError *err = nil;
    MPGOMzTabImport *parsed = [MPGOMzTabReader readFromFilePath:path error:&err];
    pass(parsed != nil && err == nil, "metabolomics fixture parses");
    pass([parsed.version isEqualToString:@"2.0.0-M"], "metabolomics fixture is 2.0.0-M");
    pass(parsed.features.count == 2, "two small-molecule features");
    NSMutableDictionary<NSString *, MPGOFeature *> *byAdduct = [NSMutableDictionary dictionary];
    for (MPGOFeature *f in parsed.features) byAdduct[f.adductIon] = f;
    pass(byAdduct[@"[M+H]1+"] != nil, "[M+H]1+ present");
    pass(byAdduct[@"[M+Na]1+"] != nil, "[M+Na]1+ present");
    pass([byAdduct[@"[M+H]1+"].chemicalEntity isEqualToString:@"CHEBI:15377"],
         "SME back-fill: [M+H]1+ → CHEBI:15377");
    pass([byAdduct[@"[M+Na]1+"].chemicalEntity isEqualToString:@"CHEBI:16865"],
         "SME back-fill: [M+Na]1+ → CHEBI:16865");
}

static void testMetabolomicsConformanceSmeConfidence(void)
{
    NSString *dir = m78ConformanceDir();
    if (!dir) {
        pass(YES, "skip: conformance/mztab_features not reachable from CWD");
        return;
    }
    NSString *path = [dir stringByAppendingPathComponent:@"metabolomics.mztab"];
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        pass(YES, "skip: metabolomics.mztab fixture missing");
        return;
    }
    NSError *err = nil;
    MPGOMzTabImport *parsed = [MPGOMzTabReader readFromFilePath:path error:&err];
    pass(parsed != nil && err == nil, "metabolomics fixture parses");

    NSMutableArray<NSNumber *> *smeConfs = [NSMutableArray array];
    for (MPGOIdentification *i in parsed.identifications) {
        BOOL hasSmeTag = NO;
        for (NSString *e in i.evidenceChain) {
            if ([e hasPrefix:@"SME_ID="]) { hasSmeTag = YES; break; }
        }
        if (hasSmeTag) [smeConfs addObject:@(i.confidenceScore)];
    }
    pass(smeConfs.count == 2, "two SME-tagged identifications");
    [smeConfs sortUsingComparator:^NSComparisonResult(NSNumber *a, NSNumber *b) {
        return [b compare:a];  // descending
    }];
    pass(fabs(smeConfs[0].doubleValue - 1.0) < 1e-6, "top SME confidence 1.0");
    pass(fabs(smeConfs[1].doubleValue - 0.5) < 1e-6, "second SME confidence 0.5");
}

void testMilestone78(void)
{
    testFeatureDefaultsAreEmpty();
    testFeatureNilInputsCoerceToEmpty();
    testFeatureEquality();
    testPepRoundTripPreservesFields();
    testPepWriterAddsPehHeader();
    testEmptyFeaturesEmitsNoPeh();
    testSmfSmeRoundTripPreservesFields();
    testSmfWriterAddsSfhAndSehHeaders();
    testSmeEmitsRankFromConfidence();
    testEmptyFeaturesMetabolomicsOmitsSfh();
    testProteomicsConformanceFixture();
    testMetabolomicsConformanceFixture();
    testMetabolomicsConformanceSmeConfidence();
}
