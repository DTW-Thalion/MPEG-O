// Milestone 27: ISA-Tab / ISA-JSON exporter.
//
// Verifies:
//   * bundleForDataset: emits the expected four file names for a
//     single-run dataset (i_investigation.txt, s_study.txt,
//     a_assay_ms_<run>.txt, investigation.json).
//   * investigation TSV contains the dataset title, id, and the assay
//     technology type.
//   * study TSV has one sample row per run.
//   * assay TSV lists derived files when chromatograms are present.
//   * investigation.json parses and carries the expected identifier,
//     title, studies[0].assays[0].measurementType.annotationValue.
//   * writeBundleForDataset: writes all files to disk.

#import <Foundation/Foundation.h>
#import "Testing.h"
#import "Core/MPGOSignalArray.h"
#import "Dataset/MPGOSpectralDataset.h"
#import "Export/MPGOISAExporter.h"
#import "Run/MPGOAcquisitionRun.h"
#import "Run/MPGOInstrumentConfig.h"
#import "Spectra/MPGOChromatogram.h"
#import "Spectra/MPGOMassSpectrum.h"
#import "ValueClasses/MPGOEncodingSpec.h"
#import "ValueClasses/MPGOEnums.h"
#import <unistd.h>
#import <sys/stat.h>

static NSString *m27TempDir(NSString *suffix)
{
    return [NSString stringWithFormat:@"/tmp/mpgo_test_m27_%d_%@",
            (int)getpid(), suffix];
}

static MPGOSignalArray *m27Array(const double *values, NSUInteger n)
{
    MPGOEncodingSpec *spec =
        [MPGOEncodingSpec specWithPrecision:MPGOPrecisionFloat64
                       compressionAlgorithm:MPGOCompressionZlib
                                  byteOrder:MPGOByteOrderLittleEndian];
    NSData *buf = [NSData dataWithBytes:values length:n * sizeof(double)];
    return [[MPGOSignalArray alloc] initWithBuffer:buf length:n encoding:spec axis:nil];
}

static MPGOSpectralDataset *m27MakeDataset(BOOL withChromatograms)
{
    double mz[]  = { 100.0, 200.0, 300.0 };
    double it[]  = { 10.0,  20.0,  30.0 };
    MPGOSignalArray *mzArr = m27Array(mz, 3);
    MPGOSignalArray *inArr = m27Array(it, 3);
    MPGOMassSpectrum *s =
        [[MPGOMassSpectrum alloc] initWithMzArray:mzArr intensityArray:inArr
                                            msLevel:1 polarity:MPGOPolarityPositive
                                         scanWindow:nil indexPosition:0
                                    scanTimeSeconds:1.0
                                        precursorMz:0.0 precursorCharge:0
                                              error:NULL];

    MPGOInstrumentConfig *cfg =
        [[MPGOInstrumentConfig alloc] initWithManufacturer:@"Thermo"
                                                     model:@"Orbitrap Exploris 480"
                                              serialNumber:@"SN-001"
                                                sourceType:@"electrospray ionization"
                                              analyzerType:@"orbitrap"
                                              detectorType:@"electron multiplier"];

    NSArray *chroms = @[];
    if (withChromatograms) {
        double t[]  = { 0.0, 1.0, 2.0 };
        double iv[] = { 100.0, 500.0, 200.0 };
        MPGOSignalArray *tArr = m27Array(t, 3);
        MPGOSignalArray *iArr = m27Array(iv, 3);
        MPGOChromatogram *c = [[MPGOChromatogram alloc]
            initWithTimeArray:tArr intensityArray:iArr
                          type:MPGOChromatogramTypeTIC
                      targetMz:0.0 precursorMz:0.0 productMz:0.0 error:NULL];
        chroms = @[c];
    }

    MPGOAcquisitionRun *run =
        [[MPGOAcquisitionRun alloc] initWithSpectra:@[s]
                                      chromatograms:chroms
                                    acquisitionMode:MPGOAcquisitionModeMS1DDA
                                   instrumentConfig:cfg];

    return [[MPGOSpectralDataset alloc]
        initWithTitle:@"M27 Investigation"
   isaInvestigationId:@"ISA-M27-001"
               msRuns:@{ @"run_0001": run }
              nmrRuns:@{}
      identifications:@[]
      quantifications:@[]
    provenanceRecords:@[]
          transitions:nil];
}

