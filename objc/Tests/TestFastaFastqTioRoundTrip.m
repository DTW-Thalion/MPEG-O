/*
 * Full round-trip tests through the on-disk .tio container.
 *
 * The other suite (TestFastaFastqIo.m) covers the parser and writer
 * in memory only — FASTA/FASTQ → TTIOWrittenGenomicRun → FASTA/FASTQ.
 * This suite drives the full chain that real users hit:
 *
 *     FASTA / FASTQ
 *       → reader
 *       → +writeMinimalToPath:...   [writes .tio]
 *       → +readFromFilePath:...     [reads .tio]
 *       → writer
 *       → FASTA / FASTQ              (compare to input)
 *
 * The native libttio_rans library is required for genomic-run write
 * (NAME_TOKENIZED_V2 codec on the read_names channel). On the ObjC
 * build the library is linked at compile time, so these tests run
 * unconditionally inside the libTTIO test harness.
 *
 * SPDX-License-Identifier: Apache-2.0
 */
#import <Foundation/Foundation.h>
#import "Testing.h"
#import "Dataset/TTIOSpectralDataset.h"
#import "Genomics/TTIOAlignedRead.h"
#import "Genomics/TTIOGenomicRun.h"
#import "Genomics/TTIOWrittenGenomicRun.h"
#import "Import/TTIOFastaReader.h"
#import "Import/TTIOFastqReader.h"
#import "Export/TTIOFastaWriter.h"
#import "Export/TTIOFastqWriter.h"
#import "ValueClasses/TTIOEnums.h"


static NSString *makeTempDirRT(void)
{
    NSString *dir = [NSTemporaryDirectory()
        stringByAppendingPathComponent:[[NSProcessInfo processInfo] globallyUniqueString]];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:NULL];
    return dir;
}


void testFastaFastqTioRoundTrip(void)
{
    NSString *tmp = makeTempDirRT();
    NSError *err = nil;

    // ---------------------------------------------------------------- FASTQ

    NSString *srcFq = [tmp stringByAppendingPathComponent:@"src.fq"];
    NSString *fqBody =
        @"@r1\nACGTACGT\n+\n!!!!!!!!\n"
        @"@r2\nGGGGAAAA\n+\nIIIIJJJJ\n"
        @"@r3\nNNNN\n+\n????\n";
    [fqBody writeToFile:srcFq atomically:YES
               encoding:NSUTF8StringEncoding error:NULL];

    NSString *tioPath = [tmp stringByAppendingPathComponent:@"out.tio"];
    NSString *finalFq = [tmp stringByAppendingPathComponent:@"final.fq"];

    // Step 1: FASTQ -> TTIOWrittenGenomicRun
    TTIOWrittenGenomicRun *runIn =
        [TTIOFastqReader readFromPath:srcFq
                          forcedPhred:0
                           sampleName:@"S1"
                             platform:@""
                         referenceUri:@""
                      acquisitionMode:TTIOAcquisitionModeGenomicWGS
                           outDetected:NULL
                                error:&err];
    PASS(runIn != nil, "FASTQ parses to TTIOWrittenGenomicRun");

    // Step 2: WrittenGenomicRun -> .tio
    BOOL ok = [TTIOSpectralDataset
               writeMinimalToPath:tioPath
                             title:@""
                isaInvestigationId:@""
                            msRuns:@{}
                       genomicRuns:@{ @"genomic_0001": runIn }
                   identifications:nil
                   quantifications:nil
                 provenanceRecords:nil
                             error:&err];
    PASS(ok, "FASTQ-derived run writes to .tio");
    PASS([[NSFileManager defaultManager] fileExistsAtPath:tioPath],
         ".tio file exists on disk");

    // Step 3: open .tio and recover the run
    TTIOSpectralDataset *ds =
        [TTIOSpectralDataset readFromFilePath:tioPath error:&err];
    PASS(ds != nil, ".tio reads back");
    TTIOGenomicRun *runBack = ds.genomicRuns[@"genomic_0001"];
    PASS(runBack != nil, "genomic run 'genomic_0001' present");

    // Step 4: GenomicRun -> FASTQ
    ok = [TTIOFastqWriter writeReadSideRun:runBack
                                    toPath:finalFq
                                gzipOutput:0
                               phredOffset:33
                                     error:&err];
    PASS(ok, "FASTQ writes back from .tio");

    // Step 5: byte-exact round-trip
    NSData *origBytes = [NSData dataWithContentsOfFile:srcFq];
    NSData *finalBytes = [NSData dataWithContentsOfFile:finalFq];
    PASS([origBytes isEqualToData:finalBytes],
         "FASTQ -> .tio -> FASTQ byte-exact round-trip");

    // ---------------------------------------------------------------- FASTA unaligned

    NSString *srcPanel = [tmp stringByAppendingPathComponent:@"panel.fa"];
    [@">target_1\nACGTACGTACGT\n>target_2\nGGGGAAAA\n"
        writeToFile:srcPanel atomically:YES
            encoding:NSUTF8StringEncoding error:NULL];

    NSString *panelTio = [tmp stringByAppendingPathComponent:@"panel.tio"];
    NSString *finalPanel = [tmp stringByAppendingPathComponent:@"final.fa"];

    TTIOWrittenGenomicRun *panelIn =
        [TTIOFastaReader readUnalignedFromPath:srcPanel
                                    sampleName:@"panel"
                                      platform:@""
                                  referenceUri:@""
                               acquisitionMode:TTIOAcquisitionModeGenomicWGS
                                         error:&err];
    PASS(panelIn != nil, "FASTA panel parses");

    ok = [TTIOSpectralDataset
          writeMinimalToPath:panelTio
                       title:@""
          isaInvestigationId:@""
                      msRuns:@{}
                 genomicRuns:@{ @"genomic_0001": panelIn }
             identifications:nil
             quantifications:nil
           provenanceRecords:nil
                       error:&err];
    PASS(ok, "FASTA panel writes to .tio");

    TTIOSpectralDataset *panelDs =
        [TTIOSpectralDataset readFromFilePath:panelTio error:&err];
    PASS(panelDs != nil, "panel .tio reads back");
    TTIOGenomicRun *panelBack = panelDs.genomicRuns[@"genomic_0001"];
    PASS(panelBack != nil, "panel run present");

    ok = [TTIOFastaWriter writeReadSideRun:panelBack
                                    toPath:finalPanel
                                 lineWidth:60
                                gzipOutput:0
                                  writeFai:NO
                                     error:&err];
    PASS(ok, "FASTA writes back from .tio");

    NSData *origPanel = [NSData dataWithContentsOfFile:srcPanel];
    NSData *finalPanelBytes = [NSData dataWithContentsOfFile:finalPanel];
    PASS([origPanel isEqualToData:finalPanelBytes],
         "FASTA panel -> .tio -> FASTA byte-exact round-trip");
}
