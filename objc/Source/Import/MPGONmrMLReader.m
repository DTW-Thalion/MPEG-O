/*
 * Licensed under the Apache License, Version 2.0.
 * See LICENSE-IMPORT-EXPORT in the repository root.
 *
 * SPDX-License-Identifier: Apache-2.0
 */

#import "MPGONmrMLReader.h"
#import "MPGOBase64.h"
#import "MPGOCVTermMapper.h"

#import "Core/MPGOSignalArray.h"
#import "ValueClasses/MPGOEncodingSpec.h"
#import "ValueClasses/MPGOAxisDescriptor.h"
#import "ValueClasses/MPGOValueRange.h"
#import "ValueClasses/MPGOEnums.h"
#import "Spectra/MPGONMRSpectrum.h"
#import "Spectra/MPGOFreeInductionDecay.h"
#import "Run/MPGOAcquisitionRun.h"
#import "Run/MPGOInstrumentConfig.h"
#import "Dataset/MPGOSpectralDataset.h"

NSString *const MPGONmrMLReaderErrorDomain = @"MPGONmrMLReaderErrorDomain";

@interface MPGONmrMLReader () <NSXMLParserDelegate>
@end

@implementation MPGONmrMLReader
{
    MPGOSpectralDataset *_dataset;
    NSMutableArray<MPGOFreeInductionDecay *> *_fids;
    NSMutableArray<MPGONMRSpectrum *> *_spectra;

    NSError *_internalError;

    // Acquisition parameters (file-wide)
    double     _spectrometerFrequencyMHz;
    NSString  *_nucleusType;
    NSUInteger _numberOfScans;
    double     _dwellTimeSeconds;
    double     _sweepWidthPpm;

    // Parse state
    BOOL _inAcquisitionParameterSet;
    BOOL _inFidData;
    BOOL _fidCompressed;
    NSString *_fidByteFormat;  // copy of byteFormat attribute (nmrML varies)
    BOOL _inSpectrum1D;
    BOOL _inXAxis;
    BOOL _inYAxis;
    BOOL _inSpectrumDataArray;
    BOOL _currentDataArrayCompressed;

    // Text accumulator (used for binary content)
    BOOL              _capturingText;
    NSMutableString  *_textBuf;

    // Current spectrum1D state
    NSData *_currentXAxisData;
    NSData *_currentYAxisData;
    NSData *_currentInterleavedXY;  // v0.9 canonical single-array form
    NSUInteger _current1DNumberOfDataPoints;
    NSUInteger _currentSpecIndex;
}

@synthesize dataset                  = _dataset;
@synthesize fids                     = _fids;
@synthesize spectrometerFrequencyMHz = _spectrometerFrequencyMHz;
@synthesize nucleusType              = _nucleusType;
@synthesize numberOfScans            = _numberOfScans;
@synthesize dwellTimeSeconds         = _dwellTimeSeconds;
@synthesize sweepWidthPpm            = _sweepWidthPpm;

#pragma mark - Class entry points

+ (MPGOSpectralDataset *)readFromFilePath:(NSString *)path error:(NSError **)error
{
    MPGONmrMLReader *r = [self parseFilePath:path error:error];
    return r.dataset;
}

+ (MPGOSpectralDataset *)readFromURL:(NSURL *)url error:(NSError **)error
{
    if (!url.isFileURL) {
        if (error) *error = [NSError errorWithDomain:MPGONmrMLReaderErrorDomain
                                                 code:MPGONmrMLReaderErrorParseFailed
                                             userInfo:@{NSLocalizedDescriptionKey:
                            @"Only file URLs are supported"}];
        return nil;
    }
    return [self readFromFilePath:url.path error:error];
}

+ (MPGOSpectralDataset *)readFromData:(NSData *)data error:(NSError **)error
{
    MPGONmrMLReader *r = [self parseData:data error:error];
    return r.dataset;
}

+ (instancetype)parseFilePath:(NSString *)path error:(NSError **)error
{
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data) {
        if (error) *error = [NSError errorWithDomain:MPGONmrMLReaderErrorDomain
                                                 code:MPGONmrMLReaderErrorParseFailed
                                             userInfo:@{NSLocalizedDescriptionKey:
                            [NSString stringWithFormat:@"Cannot read %@", path]}];
        return nil;
    }
    return [self parseData:data error:error];
}

