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
        return;
    }

    if ([elementName isEqualToString:@"fidData"]) {
        _inFidData = YES;
        NSString *comp = attrs[@"compressed"];
        _fidCompressed = ([comp isEqualToString:@"true"] ||
                          [comp isEqualToString:@"zlib"]);
        [_textBuf setString:@""];
        _capturingText = YES;
        return;
    }

    if ([elementName isEqualToString:@"spectrum1D"]) {
        _inSpectrum1D = YES;
        _currentXAxisData = nil;
        _currentYAxisData = nil;
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
    // float64 complex: interleaved real+imag doubles. Total bytes
    // must be a multiple of 2 * sizeof(double).
    if (decoded.length % (2 * sizeof(double)) != 0) {
        [self failWithCode:MPGONmrMLReaderErrorArrayLengthMismatch
                   message:@"fidData byte length is not a whole number of complex samples"];
        return;
    }
    NSUInteger complexLen = decoded.length / (2 * sizeof(double));

    MPGOFreeInductionDecay *fid =
        [[MPGOFreeInductionDecay alloc] initWithComplexBuffer:decoded
                                                 complexLength:complexLen
                                              dwellTimeSeconds:_dwellTimeSeconds
                                                     scanCount:_numberOfScans
                                                  receiverGain:1.0];
    [_fids addObject:fid];
}

- (void)finishSpectrum1D
{
    if (_internalError) return;
    if (!_currentXAxisData || !_currentYAxisData) return;

    MPGOSignalArray *csArr = makeFloat64Array(_currentXAxisData);
    MPGOSignalArray *inArr = makeFloat64Array(_currentYAxisData);
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
}

- (void)parser:(NSXMLParser *)parser parseErrorOccurred:(NSError *)parseError
{
    if (!_internalError) _internalError = parseError;
}

@end
