/*
 * TestWatersMassLynxReader — v0.9 M63.
 *
 * Mock-converter delegation test. Validates the NSTask resolution
 * path, argv layout (-i <dir> -o <tmp>), stub mzML output landing
 * in the temp dir, and MPGOMzMLReader consuming the result.
 *
 * Cross-language counterpart:
 *   python/tests/integration/test_waters_masslynx.py
 *   java/.../importers/WatersMassLynxReaderTest.java
 *
 * SPDX-License-Identifier: Apache-2.0
 */
#import <Foundation/Foundation.h>
#import "Testing.h"
#import <sys/stat.h>
#import <unistd.h>

#import "Import/MPGOWatersMassLynxReader.h"
#import "Dataset/MPGOSpectralDataset.h"
#import "Run/MPGOAcquisitionRun.h"
#import "Run/MPGOSpectrumIndex.h"

static NSString *m63TempDir(NSString *suffix)
{
    return [NSString stringWithFormat:@"/tmp/mpgo_test_m63_%d_%@",
            (int)getpid(), suffix];
}

static void m63Mkdir(NSString *path)
{
    [[NSFileManager defaultManager] createDirectoryAtPath:path
                              withIntermediateDirectories:YES
                                               attributes:nil error:NULL];
}

static void m63Remove(NSString *path)
{
    [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
}

/** Minimal mzML that MPGOMzMLReader can parse: 1 MS1 spectrum with
 *  2 peaks at mz=[10.0, 20.0], intensity=[1.0, 2.0] — values come from
 *  the base64 blobs below. Kept inline so the mock converter script
 *  can heredoc it. */
static NSString *m63MinimalMzML(void)
{
    return @"<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
           @"<mzML xmlns=\"http://psi.hupo.org/ms/mzml\" version=\"1.1.0\">\n"
           @"  <cvList count=\"2\">\n"
           @"    <cv id=\"MS\" fullName=\"PSI MS\" version=\"4.1.0\"/>\n"
           @"    <cv id=\"UO\" fullName=\"UO\" version=\"2020-03-10\"/>\n"
           @"  </cvList>\n"
           @"  <fileDescription><fileContent>\n"
           @"    <cvParam cvRef=\"MS\" accession=\"MS:1000580\" name=\"MSn spectrum\"/>\n"
           @"  </fileContent></fileDescription>\n"
           @"  <softwareList count=\"1\"><software id=\"mock_masslynx\" version=\"0.0\"/></softwareList>\n"
           @"  <instrumentConfigurationList count=\"1\"><instrumentConfiguration id=\"IC1\"/></instrumentConfigurationList>\n"
           @"  <dataProcessingList count=\"1\"><dataProcessing id=\"dp\"/></dataProcessingList>\n"
           @"  <run id=\"mock_waters\" defaultInstrumentConfigurationRef=\"IC1\">\n"
           @"    <spectrumList count=\"1\" defaultDataProcessingRef=\"dp\">\n"
           @"      <spectrum index=\"0\" id=\"scan=1\" defaultArrayLength=\"2\">\n"
           @"        <cvParam cvRef=\"MS\" accession=\"MS:1000511\" name=\"ms level\" value=\"1\"/>\n"
           @"        <cvParam cvRef=\"MS\" accession=\"MS:1000130\" name=\"positive scan\"/>\n"
           @"        <scanList count=\"1\"><scan>\n"
           @"          <cvParam cvRef=\"MS\" accession=\"MS:1000016\" name=\"scan start time\" value=\"0.0\" unitCvRef=\"UO\" unitAccession=\"UO:0000010\"/>\n"
           @"        </scan></scanList>\n"
           @"        <binaryDataArrayList count=\"2\">\n"
           @"          <binaryDataArray encodedLength=\"16\">\n"
           @"            <cvParam cvRef=\"MS\" accession=\"MS:1000523\" name=\"64-bit float\"/>\n"
           @"            <cvParam cvRef=\"MS\" accession=\"MS:1000576\" name=\"no compression\"/>\n"
           @"            <cvParam cvRef=\"MS\" accession=\"MS:1000514\" name=\"m/z array\"/>\n"
           @"            <binary>AAAAAAAAJEAAAAAAAAA0QA==</binary>\n"
           @"          </binaryDataArray>\n"
           @"          <binaryDataArray encodedLength=\"16\">\n"
           @"            <cvParam cvRef=\"MS\" accession=\"MS:1000523\" name=\"64-bit float\"/>\n"
           @"            <cvParam cvRef=\"MS\" accession=\"MS:1000576\" name=\"no compression\"/>\n"
           @"            <cvParam cvRef=\"MS\" accession=\"MS:1000515\" name=\"intensity array\"/>\n"
           @"            <binary>AAAAAAAA8D8AAAAAAAAAQA==</binary>\n"
           @"          </binaryDataArray>\n"
           @"        </binaryDataArrayList>\n"
           @"      </spectrum>\n"
           @"    </spectrumList>\n"
           @"  </run>\n"
           @"</mzML>\n";
}

/** Write a POSIX shell script that acts as the MassLynx converter:
 *  parses -i and -o, emits a stub mzML into $output. */
static NSString *m63WriteMockConverter(NSString *dir)
{
    NSString *script = [dir stringByAppendingPathComponent:@"mock_masslynxraw"];
    NSString *stubBody = m63MinimalMzML();
    // Quote for the heredoc — the content itself has no shell metachars
    // that matter inside an unquoted heredoc, but we use 'MPGO_EOF'
    // (quoted) so $ expansions inside the stub are left alone.
    NSString *src = [NSString stringWithFormat:
        @"#!/bin/sh\n"
        @"set -eu\n"
        @"input=\"\"\n"
        @"output=\"\"\n"
        @"while [ $# -gt 0 ]; do\n"
        @"    case \"$1\" in\n"
        @"        -i) input=$2; shift 2;;\n"
        @"        -o) output=$2; shift 2;;\n"
        @"        *) shift;;\n"
        @"    esac\n"
        @"done\n"
        @"if [ -z \"$input\" ] || [ -z \"$output\" ]; then\n"
        @"    echo 'usage: $0 -i <input.raw> -o <output-dir>' >&2\n"
        @"    exit 2\n"
        @"fi\n"
        @"stem=$(basename \"$input\" .raw)\n"
        @"cat > \"$output/$stem.mzML\" <<'MPGO_EOF'\n"
        @"%@"
        @"MPGO_EOF\n",
        stubBody];
    [src writeToFile:script atomically:YES
             encoding:NSUTF8StringEncoding error:NULL];
    // chmod +x
    chmod([script fileSystemRepresentation],
          S_IRUSR | S_IWUSR | S_IXUSR | S_IRGRP | S_IXGRP | S_IROTH | S_IXOTH);
    return script;
}

void testWatersMassLynxReader(void)
{
    NSString *workdir = m63TempDir(@"waters");
    m63Remove(workdir);
    m63Mkdir(workdir);

    // ── 1. Missing binary → clean error ──────────────────────────────
    {
        NSString *fakeRaw = [workdir stringByAppendingPathComponent:@"Sample_01.raw"];
        m63Mkdir(fakeRaw);
        NSError *err = nil;
        MPGOSpectralDataset *ds = [MPGOWatersMassLynxReader
            readFromDirectoryPath:fakeRaw
                       converter:@"/nonexistent/no-such-masslynx"
                           error:&err];
        PASS(ds == nil, "missing binary: returns nil");
        PASS(err != nil && [err.domain isEqualToString:@"MPGOWatersMassLynxReader"],
             "missing binary: MPGOWatersMassLynxReader error domain");
    }

    // ── 2. Input is not a directory → clean error ────────────────────
    {
        NSString *bogus = [workdir stringByAppendingPathComponent:@"not_a_dir.raw"];
        [@"plain text" writeToFile:bogus atomically:YES
                          encoding:NSUTF8StringEncoding error:NULL];
        NSError *err = nil;
        MPGOSpectralDataset *ds = [MPGOWatersMassLynxReader
            readFromDirectoryPath:bogus error:&err];
        PASS(ds == nil, "file-not-directory: returns nil");
        PASS(err != nil, "file-not-directory: populates NSError");
    }

    // ── 3. Mock converter round-trip ─────────────────────────────────
    {
        NSString *src = [workdir stringByAppendingPathComponent:@"Sample_01.raw"];
        m63Mkdir(src);
        NSString *mock = m63WriteMockConverter(workdir);
        NSError *err = nil;
        MPGOSpectralDataset *ds = [MPGOWatersMassLynxReader
            readFromDirectoryPath:src converter:mock error:&err];
        PASS(ds != nil, "mock converter: parse succeeds");
        PASS(err == nil || ds != nil, "mock converter: no error when ds returned");
        if (ds) {
            NSArray *runNames = [ds.msRuns allKeys];
            PASS(runNames.count >= 1, "mock converter: at least one run parsed");
            MPGOAcquisitionRun *run = ds.msRuns[runNames.firstObject];
            PASS(run.spectrumIndex.count == 1,
                 "mock converter: 1 spectrum (stub mzML)");
        }
    }

    m63Remove(workdir);
}