+ (instancetype)parseData:(NSData *)data error:(NSError **)error
{
    if (!data) {
        if (error) *error = [NSError errorWithDomain:MPGONmrMLReaderErrorDomain
                                                 code:MPGONmrMLReaderErrorParseFailed
                                             userInfo:@{NSLocalizedDescriptionKey:
                            @"nil input data"}];
        return nil;
    }
    MPGONmrMLReader *r = [[self alloc] init];
    if (![r parseData:data error:error]) return nil;
    return r;
}

#pragma mark - Init

- (instancetype)init
{
    self = [super init];
    if (self) {
        _fids     = [NSMutableArray array];
        _spectra  = [NSMutableArray array];
        _textBuf  = [NSMutableString string];
        _spectrometerFrequencyMHz = 0.0;
        _nucleusType              = @"";
        _numberOfScans            = 0;
        _dwellTimeSeconds         = 0.0;
        _sweepWidthPpm            = 0.0;
        _currentSpecIndex         = 0;
    }
    return self;
}

- (BOOL)parseData:(NSData *)data error:(NSError **)error
{
    NSXMLParser *parser = [[NSXMLParser alloc] initWithData:data];
    parser.delegate = self;
    parser.shouldProcessNamespaces = NO;
    parser.shouldResolveExternalEntities = NO;

    BOOL ok = [parser parse];
    if (!ok || _internalError) {
        NSError *e = _internalError ?: [parser parserError];
        if (!e) {
            e = [NSError errorWithDomain:MPGONmrMLReaderErrorDomain
                                    code:MPGONmrMLReaderErrorParseFailed
                                userInfo:@{NSLocalizedDescriptionKey: @"unknown parse failure"}];
        }
        if (error) *error = e;
        return NO;
    }

    // Build the dataset after parse completes. Wrap parsed spectrum1D
    // entries in a single NMR acquisition run.
    MPGOAcquisitionRun *run = nil;
    if (_spectra.count > 0) {
        MPGOInstrumentConfig *cfg =
            [[MPGOInstrumentConfig alloc] initWithManufacturer:@""
                                                         model:@""
                                                  serialNumber:@""
                                                    sourceType:@""
                                                  analyzerType:@""
                                                  detectorType:@""];
        run = [[MPGOAcquisitionRun alloc] initWithSpectra:[_spectra copy]
                                          acquisitionMode:MPGOAcquisitionMode1DNMR
                                         instrumentConfig:cfg];
    }

    NSDictionary *msRuns = run ? @{@"nmr_run": run} : @{};
    _dataset = [[MPGOSpectralDataset alloc] initWithTitle:@"nmrml_import"
                                       isaInvestigationId:@""
                                                   msRuns:msRuns
                                                  nmrRuns:@{}
                                          identifications:@[]
                                          quantifications:@[]
                                        provenanceRecords:@[]
                                              transitions:nil];
    return YES;
}

#pragma mark - Helpers

- (void)failWithCode:(MPGONmrMLReaderErrorCode)code message:(NSString *)msg
{
    _internalError = [NSError errorWithDomain:MPGONmrMLReaderErrorDomain
                                         code:code
                                     userInfo:@{NSLocalizedDescriptionKey: msg ?: @""}];
}

static MPGOSignalArray *makeFloat64Array(NSData *buf)
{
    NSUInteger n = buf.length / sizeof(double);
    MPGOEncodingSpec *enc =
        [MPGOEncodingSpec specWithPrecision:MPGOPrecisionFloat64
                       compressionAlgorithm:MPGOCompressionNone
                                  byteOrder:MPGOByteOrderLittleEndian];
    return [[MPGOSignalArray alloc] initWithBuffer:buf
                                            length:n
                                          encoding:enc
                                              axis:nil];
}

#pragma mark - NSXMLParserDelegate

