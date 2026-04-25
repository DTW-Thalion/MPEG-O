/*
 * Licensed under the Apache License, Version 2.0.
 * See LICENSE-IMPORT-EXPORT in the repository root.
 *
 * SPDX-License-Identifier: Apache-2.0
 */

#import "TTIONmrMLReader.h"
#import "TTIOBase64.h"
#import "TTIOCVTermMapper.h"

#import "Core/TTIOSignalArray.h"
#import "ValueClasses/TTIOEncodingSpec.h"
#import "ValueClasses/TTIOAxisDescriptor.h"
#import "ValueClasses/TTIOValueRange.h"
#import "ValueClasses/TTIOEnums.h"
#import "Spectra/TTIONMRSpectrum.h"
#import "Spectra/TTIOFreeInductionDecay.h"
#import "Run/TTIOAcquisitionRun.h"
#import "Run/TTIOInstrumentConfig.h"
#import "Dataset/TTIOSpectralDataset.h"

NSString *const TTIONmrMLReaderErrorDomain = @"TTIONmrMLReaderErrorDomain";

@interface TTIONmrMLReader () <NSXMLParserDelegate>
@end

@implementation TTIONmrMLReader
{
    TTIOSpectralDataset *_dataset;
    NSMutableArray<TTIOFreeInductionDecay *> *_fids;
    NSMutableArray<TTIONMRSpectrum *> *_spectra;

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

+ (TTIOSpectralDataset *)readFromFilePath:(NSString *)path error:(NSError **)error
{
    TTIONmrMLReader *r = [self parseFilePath:path error:error];
    return r.dataset;
}

+ (TTIOSpectralDataset *)readFromURL:(NSURL *)url error:(NSError **)error
{
    if (!url.isFileURL) {
        if (error) *error = [NSError errorWithDomain:TTIONmrMLReaderErrorDomain
                                                 code:TTIONmrMLReaderErrorParseFailed
                                             userInfo:@{NSLocalizedDescriptionKey:
                            @"Only file URLs are supported"}];
        return nil;
    }
    return [self readFromFilePath:url.path error:error];
}

+ (TTIOSpectralDataset *)readFromData:(NSData *)data error:(NSError **)error
{
    TTIONmrMLReader *r = [self parseData:data error:error];
    return r.dataset;
}

+ (instancetype)parseFilePath:(NSString *)path error:(NSError **)error
{
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data) {
        if (error) *error = [NSError errorWithDomain:TTIONmrMLReaderErrorDomain
                                                 code:TTIONmrMLReaderErrorParseFailed
                                             userInfo:@{NSLocalizedDescriptionKey:
                            [NSString stringWithFormat:@"Cannot read %@", path]}];
        return nil;
    }
    return [self parseData:data error:error];
}

