/*
 * Licensed under the Apache License, Version 2.0.
 * See LICENSE-IMPORT-EXPORT in the repository root.
 *
 * SPDX-License-Identifier: Apache-2.0
 */

#import "MPGOMzMLWriter.h"

#import "Core/MPGOSignalArray.h"
#import "Dataset/MPGOSpectralDataset.h"
#import "Run/MPGOAcquisitionRun.h"
#import "Run/MPGOSpectrumIndex.h"
#import "Spectra/MPGOMassSpectrum.h"
#import "Spectra/MPGOChromatogram.h"
#import "ValueClasses/MPGOEnums.h"
#import "ValueClasses/MPGOValueRange.h"
#import "Import/MPGOBase64.h"

#pragma mark - Helpers

/**
 * Append a UTF-8-encoded NSString to the given mutable data buffer.
 *
 * All text written by the writer goes through this function so that
 * byte offsets tracked during emission match the final file layout
 * exactly. The mzML spec requires UTF-8.
 */
static void appendUTF8(NSMutableData *buf, NSString *s)
{
    const char *c = [s UTF8String];
    if (!c) return;
    [buf appendBytes:c length:strlen(c)];
}

/** Escape the five XML special characters. mzML element text is rare
 *  (only ``<binary>`` content which is already base64) so this helper
 *  exists mainly for attribute values. */
static NSString *xmlEscape(NSString *s)
{
    if (!s) return @"";
    NSMutableString *out = [NSMutableString stringWithCapacity:s.length];
    for (NSUInteger i = 0; i < s.length; i++) {
        unichar c = [s characterAtIndex:i];
        switch (c) {
            case '&':  [out appendString:@"&amp;"];  break;
            case '<':  [out appendString:@"&lt;"];   break;
            case '>':  [out appendString:@"&gt;"];   break;
            case '"':  [out appendString:@"&quot;"]; break;
            case '\'': [out appendString:@"&apos;"]; break;
            default:   [out appendFormat:@"%C", c];  break;
        }
    }
    return out;
}

/** Format a float64 value with 15 significant digits so the binary
 *  round-trip (which is what carries the actual precision) is paired
 *  with a human-readable attribute string that also survives a text
 *  round trip. */
static NSString *fmtDouble(double v)
{
    return [NSString stringWithFormat:@"%.15g", v];
}

#pragma mark - Reverse CV mapping

static NSString *precisionAccession(BOOL useFloat32)
{
    // MS:1000521 = 32-bit float, MS:1000523 = 64-bit float
    return useFloat32 ? @"MS:1000521" : @"MS:1000523";
}

static NSString *precisionName(BOOL useFloat32)
{
    return useFloat32 ? @"32-bit float" : @"64-bit float";
}

#pragma mark - Writer core

@implementation MPGOMzMLWriter