- (void)parser:(NSXMLParser *)parser
didStartElement:(NSString *)elementName
  namespaceURI:(NSString *)namespaceURI
 qualifiedName:(NSString *)qName
    attributes:(NSDictionary<NSString *, NSString *> *)attrs
{
    if ([elementName isEqualToString:@"acquisitionParameterSet"]) {
        _inAcquisitionParameterSet = YES;
        // Real nmrML 1.0 carries numberOfScans as an attribute, not a cvParam.
        NSString *ns = attrs[@"numberOfScans"];
        if (ns.length > 0) _numberOfScans = (NSUInteger)[ns integerValue];
        return;
    }

    // Real nmrML uses dedicated child elements for the key acquisition
    // parameters rather than cvParams. Handle both.
    if (_inAcquisitionParameterSet) {
        if ([elementName isEqualToString:@"acquisitionNucleus"]) {
            NSString *name = attrs[@"name"];
            if (name.length > 0) {
                // Map common long names to canonical short forms.
                if ([name rangeOfString:@"hydrogen"].location != NSNotFound)
                    _nucleusType = @"1H";
                else if ([name rangeOfString:@"carbon"].location != NSNotFound)
                    _nucleusType = @"13C";
                else if ([name rangeOfString:@"nitrogen"].location != NSNotFound)
                    _nucleusType = @"15N";
                else if ([name rangeOfString:@"phosphorus"].location != NSNotFound)
                    _nucleusType = @"31P";
                else
                    _nucleusType = [name copy];
            }
            return;
        }
        if ([elementName isEqualToString:@"irradiationFrequency"]) {
            // Stored in Hz; MPGO_NMR_FREQUENCY is in MHz.
            double hz = [attrs[@"value"] doubleValue];
            if (hz > 0) _spectrometerFrequencyMHz = hz / 1.0e6;
            return;
        }
        if ([elementName isEqualToString:@"sweepWidth"]) {
            _sweepWidthPpm = [attrs[@"value"] doubleValue];
            return;
        }
        if ([elementName isEqualToString:@"DirectDimensionParameterSet"]) {
            NSString *ndp = attrs[@"numberOfDataPoints"];
            if (ndp.length > 0 && _dwellTimeSeconds == 0 && _sweepWidthPpm > 0) {
                // If explicit dwell isn't given elsewhere we leave it 0;
                // consumers can derive from sweep width if desired.
                (void)ndp;
            }
            return;
        }
    }

    if ([elementName isEqualToString:@"fidData"]) {
        _inFidData = YES;
        NSString *comp = attrs[@"compressed"];
        _fidCompressed = ([comp isEqualToString:@"true"] ||
                          [comp isEqualToString:@"zlib"]);
        _fidByteFormat = [attrs[@"byteFormat"] copy] ?: @"float64";
        [_textBuf setString:@""];
        _capturingText = YES;
        return;
    }

    if ([elementName isEqualToString:@"spectrum1D"]) {
        _inSpectrum1D = YES;
        _currentXAxisData = nil;
        _currentYAxisData = nil;
        _currentInterleavedXY = nil;
        NSString *n = attrs[@"numberOfDataPoints"];
        _current1DNumberOfDataPoints = n ? (NSUInteger)[n integerValue] : 0;
        return;
    }

    if ([elementName isEqualToString:@"xAxis"]) { _inXAxis = YES; return; }
    if ([elementName isEqualToString:@"yAxis"]) { _inYAxis = YES; return; }

    if ([elementName isEqualToString:@"spectrumDataArray"]) {
        _inSpectrumDataArray = YES;
        NSString *comp = attrs[@"compressed"];
        _currentDataArrayCompressed = ([comp isEqualToString:@"true"] ||
                                        [comp isEqualToString:@"zlib"]);
        [_textBuf setString:@""];
        _capturingText = YES;
        return;
    }

    if ([elementName isEqualToString:@"cvParam"]) {
        [self handleCVParamWithAttributes:attrs];
        return;
    }
}

- (void)handleCVParamWithAttributes:(NSDictionary<NSString *, NSString *> *)attrs
{
    NSString *acc   = attrs[@"accession"];
    NSString *value = attrs[@"value"];
    if (!acc) return;

    if (!_inAcquisitionParameterSet) return;

    if ([MPGOCVTermMapper isSpectrometerFrequencyAccession:acc]) {
        _spectrometerFrequencyMHz = [value doubleValue];
        return;
    }
    if ([MPGOCVTermMapper isNucleusAccession:acc]) {
        _nucleusType = [value copy] ?: @"";
        return;
    }
    if ([MPGOCVTermMapper isNumberOfScansAccession:acc]) {
        _numberOfScans = (NSUInteger)[value integerValue];
        return;
    }
    if ([MPGOCVTermMapper isDwellTimeAccession:acc]) {
        _dwellTimeSeconds = [value doubleValue];
        return;
    }
    if ([MPGOCVTermMapper isSweepWidthAccession:acc]) {
        _sweepWidthPpm = [value doubleValue];
        return;
    }
}