+ (instancetype)parseData:(NSData *)data error:(NSError **)error
{
    if (!data) {
        if (error) *error = [NSError errorWithDomain:TTIONmrMLReaderErrorDomain
                                                 code:TTIONmrMLReaderErrorParseFailed
                                             userInfo:@{NSLocalizedDescriptionKey:
                            @"nil input data"}];
        return nil;
    }
    TTIONmrMLReader *r = [[self alloc] init];
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
            e = [NSError errorWithDomain:TTIONmrMLReaderErrorDomain
                                    code:TTIONmrMLReaderErrorParseFailed
                                userInfo:@{NSLocalizedDescriptionKey: @"unknown parse failure"}];
        }
        if (error) *error = e;
        return NO;
    }

    // Build the dataset after parse completes. Wrap parsed spectrum1D
    // entries in a single NMR acquisition run.
    TTIOAcquisitionRun *run = nil;
    if (_spectra.count > 0) {
        TTIOInstrumentConfig *cfg =
            [[TTIOInstrumentConfig alloc] initWithManufacturer:@""
                                                         model:@""
                                                  serialNumber:@""
                                                    sourceType:@""
                                                  analyzerType:@""
                                                  detectorType:@""];
        run = [[TTIOAcquisitionRun alloc] initWithSpectra:[_spectra copy]
                                          acquisitionMode:TTIOAcquisitionMode1DNMR
                                         instrumentConfig:cfg];
    }

    NSDictionary *msRuns = run ? @{@"nmr_run": run} : @{};
    _dataset = [[TTIOSpectralDataset alloc] initWithTitle:@"nmrml_import"
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

- (void)failWithCode:(TTIONmrMLReaderErrorCode)code message:(NSString *)msg
{
    _internalError = [NSError errorWithDomain:TTIONmrMLReaderErrorDomain
                                         code:code
                                     userInfo:@{NSLocalizedDescriptionKey: msg ?: @""}];
}

static TTIOSignalArray *makeFloat64Array(NSData *buf)
{
    NSUInteger n = buf.length / sizeof(double);
    TTIOEncodingSpec *enc =
        [TTIOEncodingSpec specWithPrecision:TTIOPrecisionFloat64
                       compressionAlgorithm:TTIOCompressionNone
                                  byteOrder:TTIOByteOrderLittleEndian];
    return [[TTIOSignalArray alloc] initWithBuffer:buf
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
            // Stored in Hz; TTIO_NMR_FREQUENCY is in MHz.
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

    if ([TTIOCVTermMapper isSpectrometerFrequencyAccession:acc]) {
        _spectrometerFrequencyMHz = [value doubleValue];
        return;
    }
    if ([TTIOCVTermMapper isNucleusAccession:acc]) {
        _nucleusType = [value copy] ?: @"";
        return;
    }
    if ([TTIOCVTermMapper isNumberOfScansAccession:acc]) {
        _numberOfScans = (NSUInteger)[value integerValue];
        return;
    }
    if ([TTIOCVTermMapper isDwellTimeAccession:acc]) {
        _dwellTimeSeconds = [value doubleValue];
        return;
    }
    if ([TTIOCVTermMapper isSweepWidthAccession:acc]) {
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
        NSData *decoded = [TTIOBase64 decodeString:_textBuf
                                       zlibInflate:_currentDataArrayCompressed];
        if (!decoded) {
            [self failWithCode:TTIONmrMLReaderErrorBase64Failed
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
    NSData *decoded = [TTIOBase64 decodeString:_textBuf zlibInflate:_fidCompressed];
    if (!decoded) {
        [self failWithCode:TTIONmrMLReaderErrorBase64Failed
                   message:@"failed to decode fidData"];
        return;
    }

    // byteFormat varies across vendor nmrML files. Widen each sample to
    // float64 so the in-memory representation is always the TTIO
    // complex128 (interleaved real+imag doubles).
    NSData *complexBuf = nil;
    NSUInteger complexLen = 0;
    BOOL isInt = ([_fidByteFormat rangeOfString:@"Integer"].location != NSNotFound ||
                  [_fidByteFormat rangeOfString:@"int32"].location != NSNotFound);
    BOOL isInt64 = ([_fidByteFormat rangeOfString:@"Long"].location != NSNotFound ||
                    [_fidByteFormat rangeOfString:@"int64"].location != NSNotFound);

    if (isInt) {
        if (decoded.length % (2 * sizeof(int32_t)) != 0) {
            [self failWithCode:TTIONmrMLReaderErrorArrayLengthMismatch
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
            [self failWithCode:TTIONmrMLReaderErrorArrayLengthMismatch
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
            [self failWithCode:TTIONmrMLReaderErrorArrayLengthMismatch
                       message:@"float64 fidData length is not a whole number of complex samples"];
            return;
        }
        complexLen = decoded.length / (2 * sizeof(double));
        complexBuf = decoded;
    }

    TTIOFreeInductionDecay *fid =
        [[TTIOFreeInductionDecay alloc] initWithComplexBuffer:complexBuf
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

    TTIOSignalArray *csArr = makeFloat64Array(csData);
    TTIOSignalArray *inArr = makeFloat64Array(inData);
    if (csArr.length != inArr.length) {
        [self failWithCode:TTIONmrMLReaderErrorArrayLengthMismatch
                   message:@"spectrum1D xAxis and yAxis have different lengths"];
        return;
    }

    NSError *err = nil;
    TTIONMRSpectrum *spec =
        [[TTIONMRSpectrum alloc] initWithChemicalShiftArray:csArr
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
