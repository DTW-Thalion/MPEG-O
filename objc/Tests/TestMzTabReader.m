/*
 * TestMzTabReader — v0.9 M60.
 *
 * Cross-language counterpart:
 *   python/tests/integration/test_mztab_import.py
 *   java/.../importers/MzTabReaderTest.java
 *
 * SPDX-License-Identifier: Apache-2.0
 */
#import <Foundation/Foundation.h>
#import "Testing.h"
#import <unistd.h>

#import "Import/TTIOMzTabReader.h"
#import "Dataset/TTIOIdentification.h"
#import "Dataset/TTIOQuantification.h"

static NSString *m60Path(NSString *suffix)
{
    return [NSString stringWithFormat:@"/tmp/ttio_test_m60_%d_%@.mztab",
            (int)getpid(), suffix];
}

static void rmFile(NSString *path) { [[NSFileManager defaultManager] removeItemAtPath:path error:NULL]; }

static NSString *proteomicsFixture(void)
{
    return @""
        "COM\tSynthetic mzTab 1.0 fixture for v0.9 M60.\n"
        "MTD\tmzTab-version\t1.0\n"
        "MTD\tdescription\tSynthetic BSA digest results\n"
        "MTD\tms_run[1]-location\tfile:///tmp/bsa_digest.mzML\n"
        "MTD\tsoftware[1]\t[MS, MS:1001456, X!Tandem, v2.4.0]\n"
        "MTD\tpsm_search_engine_score[1]\t[MS, MS:1001330, X!Tandem expect, ]\n"
        "MTD\tassay[1]-sample_ref\tsample[1]\n"
        "MTD\tassay[2]-sample_ref\tsample[2]\n"
        "\n"
        "PRH\taccession\tdescription\ttaxid\tspecies\tdatabase\tdatabase_version\tsearch_engine\tbest_search_engine_score[1]\tprotein_abundance_assay[1]\tprotein_abundance_assay[2]\n"
        "PRT\tP02769\tBovine serum albumin\t9913\tBos taurus\tUniProtKB\t2024_04\t[MS, MS:1001456, X!Tandem, v2.4.0]\t0.99\t123456.7\t98765.4\n"
        "\n"
        "PSH\tsequence\tPSM_ID\taccession\tunique\tdatabase\tdatabase_version\tsearch_engine\tsearch_engine_score[1]\tmodifications\tretention_time\tcharge\texp_mass_to_charge\tcalc_mass_to_charge\tpre\tpost\tstart\tend\tspectra_ref\n"
        "PSM\tDTHKSEIAHR\t1\tP02769\t1\tUniProtKB\t2024_04\t[MS, MS:1001456, X!Tandem, v2.4.0]\t0.95\tnull\t120.5\t2\t413.7\t413.69\tK\tI\t125\t134\tms_run[1]:scan=42\n"
        "PSM\tLVNELTEFAK\t2\tP02769\t1\tUniProtKB\t2024_04\t[MS, MS:1001456, X!Tandem, v2.4.0]\t0.88\tnull\t130.2\t2\t582.3\t582.29\tK\tS\t66\t75\tms_run[1]:scan=87\n"
        "PSM\tYICDNQDTISSK\t3\tP02769\t1\tUniProtKB\t2024_04\t[MS, MS:1001456, X!Tandem, v2.4.0]\t0.91\tnull\t150.8\t2\t701.4\t701.38\tK\tL\t209\t220\tms_run[1]:scan=152\n";
}

static NSString *metabolomicsFixture(void)
{
    return @""
        "MTD\tmzTab-version\t2.0.0-M\n"
        "MTD\tmzTab-ID\tMTBLS9999\n"
        "MTD\tdescription\tSynthetic metabolomics study\n"
        "MTD\tms_run[1]-location\tfile:///tmp/glucose_run.mzML\n"
        "MTD\tsoftware[1]\t[MS, MS:1003121, OpenMS, v3.0.0]\n"
        "MTD\tstudy_variable[1]-description\tcontrol\n"
        "MTD\tstudy_variable[2]-description\ttreatment\n"
        "\n"
        "SMH\tSML_ID\tdatabase_identifier\tchemical_formula\tsmiles\tinchi\tchemical_name\turi\tbest_id_confidence_measure\tbest_id_confidence_value\tabundance_study_variable[1]\tabundance_study_variable[2]\n"
        "SML\t1\tCHEBI:17234\tC6H12O6\tOC[C@H]1OC(O)[C@H](O)[C@@H](O)[C@@H]1O\tnull\tD-glucose\tnull\t[MS, MS:1003124, mass match,]\t0.95\t1.5e6\t2.1e6\n"
        "SML\t2\tCHEBI:30769\tC6H8O7\tOC(=O)CC(O)(CC(O)=O)C(O)=O\tnull\tcitric acid\tnull\t[MS, MS:1003124, mass match,]\t0.88\t8.2e5\t7.5e5\n";
}