void testMilestone27(void)
{
    // ---- minimal dataset: bundle contents ----
    {
        MPGOSpectralDataset *ds = m27MakeDataset(NO);
        NSError *err = nil;
        NSDictionary *bundle = [MPGOISAExporter bundleForDataset:ds error:&err];
        PASS(bundle != nil, "M27: bundleForDataset succeeds");
        PASS(bundle[@"i_investigation.txt"] != nil, "M27: i_investigation.txt present");
        PASS(bundle[@"s_study.txt"] != nil, "M27: s_study.txt present");
        PASS(bundle[@"a_assay_ms_run_0001.txt"] != nil, "M27: per-run assay file present");
        PASS(bundle[@"investigation.json"] != nil, "M27: investigation.json present");

        NSString *inv = [[NSString alloc] initWithData:bundle[@"i_investigation.txt"]
                                                 encoding:NSUTF8StringEncoding];
        PASS([inv rangeOfString:@"ISA-M27-001"].location != NSNotFound,
             "M27: investigation TSV contains the identifier");
        PASS([inv rangeOfString:@"M27 Investigation"].location != NSNotFound,
             "M27: investigation TSV contains the title");
        PASS([inv rangeOfString:@"mass spectrometry"].location != NSNotFound,
             "M27: investigation TSV names the technology type");

        // v0.9 M64: ISA-Tab requires all 11 section headers; previously
        // the exporter emitted only 4 of 11. isatools halts at the first
        // missing required section.
        NSArray *requiredSections = @[
            @"ONTOLOGY SOURCE REFERENCE\n",
            @"INVESTIGATION\n",
            @"INVESTIGATION PUBLICATIONS\n",
            @"INVESTIGATION CONTACTS\n",
            @"STUDY\n",
            @"STUDY DESIGN DESCRIPTORS\n",
            @"STUDY PUBLICATIONS\n",
            @"STUDY FACTORS\n",
            @"STUDY ASSAYS\n",
            @"STUDY PROTOCOLS\n",
            @"STUDY CONTACTS\n",
        ];
        for (NSString *section in requiredSections) {
            NSString *msg = [NSString stringWithFormat:
                @"M27 v0.9: investigation file carries '%@'",
                [section stringByTrimmingCharactersInSet:
                    NSCharacterSet.whitespaceAndNewlineCharacterSet]];
            PASS([inv rangeOfString:section].location != NSNotFound,
                 "%s", [msg UTF8String]);
        }

        // STUDY PROTOCOLS must declare every Protocol REF used in the
        // s_study.txt + a_assay_ms_*.txt files.
        NSRange protocolsStart = [inv rangeOfString:@"STUDY PROTOCOLS\n"];
        NSRange contactsStart = [inv rangeOfString:@"STUDY CONTACTS\n"];
        if (protocolsStart.location != NSNotFound
            && contactsStart.location != NSNotFound) {
            NSString *protocolBlock =
                [inv substringWithRange:NSMakeRange(
                    protocolsStart.location,
                    contactsStart.location - protocolsStart.location)];
            PASS([protocolBlock rangeOfString:@"sample collection"].location != NSNotFound,
                 "M27 v0.9: STUDY PROTOCOLS declares 'sample collection'");
            PASS([protocolBlock rangeOfString:@"mass spectrometry"].location != NSNotFound,
                 "M27 v0.9: STUDY PROTOCOLS declares 'mass spectrometry'");
        }

        NSString *study = [[NSString alloc] initWithData:bundle[@"s_study.txt"]
                                                   encoding:NSUTF8StringEncoding];
        PASS([study rangeOfString:@"sample_run_0001"].location != NSNotFound,
             "M27: study TSV has the sample row");

        NSError *jerr = nil;
        id parsed = [NSJSONSerialization JSONObjectWithData:bundle[@"investigation.json"]
                                                     options:0 error:&jerr];
        PASS([parsed isKindOfClass:[NSDictionary class]],
             "M27: investigation.json parses as dict");
        PASS([parsed[@"identifier"] isEqualToString:@"ISA-M27-001"],
             "M27: ISA-JSON identifier");
        NSArray *studies = parsed[@"studies"];
        PASS([studies isKindOfClass:[NSArray class]] && studies.count == 1,
             "M27: ISA-JSON has one study");
        NSArray *assays = studies[0][@"assays"];
        PASS(assays.count == 1, "M27: one assay in the study");
        PASS([assays[0][@"technologyType"][@"annotationValue"]
                  isEqualToString:@"mass spectrometry"],
             "M27: assay technology type is mass spectrometry");
    }

    // ---- dataset with chromatograms: derived file listed ----
    {
        MPGOSpectralDataset *ds = m27MakeDataset(YES);
        NSError *err = nil;
        NSDictionary *bundle = [MPGOISAExporter bundleForDataset:ds error:&err];
        NSString *assay = [[NSString alloc] initWithData:bundle[@"a_assay_ms_run_0001.txt"]
                                                   encoding:NSUTF8StringEncoding];
        PASS([assay rangeOfString:@"run_0001_chrom_0"].location != NSNotFound,
             "M27: assay TSV lists the chromatogram derived file");
    }

    // ---- writeBundleForDataset: ----
    {
        NSString *dir = m27TempDir(@"bundle");
        [[NSFileManager defaultManager] removeItemAtPath:dir error:NULL];

        MPGOSpectralDataset *ds = m27MakeDataset(NO);
        NSError *err = nil;
        BOOL ok = [MPGOISAExporter writeBundleForDataset:ds
                                              toDirectory:dir
                                                    error:&err];
        PASS(ok == YES, "M27: writeBundleForDataset returns YES");

        struct stat st;
        NSString *invPath = [dir stringByAppendingPathComponent:@"i_investigation.txt"];
        PASS(stat([invPath fileSystemRepresentation], &st) == 0,
             "M27: i_investigation.txt exists on disk");

        [[NSFileManager defaultManager] removeItemAtPath:dir error:NULL];
    }
}