- (void)parser:(NSXMLParser *)parser foundCharacters:(NSString *)string
{
    if (_capturingText) [_textBuf appendString:string];
}

- (void)parser:(NSXMLParser *)parser
 didEndElement:(NSString *)elementName
  namespaceURI:(NSString *)namespaceURI
 qualifiedName:(NSString *)qName
{
    if ([elementName isEqualToString:@"acquisitionParameterSet"]) {
        _inAcquisitionParameterSet = NO;
        return;
    }

    if ([elementName isEqualToString:@"fidData"]) {
        [self finishFidData];
        _inFidData = NO;
        _capturingText = NO;
        return;
    }

    if ([elementName isEqualToString:@"spectrumDataArray"]) {
        _inSpectrumDataArray = NO;
        _capturingText = NO;
        NSData *decoded = [MPGOBase64 decodeString:_textBuf
                                       zlibInflate:_currentDataArrayCompressed];
        if (!decoded) {
            [self failWithCode:MPGONmrMLReaderErrorBase64Failed
                       message:@"failed to decode spectrumDataArray"];
            return;
        }
        if (_inXAxis) _currentXAxisData = decoded;
        else if (_inYAxis) _currentYAxisData = decoded;
        else if (_inSpectrum1D) _currentInterleavedXY = decoded;
        return;
    }

    if ([elementName isEqualToString:@"xAxis"]) { _inXAxis = NO; return; }
    if ([elementName isEqualToString:@"yAxis"]) { _inYAxis = NO; return; }

    if ([elementName isEqualToString:@"spectrum1D"]) {
        [self finishSpectrum1D];
        _inSpectrum1D = NO;
        return;
    }
}

- (void)finishFidData
{
    if (_internalError) return;
    NSData *decoded = [MPGOBase64 decodeString:_textBuf zlibInflate:_fidCompressed];
    if (!decoded) {
        [self failWithCode:MPGONmrMLReaderErrorBase64Failed
                   message:@"failed to decode fidData"];
        return;
    }

    // byteFormat varies across vendor nmrML files. Widen each sample to
    // float64 so the in-memory representation is always the MPGO
    // complex128 (interleaved real+imag doubles).
    NSData *complexBuf = nil;
    NSUInteger complexLen = 0;
    BOOL isInt = ([_fidByteFormat rangeOfString:@"Integer"].location != NSNotFound ||
                  [_fidByteFormat rangeOfString:@"int32"].location != NSNotFound);
    BOOL isInt64 = ([_fidByteFormat rangeOfString:@"Long"].location != NSNotFound ||
                    [_fidByteFormat rangeOfString:@"int64"].location != NSNotFound);

    if (isInt) {
        if (decoded.length % (2 * sizeof(int32_t)) != 0) {
            [self failWithCode:MPGONmrMLReaderErrorArrayLengthMismatch
                       message:@"int32 fidData length is not a whole number of complex pairs"];
            return;
        }
        NSUInteger sampleCount = decoded.length / sizeof(int32_t);
        complexLen = sampleCount / 2;
        NSMutableData *out = [NSMutableData dataWithLength:sampleCount * sizeof(double)];
        const int32_t *src = decoded.bytes;
        double *dst = out.mutableBytes;
        for (NSUInteger i = 0; i < sampleCount; i++) dst[i] = (double)src[i];
        complexBuf = out;
    } else if (isInt64) {
        if (decoded.length % (2 * sizeof(int64_t)) != 0) {
            [self failWithCode:MPGONmrMLReaderErrorArrayLengthMismatch
                       message:@"int64 fidData length is not a whole number of complex pairs"];
            return;
        }
        NSUInteger sampleCount = decoded.length / sizeof(int64_t);
        complexLen = sampleCount / 2;
        NSMutableData *out = [NSMutableData dataWithLength:sampleCount * sizeof(double)];
        const int64_t *src = decoded.bytes;
        double *dst = out.mutableBytes;
        for (NSUInteger i = 0; i < sampleCount; i++) dst[i] = (double)src[i];
        complexBuf = out;
    } else {
        // Default: float64 complex (synthetic test fixture shape)
        if (decoded.length % (2 * sizeof(double)) != 0) {
            [self failWithCode:MPGONmrMLReaderErrorArrayLengthMismatch
                       message:@"float64 fidData length is not a whole number of complex samples"];
            return;
        }
        complexLen = decoded.length / (2 * sizeof(double));
        complexBuf = decoded;
    }

    MPGOFreeInductionDecay *fid =
        [[MPGOFreeInductionDecay alloc] initWithComplexBuffer:complexBuf
                                                 complexLength:complexLen
                                              dwellTimeSeconds:_dwellTimeSeconds
                                                     scanCount:_numberOfScans
                                                  receiverGain:1.0];
    [_fids addObject:fid];
}

