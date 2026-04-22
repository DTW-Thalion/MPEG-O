/*
 * Licensed under the Apache License, Version 2.0.
 * See LICENSE-IMPORT-EXPORT in the repository root.
 *
 * SPDX-License-Identifier: Apache-2.0
 */

#import "MPGOMzMLReader.h"
#import "MPGOBase64.h"
#import "MPGOCVTermMapper.h"

#import "Core/MPGOSignalArray.h"
#import "ValueClasses/MPGOEncodingSpec.h"
#import "ValueClasses/MPGOAxisDescriptor.h"
#import "ValueClasses/MPGOValueRange.h"
#import "ValueClasses/MPGOEnums.h"
#import "ValueClasses/MPGOIsolationWindow.h"
#import "Spectra/MPGOSpectrum.h"
#import "Spectra/MPGOMassSpectrum.h"
#import "Spectra/MPGOChromatogram.h"
#import "Run/MPGOAcquisitionRun.h"
#import "Run/MPGOInstrumentConfig.h"
#import "Dataset/MPGOSpectralDataset.h"

NSString *const MPGOMzMLReaderErrorDomain = @"MPGOMzMLReaderErrorDomain";

@interface MPGOMzMLReader () <NSXMLParserDelegate>
@end

@implementation MPGOMzMLReader
{
    // Output
    MPGOSpectralDataset *_dataset;
    NSMutableArray<MPGOChromatogram *> *_chromatograms;

    // Parse state
    NSError *_internalError;
    NSString *_runId;
    NSMutableArray<MPGOMassSpectrum *> *_runSpectra;

    // Current spectrum
    BOOL _inSpectrum;
    NSUInteger _specIndex;
    NSUInteger _specDefaultLen;
    NSUInteger _msLevel;
    MPGOPolarity _polarity;
    double _scanTime;
    double _precursorMz;
    NSUInteger _precursorCharge;
    double _scanWinLow;
    double _scanWinHigh;
    BOOL _hasScanWin;
    NSMutableDictionary<NSString *, MPGOSignalArray *> *_specArrays;

    // Current chromatogram
    BOOL _inChromatogram;
    NSUInteger _chromDefaultLen;
    MPGOChromatogramType _chromType;
    double _chromTargetMz;        // M24: parsed from userParam
    double _chromPrecursorMz;     // M24
    double _chromProductMz;       // M24
    NSMutableDictionary<NSString *, MPGOSignalArray *> *_chromArrays;

    // Current binaryDataArray
    BOOL _inBinaryDataArray;
    MPGOPrecision _binPrecision;
    MPGOCompression _binCompression;
    NSString *_binArrayName;

    // Text accumulator
    BOOL _inBinary;
    NSMutableString *_binText;

    // Context depth counters
    NSInteger _selectedIonDepth;
    NSInteger _scanWindowDepth;
    NSInteger _scanDepth;
    NSInteger _precursorDepth;
    NSInteger _activationDepth;       // M74
    NSInteger _isolationWindowDepth;  // M74

    // M74: per-spectrum activation + isolation window being accumulated
    MPGOActivationMethod _activationMethod;
    double _isolationTargetMz;
    double _isolationLowerOffset;
    double _isolationUpperOffset;
    BOOL _anyActivationDetail;
}

@synthesize dataset = _dataset;
@synthesize chromatograms = _chromatograms;

#pragma mark - Class entry points

+ (MPGOSpectralDataset *)readFromFilePath:(NSString *)path error:(NSError **)error
{
    MPGOMzMLReader *r = [self parseFilePath:path error:error];
    return r.dataset;
}

+ (MPGOSpectralDataset *)readFromURL:(NSURL *)url error:(NSError **)error
{
    if (!url.isFileURL) {
        if (error) {
            *error = [NSError errorWithDomain:MPGOMzMLReaderErrorDomain
                                         code:MPGOMzMLReaderErrorParseFailed
                                     userInfo:@{NSLocalizedDescriptionKey: @"Only file URLs are supported"}];
        }
        return nil;
    }
    return [self readFromFilePath:url.path error:error];
}