void testMzTabReader(void)
{
    // ── Proteomics happy path ────────────────────────────────────────
    {
        NSString *path = m60Path(@"proteomics");
        [proteomicsFixture() writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];

        NSError *err = nil;
        TTIOMzTabImport *result = [TTIOMzTabReader readFromFilePath:path error:&err];
        PASS(result != nil, "proteomics: parse succeeds");
        PASS([result.version isEqualToString:@"1.0"], "proteomics: version 1.0");
        PASS(result.isMetabolomics == NO, "proteomics: isMetabolomics == NO");
        PASS([result.importDescription containsString:@"BSA"], "proteomics: description preserved");
        PASS([result.msRunLocations[@1] containsString:@"bsa_digest"], "proteomics: ms_run[1] location");

        PASS(result.identifications.count == 3, "proteomics: 3 PSMs");
        TTIOIdentification *first = result.identifications.firstObject;
        PASS([first.chemicalEntity isEqualToString:@"P02769"], "proteomics: PSM accession");
        PASS(fabs(first.confidenceScore - 0.95) < 1e-9, "proteomics: best score = 0.95");
        PASS([first.runName isEqualToString:@"bsa_digest"], "proteomics: run name from ms_run location");
        PASS(first.spectrumIndex == 42, "proteomics: spectrum index from spectra_ref");

        PASS(result.quantifications.count == 2, "proteomics: 2 PRT abundances");
        TTIOQuantification *q0 = result.quantifications[0];
        PASS([q0.chemicalEntity isEqualToString:@"P02769"], "proteomics: quant accession");
        PASS(q0.abundance > 0.0, "proteomics: quant abundance > 0");

        rmFile(path);
    }

    // ── Metabolomics dispatch ────────────────────────────────────────
    {
        NSString *path = m60Path(@"metabolomics");
        [metabolomicsFixture() writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];

        NSError *err = nil;
        TTIOMzTabImport *result = [TTIOMzTabReader readFromFilePath:path error:&err];
        PASS(result != nil, "metabolomics: parse succeeds");
        PASS([result.version isEqualToString:@"2.0.0-M"], "metabolomics: version 2.0.0-M");
        PASS(result.isMetabolomics == YES, "metabolomics: isMetabolomics == YES");
        PASS(result.identifications.count == 2, "metabolomics: 2 SML identifications");
        TTIOIdentification *glucose = result.identifications.firstObject;
        PASS([glucose.chemicalEntity isEqualToString:@"CHEBI:17234"], "metabolomics: glucose CHEBI id");
        PASS(fabs(glucose.confidenceScore - 0.95) < 1e-9, "metabolomics: confidence value");
        PASS(result.quantifications.count == 4, "metabolomics: 4 quantifications (2 metabolites x 2 study vars)");

        rmFile(path);
    }

    // ── Missing version → MissingVersion error ───────────────────────
    {
        NSString *path = m60Path(@"noversion");
        [@"MTD\tdescription\tno version line\n" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        NSError *err = nil;
        TTIOMzTabImport *result = [TTIOMzTabReader readFromFilePath:path error:&err];
        PASS(result == nil, "missing version: returns nil");
        PASS(err != nil && err.code == TTIOMzTabReaderErrorMissingVersion,
             "missing version: error code MissingVersion");
        rmFile(path);
    }

    // ── Missing file ─────────────────────────────────────────────────
    {
        NSError *err = nil;
        TTIOMzTabImport *result = [TTIOMzTabReader readFromFilePath:@"/tmp/__no_such__.mztab" error:&err];
        PASS(result == nil, "missing file: returns nil");
        PASS(err != nil && err.code == TTIOMzTabReaderErrorMissingFile,
             "missing file: error code MissingFile");
    }
}