- (void)finishSpectrum1D
{
    if (_internalError) return;

    // v0.9 M64 canonical form: single <spectrumDataArray> directly
    // under <spectrum1D> carrying interleaved (x,y) doubles.
    // Detected by encodedLength == 2 * numberOfDataPoints * 8.
    NSData *csData = _currentXAxisData;
    NSData *inData = _currentYAxisData;
    if (_currentInterleavedXY) {
        NSUInteger totalDoubles = _currentInterleavedXY.length / sizeof(double);
        NSUInteger n = _current1DNumberOfDataPoints;
        const double *xy = (const double *)_currentInterleavedXY.bytes;
        if (n > 0 && totalDoubles == 2 * n) {
            NSMutableData *cs = [NSMutableData dataWithLength:n * sizeof(double)];
            NSMutableData *it = [NSMutableData dataWithLength:n * sizeof(double)];
            double *csp = (double *)cs.mutableBytes;
            double *itp = (double *)it.mutableBytes;
            for (NSUInteger i = 0; i < n; i++) {
                csp[i] = xy[2*i    ];
                itp[i] = xy[2*i + 1];
            }
            csData = cs;
            inData = it;
        } else if (n > 0 && totalDoubles == n) {
            // y-only external nmrML — synthesize x-axis.
            NSMutableData *cs = [NSMutableData dataWithLength:n * sizeof(double)];
            double *csp = (double *)cs.mutableBytes;
            for (NSUInteger i = 0; i < n; i++) csp[i] = (double)i;
            csData = cs;
            inData = _currentInterleavedXY;
        } else if (totalDoubles % 2 == 0 && totalDoubles >= 2) {
            NSUInteger half = totalDoubles / 2;
            NSMutableData *cs = [NSMutableData dataWithLength:half * sizeof(double)];
            NSMutableData *it = [NSMutableData dataWithLength:half * sizeof(double)];
            double *csp = (double *)cs.mutableBytes;
            double *itp = (double *)it.mutableBytes;
            for (NSUInteger i = 0; i < half; i++) {
                csp[i] = xy[2*i    ];
                itp[i] = xy[2*i + 1];
            }
            csData = cs;
            inData = it;
        }
    }
    if (!csData || !inData) return;

    MPGOSignalArray *csArr = makeFloat64Array(csData);
    MPGOSignalArray *inArr = makeFloat64Array(inData);
    if (csArr.length != inArr.length) {
        [self failWithCode:MPGONmrMLReaderErrorArrayLengthMismatch
                   message:@"spectrum1D xAxis and yAxis have different lengths"];
        return;
    }

    NSError *err = nil;
    MPGONMRSpectrum *spec =
        [[MPGONMRSpectrum alloc] initWithChemicalShiftArray:csArr
                                             intensityArray:inArr
                                                nucleusType:_nucleusType
                                   spectrometerFrequencyMHz:_spectrometerFrequencyMHz
                                              indexPosition:_currentSpecIndex++
                                            scanTimeSeconds:0
                                                      error:&err];
    if (spec) [_spectra addObject:spec];
    else if (err) _internalError = err;

    _currentXAxisData = nil;
    _currentYAxisData = nil;
    _currentInterleavedXY = nil;
    _current1DNumberOfDataPoints = 0;
}

- (void)parser:(NSXMLParser *)parser parseErrorOccurred:(NSError *)parseError
{
    if (!_internalError) _internalError = parseError;
}

@end