+ (MPGOSpectralDataset *)readFromData:(NSData *)data error:(NSError **)error
{
    MPGOMzMLReader *r = [self parseData:data error:error];
    return r.dataset;
}

+ (instancetype)parseFilePath:(NSString *)path error:(NSError **)error
{
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data) {
        if (error) {
            *error = [NSError errorWithDomain:MPGOMzMLReaderErrorDomain
                                         code:MPGOMzMLReaderErrorParseFailed
                                     userInfo:@{NSLocalizedDescriptionKey:
                        [NSString stringWithFormat:@"Cannot read %@", path]}];
        }
        return nil;
    }
    return [self parseData:data error:error];
}

+ (instancetype)parseData:(NSData *)data error:(NSError **)error
{
    if (!data) {
        if (error) {
            *error = [NSError errorWithDomain:MPGOMzMLReaderErrorDomain
                                         code:MPGOMzMLReaderErrorParseFailed
                                     userInfo:@{NSLocalizedDescriptionKey: @"nil input data"}];
        }
        return nil;
    }
    MPGOMzMLReader *r = [[self alloc] init];
    if (![r parseData:data error:error]) {
        return nil;
    }
    return r;
}

#pragma mark - Instance init and driver

- (instancetype)init
{
    self = [super init];
    if (self) {
        _chromatograms = [NSMutableArray array];
        _runSpectra = [NSMutableArray array];
        _specArrays = [NSMutableDictionary dictionary];
        _chromArrays = [NSMutableDictionary dictionary];
        _binText = [NSMutableString string];
    }
    return self;
}

- (BOOL)parseData:(NSData *)data error:(NSError **)error
{
    NSXMLParser *parser = [[NSXMLParser alloc] initWithData:data];
    parser.delegate = self;
    parser.shouldProcessNamespaces = NO;
    parser.shouldReportNamespacePrefixes = NO;
    parser.shouldResolveExternalEntities = NO;

    BOOL ok = [parser parse];
    if (!ok || _internalError) {
        NSError *e = _internalError ?: [parser parserError];
        if (!e) {
            e = [NSError errorWithDomain:MPGOMzMLReaderErrorDomain
                                    code:MPGOMzMLReaderErrorParseFailed
                                userInfo:@{NSLocalizedDescriptionKey: @"Unknown parse failure"}];
        }
        if (error) *error = e;
        return NO;
    }

    if (!_dataset) {
        // <run> closed but build failed, or no run present
        if (error) {
            *error = [NSError errorWithDomain:MPGOMzMLReaderErrorDomain
                                         code:MPGOMzMLReaderErrorMissingSpectrumList
                                     userInfo:@{NSLocalizedDescriptionKey: @"No usable <run> in document"}];
        }
        return NO;
    }
    return YES;
}

#pragma mark - Helpers

- (void)failWithCode:(MPGOMzMLReaderErrorCode)code message:(NSString *)msg
{
    _internalError = [NSError errorWithDomain:MPGOMzMLReaderErrorDomain
                                         code:code
                                     userInfo:@{NSLocalizedDescriptionKey: msg ?: @""}];
}

- (void)resetSpectrumState
{
    _inSpectrum = NO;
    _specIndex = 0;
    _specDefaultLen = 0;
    _msLevel = 1;
    _polarity = MPGOPolarityUnknown;
    _scanTime = 0.0;
    _precursorMz = 0.0;
    _precursorCharge = 0;
    _scanWinLow = 0.0;
    _scanWinHigh = 0.0;
    _hasScanWin = NO;
    // M74
    _activationMethod = MPGOActivationMethodNone;
    _isolationTargetMz = 0.0;
    _isolationLowerOffset = 0.0;
    _isolationUpperOffset = 0.0;
    [_specArrays removeAllObjects];
}

- (void)resetChromatogramState
{
    _inChromatogram = NO;
    _chromDefaultLen = 0;
    _chromType = MPGOChromatogramTypeTIC;
    _chromTargetMz    = 0.0;
    _chromPrecursorMz = 0.0;
    _chromProductMz   = 0.0;
    [_chromArrays removeAllObjects];
}

