/*
 * TestMzTabWriter — v0.9+ mzTab exporter round-trip + dialect tests.
 */
#import <Foundation/Foundation.h>
#import "Testing.h"
#import <unistd.h>

#import "Export/TTIOMzTabWriter.h"
#import "Import/TTIOMzTabReader.h"
#import "Dataset/TTIOIdentification.h"
#import "Dataset/TTIOQuantification.h"


static NSString *tmpPath(NSString *suf) {
    return [NSString stringWithFormat:@"/tmp/ttio_mztab_%d_%@.mztab",
            (int)getpid(), suf];
}

static NSArray<TTIOIdentification *> *buildIdents(void) {
    return @[
        [[TTIOIdentification alloc] initWithRunName:@"run1"
                                      spectrumIndex:10
                                     chemicalEntity:@"sp|P12345|BSA_BOVIN"
                                    confidenceScore:0.95
                                      evidenceChain:@[@"[MS, MS:1001083, mascot, 1.0]"]],
        [[TTIOIdentification alloc] initWithRunName:@"run1"
                                      spectrumIndex:17
                                     chemicalEntity:@"sp|P67890|CRP_HUMAN"
                                    confidenceScore:0.82
                                      evidenceChain:@[]],
    ];
}

static NSArray<TTIOQuantification *> *buildQuants(void) {
    return @[
        [[TTIOQuantification alloc] initWithChemicalEntity:@"sp|P12345|BSA_BOVIN"
                                                 sampleRef:@"sample_A"
                                                 abundance:1234.5
                                       normalizationMethod:@""],
        [[TTIOQuantification alloc] initWithChemicalEntity:@"sp|P67890|CRP_HUMAN"
                                                 sampleRef:@"sample_A"
                                                 abundance:67.0
                                       normalizationMethod:@""],
        [[TTIOQuantification alloc] initWithChemicalEntity:@"sp|P12345|BSA_BOVIN"
                                                 sampleRef:@"sample_B"
                                                 abundance:2222.2
                                       normalizationMethod:@""],
    ];
}

void testMzTabWriter(void) {
    @autoreleasepool {
        // ── Proteomics 1.0 round-trip ─────────────────────────────────
        NSString *outP = tmpPath(@"proteomics");
        unlink([outP fileSystemRepresentation]);
        NSError *err = nil;
        TTIOMzTabWriteResult *res = [TTIOMzTabWriter writeToPath:outP
                                                   identifications:buildIdents()
                                                   quantifications:buildQuants()
                                                           version:@"1.0"
                                                             title:@"BSA digest"
                                                       description:nil
                                                             error:&err];
        PASS(res != nil, "proteomics writer succeeds");
        PASS([res.version isEqualToString:@"1.0"], "version 1.0 reported");
        PASS(res.nPSMRows == 2, "2 PSM rows emitted");
        PASS(res.nPRTRows == 2, "2 PRT rows emitted (grouped by protein)");
        PASS(res.nSMLRows == 0, "no SML rows in proteomics dialect");

        TTIOMzTabImport *imp = [TTIOMzTabReader readFromFilePath:outP error:&err];
        PASS(imp != nil, "TTIOMzTabReader re-parses our output");
        PASS([imp.version isEqualToString:@"1.0"], "version round-trips");
        PASS(imp.identifications.count == 2, "2 identifications round-trip");
        PASS(imp.quantifications.count == 3, "3 per-assay quantifications round-trip");

        // Sample labels must round-trip via assay[N]-sample_ref.
        NSMutableSet *sampleLabels = [NSMutableSet set];
        for (TTIOQuantification *q in imp.quantifications) {
            [sampleLabels addObject:q.sampleRef];
        }
        PASS([sampleLabels containsObject:@"sample_A"],
             "sample_A label round-trips via MTD");
        PASS([sampleLabels containsObject:@"sample_B"],
             "sample_B label round-trips via MTD");
        unlink([outP fileSystemRepresentation]);

        // ── Metabolomics 2.0.0-M round-trip ───────────────────────────
        NSString *outM = tmpPath(@"metabolomics");
        unlink([outM fileSystemRepresentation]);
        NSArray *mIdents = @[
            [[TTIOIdentification alloc] initWithRunName:@"metabolomics"
                                          spectrumIndex:0
                                         chemicalEntity:@"CHEBI:15365"
                                        confidenceScore:0.9
                                          evidenceChain:@[]],
        ];
        NSArray *mQuants = @[
            [[TTIOQuantification alloc] initWithChemicalEntity:@"CHEBI:15365"
                                                     sampleRef:@"S1"
                                                     abundance:10.0
                                           normalizationMethod:@""],
            [[TTIOQuantification alloc] initWithChemicalEntity:@"CHEBI:15365"
                                                     sampleRef:@"S2"
                                                     abundance:20.0
                                           normalizationMethod:@""],
        ];
        TTIOMzTabWriteResult *mres = [TTIOMzTabWriter writeToPath:outM
                                                    identifications:mIdents
                                                    quantifications:mQuants
                                                            version:@"2.0.0-M"
                                                              title:nil
                                                        description:nil
                                                              error:&err];
        PASS(mres != nil, "metabolomics writer succeeds");
        PASS(mres.nSMLRows == 1, "1 SML row emitted (one entity)");
        PASS(mres.nPSMRows == 0, "no PSM rows in metabolomics dialect");

        TTIOMzTabImport *mimp = [TTIOMzTabReader readFromFilePath:outM error:&err];
        PASS(mimp != nil, "metabolomics reader re-parses writer output");
        PASS([mimp.version isEqualToString:@"2.0.0-M"],
             "metabolomics version round-trips");
        PASS(mimp.quantifications.count == 2,
             "2 metabolomics quantifications round-trip");
        unlink([outM fileSystemRepresentation]);

        // ── unknown version rejected ──────────────────────────────────
        err = nil;
        TTIOMzTabWriteResult *bad = [TTIOMzTabWriter writeToPath:tmpPath(@"bad")
                                                  identifications:buildIdents()
                                                  quantifications:@[]
                                                          version:@"0.9"
                                                            title:nil
                                                      description:nil
                                                            error:&err];
        PASS(bad == nil, "unknown version rejected");
        PASS(err != nil, "error populated for unknown version");
    }
}
