/*
 * Licensed under the Apache License, Version 2.0.
 * See LICENSE-IMPORT-EXPORT in the repository root.
 *
 * SPDX-License-Identifier: Apache-2.0
 */

#import "MPGONmrMLWriter.h"
#import "Spectra/MPGONMRSpectrum.h"
#import "Spectra/MPGOFreeInductionDecay.h"
#import "Core/MPGOSignalArray.h"
#import "Import/MPGOBase64.h"

static void emit(NSMutableData *buf, NSString *s)
{
    const char *c = [s UTF8String];
    if (c) [buf appendBytes:c length:strlen(c)];
}

static NSString *fmtD(double v) { return [NSString stringWithFormat:@"%.15g", v]; }

@implementation MPGONmrMLWriter

+ (NSData *)dataForSpectrum:(MPGONMRSpectrum *)spectrum
                        fid:(MPGOFreeInductionDecay *)fid
              sweepWidthPPM:(double)sweepWidthPPM
                      error:(NSError **)error
{
    if (!spectrum) {
        if (error) *error = [NSError errorWithDomain:@"MPGONmrMLWriter"
                                                  code:1
                                              userInfo:@{NSLocalizedDescriptionKey:
                                                          @"nil spectrum"}];
        return nil;
    }

    NSMutableData *out = [NSMutableData data];

    emit(out, @"<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n");
    // nmrML XSD requires a version attribute on the root element.
    emit(out, @"<nmrML xmlns=\"http://nmrml.org/schema\""
              @" xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\""
              @" xsi:schemaLocation=\"http://nmrml.org/schema http://nmrml.org/schema/v1.0/nmrML.xsd\""
              @" version=\"1.1.0\">\n");

    // cvList
    emit(out, @"  <cvList>\n");
    emit(out, @"    <cv id=\"nmrCV\" fullName=\"nmrML Controlled Vocabulary\""
              @" version=\"1.1.0\" URI=\"http://nmrml.org/cv/v1.1.0/nmrCV.owl\"/>\n");
    emit(out, @"  </cvList>\n");

    // nmrML XSD requires <fileDescription> between <cvList> and <acquisition>.
    emit(out, @"  <fileDescription>\n");
    emit(out, @"    <fileContent>\n");
    emit(out, @"      <cvParam cvRef=\"nmrCV\" accession=\"NMR:1000002\""
              @" name=\"acquisition nucleus\" value=\"\"/>\n");
    emit(out, @"    </fileContent>\n");
    emit(out, @"  </fileDescription>\n");

    // softwareList + instrumentConfigurationList before <acquisition>.
    emit(out, @"  <softwareList>\n");
    emit(out, @"    <software id=\"mpeg_o\" version=\"0.9.0\""
              @" cvRef=\"nmrCV\" accession=\"NMR:1400217\" name=\"custom software\"/>\n");
    emit(out, @"  </softwareList>\n");
    emit(out, @"  <instrumentConfigurationList>\n");
    emit(out, @"    <instrumentConfiguration id=\"IC1\">\n");
    emit(out, @"      <cvParam cvRef=\"nmrCV\" accession=\"NMR:1400255\""
              @" name=\"nmr instrument\" value=\"\"/>\n");
    emit(out, @"    </instrumentConfiguration>\n");
    emit(out, @"  </instrumentConfigurationList>\n");

    // Strict XSD element order per AcquisitionParameterSet[1D]Type:
    //   softwareRef, sampleContainer, sampleAcquisitionTemperature,
    //   spinningRate, relaxationDelay, pulseSequence,
    //   DirectDimensionParameterSet
    emit(out, @"  <acquisition>\n");
    emit(out, @"    <acquisition1D>\n");
    emit(out, @"      <acquisitionParameterSet numberOfScans=\"1\""
              @" numberOfSteadyStateScans=\"0\">\n");
    emit(out, @"        <softwareRef ref=\"mpeg_o\"/>\n");
    emit(out, @"        <sampleContainer cvRef=\"nmrCV\""
              @" accession=\"NMR:1400128\" name=\"tube\"/>\n");
    emit(out, @"        <sampleAcquisitionTemperature value=\"298.0\""
              @" unitAccession=\"UO:0000012\" unitName=\"kelvin\" unitCvRef=\"UO\"/>\n");
    emit(out, @"        <spinningRate value=\"0.0\""
              @" unitAccession=\"UO:0000106\" unitName=\"hertz\" unitCvRef=\"UO\"/>\n");
    emit(out, @"        <relaxationDelay value=\"1.0\""
              @" unitAccession=\"UO:0000010\" unitName=\"second\" unitCvRef=\"UO\"/>\n");
    emit(out, @"        <pulseSequence/>\n");

    double freqHz = spectrum.spectrometerFrequencyMHz * 1.0e6;
    double sweepValue = (sweepWidthPPM > 0.0) ? sweepWidthPPM : 10.0;
    NSUInteger nPointsHint = spectrum.intensityArray.length;
    NSString *nucleus = spectrum.nucleusType ?: @"1H";
    if (nucleus.length == 0) nucleus = @"1H";

    emit(out, [NSString stringWithFormat:
        @"        <DirectDimensionParameterSet decoupled=\"false\""
        @" numberOfDataPoints=\"%lu\">\n",
        (unsigned long)nPointsHint]);
    emit(out, [NSString stringWithFormat:
        @"          <acquisitionNucleus cvRef=\"nmrCV\""
        @" accession=\"NMR:1000002\" name=\"%@\"/>\n",
        nucleus]);
    emit(out, @"          <effectiveExcitationField value=\"0.0\""
              @" unitAccession=\"UO:0000228\" unitName=\"tesla\" unitCvRef=\"UO\"/>\n");
    emit(out, [NSString stringWithFormat:
        @"          <sweepWidth value=\"%@\""
        @" unitAccession=\"UO:0000169\" unitName=\"parts per million\" unitCvRef=\"UO\"/>\n",
        fmtD(sweepValue)]);
    emit(out, @"          <pulseWidth value=\"10.0\""
              @" unitAccession=\"UO:0000029\" unitName=\"microsecond\" unitCvRef=\"UO\"/>\n");
    emit(out, [NSString stringWithFormat:
        @"          <irradiationFrequency value=\"%@\""
        @" unitAccession=\"UO:0000106\" unitName=\"hertz\" unitCvRef=\"UO\"/>\n",
        fmtD(freqHz)]);
    emit(out, @"          <irradiationFrequencyOffset value=\"0.0\""
              @" unitAccession=\"UO:0000106\" unitName=\"hertz\" unitCvRef=\"UO\"/>\n");
    emit(out, @"          <samplingStrategy cvRef=\"nmrCV\""
              @" accession=\"NMR:1400285\" name=\"uniform sampling\"/>\n");
    emit(out, @"        </DirectDimensionParameterSet>\n");

    emit(out, @"      </acquisitionParameterSet>\n");

    // fidData — required by XSD; emit empty placeholder when no FID supplied.
    if (fid) {
        NSString *fidB64 = [MPGOBase64 encodeData:fid.buffer zlibDeflate:NO];
        emit(out, [NSString stringWithFormat:
            @"      <fidData compressed=\"false\" byteFormat=\"Complex128\""
            @" encodedLength=\"%lu\">%@</fidData>\n",
            (unsigned long)fidB64.length, fidB64]);
    } else {
        emit(out, @"      <fidData compressed=\"false\" byteFormat=\"Complex128\""
                  @" encodedLength=\"0\"></fidData>\n");
    }

    emit(out, @"    </acquisition1D>\n");
    emit(out, @"  </acquisition>\n");

    // Canonical spectrum1D: single <spectrumDataArray> with interleaved
    // (x,y) doubles + attribute-only <xAxis>. Reader detects the
    // interleaved form by encodedLength == 2*numberOfDataPoints*8.
    NSData *xBuf = spectrum.chemicalShiftArray.buffer;
    NSData *yBuf = spectrum.intensityArray.buffer;
    NSUInteger nPoints = spectrum.intensityArray.length;
    NSMutableData *xy = [NSMutableData dataWithLength:nPoints * 2 * sizeof(double)];
    const double *xp = xBuf.bytes;
    const double *yp = yBuf.bytes;
    double *xyp = xy.mutableBytes;
    for (NSUInteger i = 0; i < nPoints; i++) {
        xyp[2*i    ] = xp[i];
        xyp[2*i + 1] = yp[i];
    }
    NSString *xyB64 = [MPGOBase64 encodeData:xy zlibDeflate:NO];

    emit(out, @"  <spectrumList>\n");
    emit(out, [NSString stringWithFormat:
        @"    <spectrum1D id=\"s1\" numberOfDataPoints=\"%lu\">\n",
        (unsigned long)nPoints]);
    emit(out, [NSString stringWithFormat:
        @"      <spectrumDataArray compressed=\"false\" byteFormat=\"Complex128\""
        @" encodedLength=\"%lu\">%@</spectrumDataArray>\n",
        (unsigned long)xyB64.length, xyB64]);
    emit(out, @"      <xAxis unitAccession=\"UO:0000169\""
              @" unitName=\"parts per million\" unitCvRef=\"UO\"/>\n");
    emit(out, @"    </spectrum1D>\n");
    emit(out, @"  </spectrumList>\n");
    emit(out, @"</nmrML>\n");

    return out;
}

+ (BOOL)writeSpectrum:(MPGONMRSpectrum *)spectrum
                  fid:(MPGOFreeInductionDecay *)fid
        sweepWidthPPM:(double)sweepWidthPPM
               toPath:(NSString *)path
                error:(NSError **)error
{
    NSData *data = [self dataForSpectrum:spectrum fid:fid
                           sweepWidthPPM:sweepWidthPPM error:error];
    if (!data) return NO;
    return [data writeToFile:path options:NSDataWritingAtomic error:error];
}

@end