- (void)resetBinaryState
{
    _inBinaryDataArray = NO;
    _binPrecision = MPGOPrecisionFloat64;
    _binCompression = MPGOCompressionNone;
    _binArrayName = nil;
}

- (MPGOSignalArray *)makeSignalArrayFromDecodedData:(NSData *)decoded
                                             length:(NSUInteger)expectedLen
                                             axisName:(NSString *)axisName
                                             axisUnit:(NSString *)axisUnit
{
    MPGOEncodingSpec *spec =
        [MPGOEncodingSpec specWithPrecision:_binPrecision
                       compressionAlgorithm:MPGOCompressionNone
                                  byteOrder:MPGOByteOrderLittleEndian];

    NSUInteger elemSize = [spec elementSize];
    if (elemSize == 0) return nil;

    NSUInteger actualLen = decoded.length / elemSize;
    if (expectedLen > 0 && actualLen != expectedLen) {
        [self failWithCode:MPGOMzMLReaderErrorArrayLengthMismatch
                   message:[NSString stringWithFormat:
                            @"binaryDataArray length mismatch: expected %lu, got %lu",
                            (unsigned long)expectedLen, (unsigned long)actualLen]];
        return nil;
    }

    MPGOValueRange *range = [MPGOValueRange rangeWithMinimum:0 maximum:0];
    MPGOAxisDescriptor *axis =
        [MPGOAxisDescriptor descriptorWithName:axisName
                                          unit:axisUnit
                                    valueRange:range
                                  samplingMode:MPGOSamplingModeNonUniform];

    return [[MPGOSignalArray alloc] initWithBuffer:decoded
                                            length:actualLen
                                          encoding:spec
                                              axis:axis];
}

- (NSString *)axisUnitForName:(NSString *)name
{
    if ([name isEqualToString:@"mz"]) return @"m/z";
    if ([name isEqualToString:@"intensity"]) return @"counts";
    if ([name isEqualToString:@"time"]) return @"second";
    return @"";
}

#pragma mark - NSXMLParserDelegate

- (void)parser:(NSXMLParser *)parser
didStartElement:(NSString *)elementName
  namespaceURI:(NSString *)namespaceURI
 qualifiedName:(NSString *)qName
    attributes:(NSDictionary<NSString *, NSString *> *)attrs
{
    if ([elementName isEqualToString:@"run"]) {
        _runId = [attrs[@"id"] copy] ?: @"run";
        return;
    }

    if ([elementName isEqualToString:@"spectrum"]) {
        [self resetSpectrumState];
        _inSpectrum = YES;
        _specIndex = (NSUInteger)[attrs[@"index"] integerValue];
        _specDefaultLen = (NSUInteger)[attrs[@"defaultArrayLength"] integerValue];
        return;
    }

    if ([elementName isEqualToString:@"chromatogram"]) {
        [self resetChromatogramState];
        _inChromatogram = YES;
        _chromDefaultLen = (NSUInteger)[attrs[@"defaultArrayLength"] integerValue];
        return;
    }

    if ([elementName isEqualToString:@"binaryDataArray"]) {
        [self resetBinaryState];
        _inBinaryDataArray = YES;
        return;
    }

    if ([elementName isEqualToString:@"binary"]) {
        _inBinary = YES;
        [_binText setString:@""];
        return;
    }

    if ([elementName isEqualToString:@"precursor"])       { _precursorDepth++;      return; }
    if ([elementName isEqualToString:@"selectedIon"])     { _selectedIonDepth++;    return; }
    if ([elementName isEqualToString:@"scan"])            { _scanDepth++;           return; }
    if ([elementName isEqualToString:@"scanWindow"])      { _scanWindowDepth++;     return; }
    if ([elementName isEqualToString:@"activation"])      { _activationDepth++;     return; }
    if ([elementName isEqualToString:@"isolationWindow"]) { _isolationWindowDepth++; return; }

    if ([elementName isEqualToString:@"cvParam"]) {
        [self handleCVParamWithAttributes:attrs];
        return;
    }

    // M24: parse userParam target/precursor/product m/z inside a chromatogram.
    if ([elementName isEqualToString:@"userParam"] && _inChromatogram) {
        NSString *name = attrs[@"name"];
        double v = [attrs[@"value"] doubleValue];
        if ([name isEqualToString:@"target m/z"])    _chromTargetMz    = v;
        else if ([name isEqualToString:@"precursor m/z"]) _chromPrecursorMz = v;
        else if ([name isEqualToString:@"product m/z"])   _chromProductMz   = v;
        return;
    }
}

