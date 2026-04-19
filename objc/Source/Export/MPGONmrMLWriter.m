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

    // acquisitionParameterSet — numberOfSteadyStateScans required.
    emit(out, @"  <acquisition>\n");
    emit(out, @"    <acquisition1D>\n");
    emit(out, @"      <acquisitionParameterSet numberOfScans=\"1\""
              @" numberOfSteadyStateScans=\"0\">\n");
    emit(out, @"        <softwareRef ref=\"mpeg_o\"/>\n");

    // nucleus
    emit(out, [NSString stringWithFormat:
        @"        <acquisitionNucleus name=\"%@\"/>\n",
        spectrum.nucleusType ?: @""]);

    // spectrometer frequency in Hz → we store in MHz, nmrML expects Hz
    double freqHz = spectrum.spectrometerFrequencyMHz * 1.0e6;
    emit(out, [NSString stringWithFormat:
        @"        <cvParam cvRef=\"nmrCV\" accession=\"NMR:1000001\""
        @" name=\"spectrometer frequency\" value=\"%@\"/>\n",
        fmtD(freqHz)]);

    // nucleus as cvParam too
    emit(out, [NSString stringWithFormat:
        @"        <cvParam cvRef=\"nmrCV\" accession=\"NMR:1000002\""
        @" name=\"acquisition nucleus\" value=\"%@\"/>\n",
        spectrum.nucleusType ?: @""]);

    if (sweepWidthPPM > 0.0) {
        emit(out, [NSString stringWithFormat:
            @"        <cvParam cvRef=\"nmrCV\" accession=\"NMR:1400014\""
            @" name=\"sweep width\" value=\"%@\"/>\n",
            fmtD(sweepWidthPPM)]);
    }

    if (fid) {
        emit(out, [NSString stringWithFormat:
            @"        <cvParam cvRef=\"nmrCV\" accession=\"NMR:1000004\""
            @" name=\"dwell time\" value=\"%@\"/>\n",
            fmtD(fid.dwellTimeSeconds)]);
    }

    emit(out, @"      </acquisitionParameterSet>\n");

    // fidData
    if (fid) {
        NSString *fidB64 = [MPGOBase64 encodeData:fid.buffer zlibDeflate:NO];
        emit(out, [NSString stringWithFormat:
            @"      <fidData compressed=\"false\" byteFormat=\"float64\""
            @" encodedLength=\"%lu\">\n",
            (unsigned long)fidB64.length]);
        emit(out, [NSString stringWithFormat:@"        %@\n", fidB64]);
        emit(out, @"      </fidData>\n");
    }

    emit(out, @"    </acquisition1D>\n");
    emit(out, @"  </acquisition>\n");

    // spectrum1D
    emit(out, @"  <spectrumList>\n");
    emit(out, @"    <spectrum1D>\n");

    // xAxis = chemical shift
    NSData *xBuf = spectrum.chemicalShiftArray.buffer;
    NSString *xB64 = [MPGOBase64 encodeData:xBuf zlibDeflate:NO];
    emit(out, @"      <xAxis>\n");
    emit(out, [NSString stringWithFormat:
        @"        <spectrumDataArray compressed=\"false\""
        @" encodedLength=\"%lu\">\n",
        (unsigned long)xB64.length]);
    emit(out, [NSString stringWithFormat:@"          %@\n", xB64]);
    emit(out, @"        </spectrumDataArray>\n");
    emit(out, @"      </xAxis>\n");

    // yAxis = intensity
    NSData *yBuf = spectrum.intensityArray.buffer;
    NSString *yB64 = [MPGOBase64 encodeData:yBuf zlibDeflate:NO];
    emit(out, @"      <yAxis>\n");
    emit(out, [NSString stringWithFormat:
        @"        <spectrumDataArray compressed=\"false\""
        @" encodedLength=\"%lu\">\n",
        (unsigned long)yB64.length]);
    emit(out, [NSString stringWithFormat:@"          %@\n", yB64]);
    emit(out, @"        </spectrumDataArray>\n");
    emit(out, @"      </yAxis>\n");

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
