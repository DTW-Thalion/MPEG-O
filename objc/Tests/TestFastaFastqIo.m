#import <Foundation/Foundation.h>
#import "Testing.h"
#import "Genomics/TTIOReferenceImport.h"
#import "Genomics/TTIOWrittenGenomicRun.h"
#import "Import/TTIOFastaReader.h"
#import "Import/TTIOFastqReader.h"
#import "Export/TTIOFastaWriter.h"
#import "Export/TTIOFastqWriter.h"
#import "ValueClasses/TTIOEnums.h"


static NSString *makeTempDir(void)
{
    NSString *dir = [NSTemporaryDirectory()
        stringByAppendingPathComponent:[[NSProcessInfo processInfo] globallyUniqueString]];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:NULL];
    return dir;
}

static void writeFile(NSString *path, NSString *contents)
{
    [contents writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
}


void testFastaFastqIo(void)
{
    NSString *tmp = makeTempDir();
    NSError *err = nil;

    // -------------------------------------------------- FASTA reference

    NSString *refFa = [tmp stringByAppendingPathComponent:@"ref.fa"];
    writeFile(refFa, @">chr1\nACGTACGT\nACGT\n>chr2\nGGGggg\n");

    TTIOReferenceImport *refIn =
        [TTIOFastaReader readReferenceFromPath:refFa uri:nil error:&err];
    PASS(refIn != nil, "FASTA reference parses");
    PASS([refIn.uri isEqualToString:@"ref"], "reference URI derived from filename");
    PASS(refIn.chromosomes.count == 2, "two chromosomes parsed");
    PASS([refIn.chromosomes[0] isEqualToString:@"chr1"], "chr1 first");
    NSData *expected = [@"ACGTACGTACGT" dataUsingEncoding:NSUTF8StringEncoding];
    PASS([refIn.sequences[0] isEqualToData:expected],
         "chr1 sequence concatenated across wrap");
    NSData *expected2 = [@"GGGggg" dataUsingEncoding:NSUTF8StringEncoding];
    PASS([refIn.sequences[1] isEqualToData:expected2],
         "chr2 case-preserving (lowercase soft-masking)");

    // MD5 round-trip
    NSData *md5a = refIn.md5;
    NSData *md5b = [TTIOReferenceImport
        computeMd5WithChromosomes:refIn.chromosomes
                        sequences:refIn.sequences];
    PASS([md5a isEqualToData:md5b], "computed MD5 matches stored MD5");
    PASS(md5a.length == 16, "MD5 is 16 bytes");

    // Write back, re-read, verify byte-for-byte content.
    NSString *refOut = [tmp stringByAppendingPathComponent:@"out.fa"];
    BOOL ok = [TTIOFastaWriter writeReference:refIn
                                       toPath:refOut
                                    lineWidth:4
                                   gzipOutput:0
                                     writeFai:YES
                                        error:&err];
    PASS(ok, "FASTA reference write succeeds");

    TTIOReferenceImport *refBack =
        [TTIOFastaReader readReferenceFromPath:refOut uri:@"ref" error:&err];
    PASS([refBack.md5 isEqualToData:refIn.md5],
         "reference round-trip preserves MD5");
    PASS([refBack.sequences[0] isEqualToData:refIn.sequences[0]],
         "round-trip preserves chr1 bytes");
    PASS([refBack.sequences[1] isEqualToData:refIn.sequences[1]],
         "round-trip preserves chr2 case");

    // .fai index
    NSString *fai = [refOut stringByAppendingString:@".fai"];
    NSString *faiBody = [NSString stringWithContentsOfFile:fai
                                                  encoding:NSASCIIStringEncoding
                                                     error:NULL];
    PASS([faiBody hasPrefix:@"chr1\t12\t6\t4\t5\n"],
         ".fai chr1 line layout matches samtools convention");

    // -------------------------------------------------- FASTA unaligned

    NSString *readsFa = [tmp stringByAppendingPathComponent:@"reads.fa"];
    writeFile(readsFa, @">read_1\nACGTACGT\n>read_2\nGGGGAAAA\n");
    TTIOWrittenGenomicRun *run =
        [TTIOFastaReader readUnalignedFromPath:readsFa
                                    sampleName:@"NA12878"
                                      platform:@""
                                  referenceUri:@""
                               acquisitionMode:TTIOAcquisitionModeGenomicWGS
                                         error:&err];
    PASS(run != nil, "FASTA unaligned-run parses");
    PASS([run.sampleName isEqualToString:@"NA12878"], "sample name recorded");
    PASS(run.readCount == 2, "two reads");
    const uint32_t *flags = run.flagsData.bytes;
    PASS(flags[0] == 4 && flags[1] == 4,
         "unaligned reads have flags == 4");

    // -------------------------------------------------- FASTQ Phred+33

    NSString *fq33 = [tmp stringByAppendingPathComponent:@"reads.fq"];
    writeFile(fq33, @"@r1\nACGT\n+\n????\n@r2\nGGGG\n+\n5555\n");
    uint8_t detected = 0;
    TTIOWrittenGenomicRun *fqRun =
        [TTIOFastqReader readFromPath:fq33
                          forcedPhred:0
                           sampleName:@"S1"
                             platform:@""
                         referenceUri:@""
                      acquisitionMode:TTIOAcquisitionModeGenomicWGS
                          outDetected:&detected
                                error:&err];
    PASS(fqRun != nil, "FASTQ parses");
    PASS(detected == 33, "Phred+33 auto-detected on '?' / '5' qualities");

    NSString *fqOut = [tmp stringByAppendingPathComponent:@"back.fq"];
    ok = [TTIOFastqWriter writeRun:fqRun
                            toPath:fqOut
                        gzipOutput:0
                       phredOffset:33
                             error:&err];
    PASS(ok, "FASTQ write succeeds");

    NSData *backBytes = [NSData dataWithContentsOfFile:fqOut];
    NSData *origBytes = [NSData dataWithContentsOfFile:fq33];
    PASS([backBytes isEqualToData:origBytes],
         "FASTQ -> .tio shape -> FASTQ byte-exact round-trip");

    // -------------------------------------------------- FASTQ auto-detect 64

    // Phred+64: bytes 64..104 only (no byte < 59).
    uint8_t qualBytesRaw[3] = { 104, 100, 80 };
    NSData *qualP64 = [NSData dataWithBytes:qualBytesRaw length:3];
    PASS([TTIOFastqReader detectPhredOffsetFromBytes:qualP64] == 64,
         "all-bytes-in-64..104 -> Phred+64 detected");

    uint8_t mixedRaw[4] = { 33, 50, 70, 80 };
    NSData *mixed = [NSData dataWithBytes:mixedRaw length:4];
    PASS([TTIOFastqReader detectPhredOffsetFromBytes:mixed] == 33,
         "byte < 59 forces Phred+33");

    // -------------------------------------------------- FASTQ Phred+64 normalise

    NSString *p64Path = [tmp stringByAppendingPathComponent:@"p64.fq"];
    NSString *p64Body = [NSString stringWithFormat:@"@r1\nACG\n+\n%c%c%c\n",
                            104, 100, 80];
    writeFile(p64Path, p64Body);
    detected = 0;
    TTIOWrittenGenomicRun *p64Run =
        [TTIOFastqReader readFromPath:p64Path
                          forcedPhred:0
                           sampleName:@""
                             platform:@""
                         referenceUri:@""
                      acquisitionMode:TTIOAcquisitionModeGenomicWGS
                          outDetected:&detected
                                error:&err];
    PASS(p64Run != nil, "FASTQ Phred+64 parses");
    PASS(detected == 64, "Phred+64 auto-detected on byte range 80..104");
    const uint8_t *q33 = p64Run.qualitiesData.bytes;
    PASS(q33[0] == 104 - 31 && q33[1] == 100 - 31 && q33[2] == 80 - 31,
         "Phred+64 qualities normalised to Phred+33 on read");
}