- (void)handleCVParamWithAttributes:(NSDictionary<NSString *, NSString *> *)attrs
{
    NSString *acc   = attrs[@"accession"];
    NSString *value = attrs[@"value"];
    if (!acc) return;

    // 1. Inside binaryDataArray: type/compression/role
    if (_inBinaryDataArray) {
        NSString *arrName = [MPGOCVTermMapper signalArrayNameForAccession:acc];
        if (arrName) { _binArrayName = arrName; return; }

        if ([acc isEqualToString:@"MS:1000521"] ||
            [acc isEqualToString:@"MS:1000523"] ||
            [acc isEqualToString:@"MS:1000519"] ||
            [acc isEqualToString:@"MS:1000522"]) {
            _binPrecision = [MPGOCVTermMapper precisionForAccession:acc];
            return;
        }
        if ([acc isEqualToString:@"MS:1000574"] ||
            [acc isEqualToString:@"MS:1000576"]) {
            _binCompression = [MPGOCVTermMapper compressionForAccession:acc];
            return;
        }
        return;
    }

    // 2a. (M74) Inside <precursor><activation>: dissociation method cvParams.
    // Gate on _precursorDepth so <product> siblings (SRM) are ignored.
    if (_activationDepth > 0 && _precursorDepth > 0 && _inSpectrum) {
        if ([MPGOCVTermMapper isActivationMethodAccession:acc]) {
            _activationMethod = [MPGOCVTermMapper activationMethodForAccession:acc];
            _anyActivationDetail = YES;
        }
        return;
    }

    // 2b. (M74) Inside <precursor><isolationWindow>: target m/z + offsets.
    if (_isolationWindowDepth > 0 && _precursorDepth > 0 && _inSpectrum) {
        if ([MPGOCVTermMapper isIsolationWindowTargetMzAccession:acc]) {
            _isolationTargetMz = [value doubleValue];
            _anyActivationDetail = YES;
        } else if ([MPGOCVTermMapper isIsolationWindowLowerOffsetAccession:acc]) {
            _isolationLowerOffset = [value doubleValue];
            _anyActivationDetail = YES;
        } else if ([MPGOCVTermMapper isIsolationWindowUpperOffsetAccession:acc]) {
            _isolationUpperOffset = [value doubleValue];
            _anyActivationDetail = YES;
        }
        return;
    }

    // 2. Inside selectedIon: precursor m/z and charge
    if (_selectedIonDepth > 0 && _inSpectrum) {
        if ([MPGOCVTermMapper isSelectedIonMzAccession:acc]) {
            _precursorMz = [value doubleValue];
            return;
        }
        if ([MPGOCVTermMapper isChargeStateAccession:acc]) {
            _precursorCharge = (NSUInteger)[value integerValue];
            return;
        }
        return;
    }

    // 3. Inside scanWindow: lower/upper limits
    if (_scanWindowDepth > 0 && _inSpectrum) {
        if ([MPGOCVTermMapper isScanWindowLowerAccession:acc]) {
            _scanWinLow = [value doubleValue];
            _hasScanWin = YES;
            return;
        }
        if ([MPGOCVTermMapper isScanWindowUpperAccession:acc]) {
            _scanWinHigh = [value doubleValue];
            _hasScanWin = YES;
            return;
        }
        return;
    }

    // 4. Inside scan (not scanWindow): scan start time
    if (_scanDepth > 0 && _inSpectrum) {
        if ([MPGOCVTermMapper isScanStartTimeAccession:acc]) {
            double t = [value doubleValue];
            NSString *unit = attrs[@"unitAccession"];
            if ([unit isEqualToString:@"UO:0000031"]) t *= 60.0; // minutes -> seconds
            _scanTime = t;
            return;
        }
        return;
    }

    // 5. Inside spectrum directly: level, polarity, base peak, TIC
    if (_inSpectrum && !_inChromatogram) {
        if ([MPGOCVTermMapper isMSLevelAccession:acc]) {
            _msLevel = (NSUInteger)[value integerValue];
            return;
        }
        if ([MPGOCVTermMapper isPositivePolarityAccession:acc]) {
            _polarity = MPGOPolarityPositive;
            return;
        }
        if ([MPGOCVTermMapper isNegativePolarityAccession:acc]) {
            _polarity = MPGOPolarityNegative;
            return;
        }
        // Scan start time can also appear directly inside <spectrum>
        if ([MPGOCVTermMapper isScanStartTimeAccession:acc]) {
            double t = [value doubleValue];
            NSString *unit = attrs[@"unitAccession"];
            if ([unit isEqualToString:@"UO:0000031"]) t *= 60.0;
            _scanTime = t;
            return;
        }
        return;
    }

    // 6. Inside chromatogram directly: detect TIC / XIC / SRM
    if (_inChromatogram) {
        if ([MPGOCVTermMapper isTotalIonChromatogramAccession:acc]) {
            _chromType = MPGOChromatogramTypeTIC;
            return;
        }
        if ([acc isEqualToString:@"MS:1000627"]) {    // M24: XIC
            _chromType = MPGOChromatogramTypeXIC;
            return;
        }
        if ([MPGOCVTermMapper isSelectedReactionMonitoringAccession:acc]) {
            _chromType = MPGOChromatogramTypeSRM;
            return;
        }
        return;
    }
}