+ (NSData *)dataForDataset:(MPGOSpectralDataset *)dataset
           zlibCompression:(BOOL)zlibCompression
                     error:(NSError **)error
{
    if (!dataset) {
        if (error) *error = [NSError errorWithDomain:@"MPGOMzMLWriter"
                                                  code:1
                                              userInfo:@{NSLocalizedDescriptionKey:
                                                          @"nil dataset"}];
        return nil;
    }

    // Pick the first run whose spectrumClassName is MPGOMassSpectrum.
    NSArray *runNames = [[dataset.msRuns allKeys]
        sortedArrayUsingSelector:@selector(compare:)];
    MPGOAcquisitionRun *chosenRun = nil;
    NSString *chosenName = nil;
    for (NSString *n in runNames) {
        MPGOAcquisitionRun *r = dataset.msRuns[n];
        if ([r.spectrumClassName isEqualToString:@"MPGOMassSpectrum"]) {
            chosenRun = r;
            chosenName = n;
            break;
        }
    }
    if (!chosenRun) {
        if (error) *error = [NSError errorWithDomain:@"MPGOMzMLWriter"
                                                  code:2
                                              userInfo:@{NSLocalizedDescriptionKey:
                                                          @"no MPGOMassSpectrum run to export"}];
        return nil;
    }

    NSUInteger nSpectra = chosenRun.spectrumIndex.count;

    // ------------------------------------------------------------------
    // Header / prelude — everything before <spectrumList>.
    // ------------------------------------------------------------------
    NSMutableData *body = [NSMutableData data];
    NSString *runId = chosenName ?: @"run";

    appendUTF8(body, @"<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n");
    appendUTF8(body, @"<indexedmzML xmlns=\"http://psi.hupo.org/ms/mzml\""
                     @" xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\""
                     @" xsi:schemaLocation=\"http://psi.hupo.org/ms/mzml http://psidev.info/files/ms/mzML/xsd/mzML1.1.0_idx.xsd\">\n");
    appendUTF8(body, @"  <mzML xmlns=\"http://psi.hupo.org/ms/mzml\""
                     @" xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\""
                     @" xsi:schemaLocation=\"http://psi.hupo.org/ms/mzml http://psidev.info/files/ms/mzML/xsd/mzML1.1.0.xsd\""
                     @" id=\"mpgo_export\" version=\"1.1.0\">\n");

    appendUTF8(body,
        @"    <cvList count=\"2\">\n"
        @"      <cv id=\"MS\" fullName=\"Proteomics Standards Initiative Mass Spectrometry Ontology\" version=\"4.1.0\" URI=\"https://raw.githubusercontent.com/HUPO-PSI/psi-ms-CV/master/psi-ms.obo\"/>\n"
        @"      <cv id=\"UO\" fullName=\"Unit Ontology\" version=\"releases/2020-03-10\" URI=\"http://ontologies.berkeleybop.org/uo.obo\"/>\n"
        @"    </cvList>\n");

    appendUTF8(body,
        @"    <fileDescription>\n"
        @"      <fileContent>\n"
        @"        <cvParam cvRef=\"MS\" accession=\"MS:1000580\" name=\"MSn spectrum\" value=\"\"/>\n"
        @"      </fileContent>\n"
        @"    </fileDescription>\n");

    appendUTF8(body,
        @"    <softwareList count=\"1\">\n"
        @"      <software id=\"mpeg_o\" version=\"0.3.0\">\n"
        @"        <cvParam cvRef=\"MS\" accession=\"MS:1000799\" name=\"custom unreleased software tool\" value=\"mpeg-o\"/>\n"
        @"      </software>\n"
        @"    </softwareList>\n");

    appendUTF8(body,
        @"    <instrumentConfigurationList count=\"1\">\n"
        @"      <instrumentConfiguration id=\"IC1\">\n"
        @"        <cvParam cvRef=\"MS\" accession=\"MS:1000031\" name=\"instrument model\" value=\"\"/>\n"
        @"      </instrumentConfiguration>\n"
        @"    </instrumentConfigurationList>\n");

    appendUTF8(body,
        @"    <dataProcessingList count=\"1\">\n"
        @"      <dataProcessing id=\"dp_export\">\n"
        @"        <processingMethod order=\"0\" softwareRef=\"mpeg_o\">\n"
        @"          <cvParam cvRef=\"MS\" accession=\"MS:1000544\" name=\"Conversion to mzML\"/>\n"
        @"        </processingMethod>\n"
        @"      </dataProcessing>\n"
        @"    </dataProcessingList>\n");

    NSString *runOpen = [NSString stringWithFormat:
        @"    <run id=\"%@\" defaultInstrumentConfigurationRef=\"IC1\">\n",
        xmlEscape(runId)];
    appendUTF8(body, runOpen);

    NSString *specListOpen = [NSString stringWithFormat:
        @"      <spectrumList count=\"%lu\" defaultDataProcessingRef=\"dp_export\">\n",
        (unsigned long)nSpectra];
    appendUTF8(body, specListOpen);

    // ------------------------------------------------------------------
    // Spectrum loop — record byte offsets for the indexList.
    // ------------------------------------------------------------------
    NSMutableArray<NSNumber *> *spectrumOffsets = [NSMutableArray arrayWithCapacity:nSpectra];
    NSMutableArray<NSString *> *spectrumIds = [NSMutableArray arrayWithCapacity:nSpectra];

    for (NSUInteger i = 0; i < nSpectra; i++) {
        NSError *sErr = nil;
        id spec = [chosenRun spectrumAtIndex:i error:&sErr];
        if (![spec isKindOfClass:[MPGOMassSpectrum class]]) continue;
        MPGOMassSpectrum *ms = (MPGOMassSpectrum *)spec;

        NSUInteger offset = body.length;
        // indexedmzML offsets point to the byte after the preceding
        // newline (i.e. the first byte of the `<spectrum` tag itself).
        [spectrumOffsets addObject:@(offset + strlen("        "))];

        NSString *scanId = [NSString stringWithFormat:@"scan=%lu", (unsigned long)(i + 1)];
        [spectrumIds addObject:scanId];

        NSUInteger arrayLen = ms.mzArray.length;
        NSString *specOpen = [NSString stringWithFormat:
            @"        <spectrum index=\"%lu\" id=\"%@\" defaultArrayLength=\"%lu\">\n",
            (unsigned long)i, xmlEscape(scanId), (unsigned long)arrayLen];
        appendUTF8(body, specOpen);

        appendUTF8(body, @"          <cvParam cvRef=\"MS\" accession=\"MS:1000580\" name=\"MSn spectrum\" value=\"\"/>\n");

        NSString *lvl = [NSString stringWithFormat:
            @"          <cvParam cvRef=\"MS\" accession=\"MS:1000511\" name=\"ms level\" value=\"%lu\"/>\n",
            (unsigned long)ms.msLevel];
        appendUTF8(body, lvl);

        if (ms.polarity == MPGOPolarityPositive) {
            appendUTF8(body, @"          <cvParam cvRef=\"MS\" accession=\"MS:1000130\" name=\"positive scan\" value=\"\"/>\n");
        } else if (ms.polarity == MPGOPolarityNegative) {
            appendUTF8(body, @"          <cvParam cvRef=\"MS\" accession=\"MS:1000129\" name=\"negative scan\" value=\"\"/>\n");
        }

        appendUTF8(body, @"          <scanList count=\"1\">\n");
        appendUTF8(body, @"            <cvParam cvRef=\"MS\" accession=\"MS:1000795\" name=\"no combination\" value=\"\"/>\n");
        appendUTF8(body, @"            <scan>\n");
        NSString *rt = [NSString stringWithFormat:
            @"              <cvParam cvRef=\"MS\" accession=\"MS:1000016\" name=\"scan start time\" value=\"%@\" unitCvRef=\"UO\" unitAccession=\"UO:0000010\" unitName=\"second\"/>\n",
            fmtDouble(ms.scanTimeSeconds)];
        appendUTF8(body, rt);
        appendUTF8(body, @"            </scan>\n");
        appendUTF8(body, @"          </scanList>\n");

        if (ms.precursorMz > 0.0 || ms.msLevel > 1) {
            appendUTF8(body, @"          <precursorList count=\"1\">\n");
            appendUTF8(body, @"            <precursor>\n");
            appendUTF8(body, @"              <selectedIonList count=\"1\">\n");
            appendUTF8(body, @"                <selectedIon>\n");
            NSString *pmz = [NSString stringWithFormat:
                @"                  <cvParam cvRef=\"MS\" accession=\"MS:1000744\" name=\"selected ion m/z\" value=\"%@\" unitCvRef=\"MS\" unitAccession=\"MS:1000040\" unitName=\"m/z\"/>\n",
                fmtDouble(ms.precursorMz)];
            appendUTF8(body, pmz);
            if (ms.precursorCharge > 0) {
                NSString *pz = [NSString stringWithFormat:
                    @"                  <cvParam cvRef=\"MS\" accession=\"MS:1000041\" name=\"charge state\" value=\"%lu\"/>\n",
                    (unsigned long)ms.precursorCharge];
                appendUTF8(body, pz);
            }
            appendUTF8(body, @"                </selectedIon>\n");
            appendUTF8(body, @"              </selectedIonList>\n");
            appendUTF8(body, @"            </precursor>\n");
            appendUTF8(body, @"          </precursorList>\n");
        }

        // Binary data arrays: m/z and intensity, both float64 (MPGO's
        // canonical precision). Optional zlib compression.
        appendUTF8(body, @"          <binaryDataArrayList count=\"2\">\n");

        NSData *mzBuf = ms.mzArray.buffer;
        NSData *inBuf = ms.intensityArray.buffer;
        NSString *mzB64 = [MPGOBase64 encodeData:mzBuf zlibDeflate:zlibCompression];
        NSString *inB64 = [MPGOBase64 encodeData:inBuf zlibDeflate:zlibCompression];

        NSString *mzArr = [NSString stringWithFormat:
            @"            <binaryDataArray encodedLength=\"%lu\">\n"
            @"              <cvParam cvRef=\"MS\" accession=\"%@\" name=\"%@\" value=\"\"/>\n"
            @"              <cvParam cvRef=\"MS\" accession=\"%@\" name=\"%@\" value=\"\"/>\n"
            @"              <cvParam cvRef=\"MS\" accession=\"MS:1000514\" name=\"m/z array\" value=\"\" unitCvRef=\"MS\" unitAccession=\"MS:1000040\" unitName=\"m/z\"/>\n"
            @"              <binary>%@</binary>\n"
            @"            </binaryDataArray>\n",
            (unsigned long)mzB64.length,
            precisionAccession(NO), precisionName(NO),
            (zlibCompression ? @"MS:1000574" : @"MS:1000576"),
            (zlibCompression ? @"zlib compression" : @"no compression"),
            mzB64];
        appendUTF8(body, mzArr);

        NSString *inArr = [NSString stringWithFormat:
            @"            <binaryDataArray encodedLength=\"%lu\">\n"
            @"              <cvParam cvRef=\"MS\" accession=\"%@\" name=\"%@\" value=\"\"/>\n"
            @"              <cvParam cvRef=\"MS\" accession=\"%@\" name=\"%@\" value=\"\"/>\n"
            @"              <cvParam cvRef=\"MS\" accession=\"MS:1000515\" name=\"intensity array\" value=\"\" unitCvRef=\"MS\" unitAccession=\"MS:1000131\" unitName=\"number of counts\"/>\n"
            @"              <binary>%@</binary>\n"
            @"            </binaryDataArray>\n",
            (unsigned long)inB64.length,
            precisionAccession(NO), precisionName(NO),
            (zlibCompression ? @"MS:1000574" : @"MS:1000576"),
            (zlibCompression ? @"zlib compression" : @"no compression"),
            inB64];
        appendUTF8(body, inArr);

        appendUTF8(body, @"          </binaryDataArrayList>\n");
        appendUTF8(body, @"        </spectrum>\n");
    }

    appendUTF8(body, @"      </spectrumList>\n");

    // ------------------------------------------------------------------
    // M24: chromatogramList
    // ------------------------------------------------------------------
    NSArray<MPGOChromatogram *> *chroms = chosenRun.chromatograms;
    NSMutableArray<NSNumber *> *chromOffsets = [NSMutableArray arrayWithCapacity:chroms.count];
    NSMutableArray<NSString *> *chromIds = [NSMutableArray arrayWithCapacity:chroms.count];
    if (chroms.count > 0) {
        NSString *chromListOpen = [NSString stringWithFormat:
            @"      <chromatogramList count=\"%lu\" defaultDataProcessingRef=\"dp_export\">\n",
            (unsigned long)chroms.count];
        appendUTF8(body, chromListOpen);

        for (NSUInteger i = 0; i < chroms.count; i++) {
            MPGOChromatogram *c = chroms[i];
            NSUInteger arrayLen = c.timeArray.length;
            NSString *cid = [NSString stringWithFormat:@"chrom=%lu", (unsigned long)(i + 1)];
            [chromIds addObject:cid];

            NSUInteger offset = body.length;
            [chromOffsets addObject:@(offset + strlen("        "))];

            NSString *open = [NSString stringWithFormat:
                @"        <chromatogram index=\"%lu\" id=\"%@\" defaultArrayLength=\"%lu\">\n",
                (unsigned long)i, xmlEscape(cid), (unsigned long)arrayLen];
            appendUTF8(body, open);

            // Type cvParam. MS:1000235 = TIC, MS:1000627 = XIC (also
            // called "selected ion chromatogram"), MS:1000789 = SRM.
            if (c.type == MPGOChromatogramTypeTIC) {
                appendUTF8(body, @"          <cvParam cvRef=\"MS\" accession=\"MS:1000235\" name=\"total ion current chromatogram\" value=\"\"/>\n");
            } else if (c.type == MPGOChromatogramTypeXIC) {
                appendUTF8(body, @"          <cvParam cvRef=\"MS\" accession=\"MS:1000627\" name=\"selected ion current chromatogram\" value=\"\"/>\n");
                NSString *tm = [NSString stringWithFormat:
                    @"          <userParam name=\"target m/z\" value=\"%@\" type=\"xsd:double\"/>\n",
                    fmtDouble(c.targetMz)];
                appendUTF8(body, tm);
            } else if (c.type == MPGOChromatogramTypeSRM) {
                appendUTF8(body, @"          <cvParam cvRef=\"MS\" accession=\"MS:1001473\" name=\"selected reaction monitoring chromatogram\" value=\"\"/>\n");
                NSString *pm = [NSString stringWithFormat:
                    @"          <userParam name=\"precursor m/z\" value=\"%@\" type=\"xsd:double\"/>\n"
                    @"          <userParam name=\"product m/z\" value=\"%@\" type=\"xsd:double\"/>\n",
                    fmtDouble(c.precursorProductMz), fmtDouble(c.productMz)];
                appendUTF8(body, pm);
            }

            NSData *tBuf = c.timeArray.buffer;
            NSData *iBuf = c.intensityArray.buffer;
            NSString *tB64 = [MPGOBase64 encodeData:tBuf zlibDeflate:zlibCompression];
            NSString *iB64 = [MPGOBase64 encodeData:iBuf zlibDeflate:zlibCompression];

            appendUTF8(body, @"          <binaryDataArrayList count=\"2\">\n");
            NSString *tArr = [NSString stringWithFormat:
                @"            <binaryDataArray encodedLength=\"%lu\">\n"
                @"              <cvParam cvRef=\"MS\" accession=\"%@\" name=\"%@\" value=\"\"/>\n"
                @"              <cvParam cvRef=\"MS\" accession=\"%@\" name=\"%@\" value=\"\"/>\n"
                @"              <cvParam cvRef=\"MS\" accession=\"MS:1000595\" name=\"time array\" value=\"\" unitCvRef=\"UO\" unitAccession=\"UO:0000010\" unitName=\"second\"/>\n"
                @"              <binary>%@</binary>\n"
                @"            </binaryDataArray>\n",
                (unsigned long)tB64.length,
                precisionAccession(NO), precisionName(NO),
                (zlibCompression ? @"MS:1000574" : @"MS:1000576"),
                (zlibCompression ? @"zlib compression" : @"no compression"),
                tB64];
            appendUTF8(body, tArr);

            NSString *iArr = [NSString stringWithFormat:
                @"            <binaryDataArray encodedLength=\"%lu\">\n"
                @"              <cvParam cvRef=\"MS\" accession=\"%@\" name=\"%@\" value=\"\"/>\n"
                @"              <cvParam cvRef=\"MS\" accession=\"%@\" name=\"%@\" value=\"\"/>\n"
                @"              <cvParam cvRef=\"MS\" accession=\"MS:1000515\" name=\"intensity array\" value=\"\" unitCvRef=\"MS\" unitAccession=\"MS:1000131\" unitName=\"number of counts\"/>\n"
                @"              <binary>%@</binary>\n"
                @"            </binaryDataArray>\n",
                (unsigned long)iB64.length,
                precisionAccession(NO), precisionName(NO),
                (zlibCompression ? @"MS:1000574" : @"MS:1000576"),
                (zlibCompression ? @"zlib compression" : @"no compression"),
                iB64];
            appendUTF8(body, iArr);
            appendUTF8(body, @"          </binaryDataArrayList>\n");
            appendUTF8(body, @"        </chromatogram>\n");
        }
        appendUTF8(body, @"      </chromatogramList>\n");
    }

    appendUTF8(body, @"    </run>\n");
    appendUTF8(body, @"  </mzML>\n");

    // ------------------------------------------------------------------
    // indexList + indexListOffset + fileChecksum
    // ------------------------------------------------------------------
    NSUInteger indexListOffset = body.length;

    NSUInteger indexCount = 1 + (chroms.count > 0 ? 1 : 0);
    NSString *indexListOpen = [NSString stringWithFormat:
        @"  <indexList count=\"%lu\">\n", (unsigned long)indexCount];
    appendUTF8(body, indexListOpen);

    appendUTF8(body, @"    <index name=\"spectrum\">\n");
    for (NSUInteger i = 0; i < spectrumOffsets.count; i++) {
        NSString *entry = [NSString stringWithFormat:
            @"      <offset idRef=\"%@\">%llu</offset>\n",
            xmlEscape(spectrumIds[i]),
            (unsigned long long)spectrumOffsets[i].unsignedLongLongValue];
        appendUTF8(body, entry);
    }
    appendUTF8(body, @"    </index>\n");

    if (chroms.count > 0) {
        appendUTF8(body, @"    <index name=\"chromatogram\">\n");
        for (NSUInteger i = 0; i < chromOffsets.count; i++) {
            NSString *entry = [NSString stringWithFormat:
                @"      <offset idRef=\"%@\">%llu</offset>\n",
                xmlEscape(chromIds[i]),
                (unsigned long long)chromOffsets[i].unsignedLongLongValue];
            appendUTF8(body, entry);
        }
        appendUTF8(body, @"    </index>\n");
    }
    appendUTF8(body, @"  </indexList>\n");

    NSString *ilo = [NSString stringWithFormat:
        @"  <indexListOffset>%llu</indexListOffset>\n",
        (unsigned long long)indexListOffset];
    appendUTF8(body, ilo);

    appendUTF8(body, @"  <fileChecksum>0</fileChecksum>\n");
    appendUTF8(body, @"</indexedmzML>\n");

    return body;
}

+ (BOOL)writeDataset:(MPGOSpectralDataset *)dataset
              toPath:(NSString *)path
     zlibCompression:(BOOL)zlibCompression
                error:(NSError **)error
{
    NSData *data = [self dataForDataset:dataset
                         zlibCompression:zlibCompression
                                   error:error];
    if (!data) return NO;
    return [data writeToFile:path options:NSDataWritingAtomic error:error];
}

@end