- (void)parser:(NSXMLParser *)parser foundCharacters:(NSString *)string
{
    if (_inBinary) {
        [_binText appendString:string];
    }
}

- (void)parser:(NSXMLParser *)parser
 didEndElement:(NSString *)elementName
  namespaceURI:(NSString *)namespaceURI
 qualifiedName:(NSString *)qName
{
    if ([elementName isEqualToString:@"binary"]) {
        _inBinary = NO;
        return;
    }

    if ([elementName isEqualToString:@"binaryDataArray"]) {
        [self finishBinaryDataArray];
        return;
    }

    if ([elementName isEqualToString:@"spectrum"]) {
        [self finishSpectrum];
        return;
    }

    if ([elementName isEqualToString:@"chromatogram"]) {
        [self finishChromatogram];
        return;
    }

    if ([elementName isEqualToString:@"run"]) {
        [self finishRun];
        return;
    }

    if ([elementName isEqualToString:@"mzML"] ||
        [elementName isEqualToString:@"indexedmzML"]) {
        [self finishDocument];
        return;
    }

    if ([elementName isEqualToString:@"precursor"])       { _precursorDepth--;      return; }
    if ([elementName isEqualToString:@"selectedIon"])     { _selectedIonDepth--;    return; }
    if ([elementName isEqualToString:@"scan"])            { _scanDepth--;           return; }
    if ([elementName isEqualToString:@"scanWindow"])      { _scanWindowDepth--;     return; }
    if ([elementName isEqualToString:@"activation"])      { _activationDepth--;     return; }
    if ([elementName isEqualToString:@"isolationWindow"]) { _isolationWindowDepth--; return; }
}

#pragma mark - Element finishers

- (void)finishBinaryDataArray
{
    _inBinaryDataArray = NO;
    if (_internalError) return;

    BOOL needInflate = (_binCompression == MPGOCompressionZlib);
    NSData *decoded = [MPGOBase64 decodeString:_binText zlibInflate:needInflate];
    if (!decoded) {
        [self failWithCode:MPGOMzMLReaderErrorBase64Failed
                   message:@"Failed to decode binaryDataArray content"];
        return;
    }

    NSUInteger expected = _inSpectrum ? _specDefaultLen : _chromDefaultLen;
    NSString *name = _binArrayName ?: (_inChromatogram ? @"intensity" : @"intensity");
    NSString *unit = [self axisUnitForName:name];

    MPGOSignalArray *arr =
        [self makeSignalArrayFromDecodedData:decoded
                                      length:expected
                                    axisName:name
                                    axisUnit:unit];
    if (!arr) return;

    if (_inSpectrum) {
        _specArrays[name] = arr;
    } else if (_inChromatogram) {
        _chromArrays[name] = arr;
    }
}

- (void)finishSpectrum
{
    if (_internalError) { _inSpectrum = NO; return; }

    MPGOSignalArray *mz  = _specArrays[@"mz"];
    MPGOSignalArray *ints = _specArrays[@"intensity"];

    if (!mz || !ints) {
        // Spectrum with no binary content — skip silently.
        [self resetSpectrumState];
        return;
    }

    MPGOValueRange *win = nil;
    if (_hasScanWin) {
        win = [MPGOValueRange rangeWithMinimum:_scanWinLow maximum:_scanWinHigh];
    }

    // M74: build an IsolationWindow only when any of the three offsets was
    // reported. All-zero means "no window" and we pass nil to match Python/Java.
    MPGOIsolationWindow *iso = nil;
    if (_isolationTargetMz != 0.0 ||
        _isolationLowerOffset != 0.0 ||
        _isolationUpperOffset != 0.0) {
        iso = [MPGOIsolationWindow windowWithTargetMz:_isolationTargetMz
                                          lowerOffset:_isolationLowerOffset
                                          upperOffset:_isolationUpperOffset];
    }

    NSError *err = nil;
    MPGOMassSpectrum *spec =
        [[MPGOMassSpectrum alloc] initWithMzArray:mz
                                   intensityArray:ints
                                          msLevel:_msLevel
                                         polarity:_polarity
                                       scanWindow:win
                                 activationMethod:_activationMethod
                                  isolationWindow:iso
                                    indexPosition:_specIndex
                                  scanTimeSeconds:_scanTime
                                      precursorMz:_precursorMz
                                  precursorCharge:_precursorCharge
                                            error:&err];
    if (!spec) {
        [self failWithCode:MPGOMzMLReaderErrorArrayLengthMismatch
                   message:err.localizedDescription ?: @"MPGOMassSpectrum init failed"];
        return;
    }
    [_runSpectra addObject:spec];
    [self resetSpectrumState];
}

- (void)finishChromatogram
{
    if (_internalError) { _inChromatogram = NO; return; }

    MPGOSignalArray *time = _chromArrays[@"time"];
    MPGOSignalArray *ints = _chromArrays[@"intensity"];

    if (time && ints) {
        NSError *err = nil;
        MPGOChromatogram *c =
            [[MPGOChromatogram alloc] initWithTimeArray:time
                                         intensityArray:ints
                                                   type:_chromType
                                               targetMz:_chromTargetMz
                                            precursorMz:_chromPrecursorMz
                                              productMz:_chromProductMz
                                                  error:&err];
        if (c) [_chromatograms addObject:c];
    }
    [self resetChromatogramState];
}

- (void)finishRun
{
    if (_runSpectra.count == 0) return;

    MPGOInstrumentConfig *config =
        [[MPGOInstrumentConfig alloc] initWithManufacturer:@""
                                                     model:@""
                                              serialNumber:@""
                                                sourceType:@""
                                              analyzerType:@""
                                              detectorType:@""];

    MPGOAcquisitionRun *run =
        [[MPGOAcquisitionRun alloc] initWithSpectra:[_runSpectra copy]
                                    acquisitionMode:MPGOAcquisitionModeMS1DDA
                                   instrumentConfig:config];

    NSString *title = _runId ?: @"run";
    NSDictionary *msRuns = @{ title: run };

    _dataset = [[MPGOSpectralDataset alloc] initWithTitle:title
                                       isaInvestigationId:@""
                                                   msRuns:msRuns
                                                  nmrRuns:@{}
                                          identifications:@[]
                                          quantifications:@[]
                                        provenanceRecords:@[]
                                              transitions:nil];
    [_runSpectra removeAllObjects];
}

- (void)finishDocument
{
    // If <run> closed already, _dataset was built. Nothing else to do.
}

- (void)parser:(NSXMLParser *)parser parseErrorOccurred:(NSError *)parseError
{
    if (!_internalError) {
        _internalError = parseError;
    }
}

@end
