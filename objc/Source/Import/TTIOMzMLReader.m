/*
 * TTIOMzMLReader.m
 * TTI-O Objective-C Implementation
 *
 * Class:         TTIOMzMLReader
 * Inherits From: NSObject
 * Conforms To:   NSObject (NSObject)
 * Declared In:   Import/TTIOMzMLReader.h
 *
 * SAX-based mzML 1.1 parser. Produces a TTIOSpectralDataset with one
 * TTIOAcquisitionRun per <run> element; chromatograms appear as
 * extra TTIOChromatogram-tagged spectra. Binary payloads are
 * decoded via TTIOBase64 and typed via TTIOCVTermMapper.
 *
 * Licensed under the Apache License, Version 2.0.
 * See LICENSE-IMPORT-EXPORT in the repository root.
 *
 * SPDX-License-Identifier: Apache-2.0
 */

#import "TTIOMzMLReader.h"
#import "TTIOBase64.h"
#import "TTIOCVTermMapper.h"

#import "Core/TTIOSignalArray.h"
#import "ValueClasses/TTIOEncodingSpec.h"
#import "ValueClasses/TTIOAxisDescriptor.h"
#import "ValueClasses/TTIOValueRange.h"
#import "ValueClasses/TTIOEnums.h"
#import "ValueClasses/TTIOIsolationWindow.h"
#import "Spectra/TTIOSpectrum.h"
#import "Spectra/TTIOMassSpectrum.h"
#import "Spectra/TTIOChromatogram.h"
#import "Run/TTIOAcquisitionRun.h"
#import "Run/TTIOInstrumentConfig.h"
#import "Dataset/TTIOSpectralDataset.h"

NSString *const TTIOMzMLReaderErrorDomain = @"TTIOMzMLReaderErrorDomain";

@interface TTIOMzMLReader () <NSXMLParserDelegate>
@end

@implementation TTIOMzMLReader
{
    // Output
    TTIOSpectralDataset *_dataset;
    NSMutableArray<TTIOChromatogram *> *_chromatograms;

    // Parse state
    NSError *_internalError;
    NSString *_runId;
    NSMutableArray<TTIOMassSpectrum *> *_runSpectra;

    // Current spectrum
    BOOL _inSpectrum;
    NSUInteger _specIndex;
    NSUInteger _specDefaultLen;
    NSUInteger _msLevel;
    TTIOPolarity _polarity;
    double _scanTime;
    double _precursorMz;
    NSUInteger _precursorCharge;
    double _scanWinLow;
    double _scanWinHigh;
    BOOL _hasScanWin;
    NSMutableDictionary<NSString *, TTIOSignalArray *> *_specArrays;

    // Current chromatogram
    BOOL _inChromatogram;
    NSUInteger _chromDefaultLen;
    TTIOChromatogramType _chromType;
    double _chromTargetMz;        // M24: parsed from userParam
    double _chromPrecursorMz;     // M24
    double _chromProductMz;       // M24
    NSMutableDictionary<NSString *, TTIOSignalArray *> *_chromArrays;

    // Current binaryDataArray
    BOOL _inBinaryDataArray;
    TTIOPrecision _binPrecision;
    TTIOCompression _binCompression;
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
    TTIOActivationMethod _activationMethod;
    double _isolationTargetMz;
    double _isolationLowerOffset;
    double _isolationUpperOffset;
    BOOL _anyActivationDetail;
}

@synthesize dataset = _dataset;
@synthesize chromatograms = _chromatograms;

#pragma mark - Class entry points

+ (TTIOSpectralDataset *)readFromFilePath:(NSString *)path error:(NSError **)error
{
    TTIOMzMLReader *r = [self parseFilePath:path error:error];
    return r.dataset;
}

+ (TTIOSpectralDataset *)readFromURL:(NSURL *)url error:(NSError **)error
{
    if (!url.isFileURL) {
        if (error) {
            *error = [NSError errorWithDomain:TTIOMzMLReaderErrorDomain
                                         code:TTIOMzMLReaderErrorParseFailed
                                     userInfo:@{NSLocalizedDescriptionKey: @"Only file URLs are supported"}];
        }
        return nil;
    }
    return [self readFromFilePath:url.path error:error];
}

+ (TTIOSpectralDataset *)readFromData:(NSData *)data error:(NSError **)error
{
    TTIOMzMLReader *r = [self parseData:data error:error];
    return r.dataset;
}

+ (instancetype)parseFilePath:(NSString *)path error:(NSError **)error
{
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data) {
        if (error) {
            *error = [NSError errorWithDomain:TTIOMzMLReaderErrorDomain
                                         code:TTIOMzMLReaderErrorParseFailed
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
            *error = [NSError errorWithDomain:TTIOMzMLReaderErrorDomain
                                         code:TTIOMzMLReaderErrorParseFailed
                                     userInfo:@{NSLocalizedDescriptionKey: @"nil input data"}];
        }
        return nil;
    }
    TTIOMzMLReader *r = [[self alloc] init];
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
            e = [NSError errorWithDomain:TTIOMzMLReaderErrorDomain
                                    code:TTIOMzMLReaderErrorParseFailed
                                userInfo:@{NSLocalizedDescriptionKey: @"Unknown parse failure"}];
        }
        if (error) *error = e;
        return NO;
    }

    if (!_dataset) {
        // <run> closed but build failed, or no run present
        if (error) {
            *error = [NSError errorWithDomain:TTIOMzMLReaderErrorDomain
                                         code:TTIOMzMLReaderErrorMissingSpectrumList
                                     userInfo:@{NSLocalizedDescriptionKey: @"No usable <run> in document"}];
        }
        return NO;
    }
    return YES;
}

#pragma mark - Helpers

- (void)failWithCode:(TTIOMzMLReaderErrorCode)code message:(NSString *)msg
{
    _internalError = [NSError errorWithDomain:TTIOMzMLReaderErrorDomain
                                         code:code
                                     userInfo:@{NSLocalizedDescriptionKey: msg ?: @""}];
}

- (void)resetSpectrumState
{
    _inSpectrum = NO;
    _specIndex = 0;
    _specDefaultLen = 0;
    _msLevel = 1;
    _polarity = TTIOPolarityUnknown;
    _scanTime = 0.0;
    _precursorMz = 0.0;
    _precursorCharge = 0;
    _scanWinLow = 0.0;
    _scanWinHigh = 0.0;
    _hasScanWin = NO;
    // M74
    _activationMethod = TTIOActivationMethodNone;
    _isolationTargetMz = 0.0;
    _isolationLowerOffset = 0.0;
    _isolationUpperOffset = 0.0;
    [_specArrays removeAllObjects];
}

- (void)resetChromatogramState
{
    _inChromatogram = NO;
    _chromDefaultLen = 0;
    _chromType = TTIOChromatogramTypeTIC;
    _chromTargetMz    = 0.0;
    _chromPrecursorMz = 0.0;
    _chromProductMz   = 0.0;
    [_chromArrays removeAllObjects];
}

- (void)resetBinaryState
{
    _inBinaryDataArray = NO;
    _binPrecision = TTIOPrecisionFloat64;
    _binCompression = TTIOCompressionNone;
    _binArrayName = nil;
}

- (TTIOSignalArray *)makeSignalArrayFromDecodedData:(NSData *)decoded
                                             length:(NSUInteger)expectedLen
                                             axisName:(NSString *)axisName
                                             axisUnit:(NSString *)axisUnit
{
    TTIOEncodingSpec *spec =
        [TTIOEncodingSpec specWithPrecision:_binPrecision
                       compressionAlgorithm:TTIOCompressionNone
                                  byteOrder:TTIOByteOrderLittleEndian];

    NSUInteger elemSize = [spec elementSize];
    if (elemSize == 0) return nil;

    NSUInteger actualLen = decoded.length / elemSize;
    if (expectedLen > 0 && actualLen != expectedLen) {
        [self failWithCode:TTIOMzMLReaderErrorArrayLengthMismatch
                   message:[NSString stringWithFormat:
                            @"binaryDataArray length mismatch: expected %lu, got %lu",
                            (unsigned long)expectedLen, (unsigned long)actualLen]];
        return nil;
    }

    TTIOValueRange *range = [TTIOValueRange rangeWithMinimum:0 maximum:0];
    TTIOAxisDescriptor *axis =
        [TTIOAxisDescriptor descriptorWithName:axisName
                                          unit:axisUnit
                                    valueRange:range
                                  samplingMode:TTIOSamplingModeNonUniform];

    return [[TTIOSignalArray alloc] initWithBuffer:decoded
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
        NSString *arrName = [TTIOCVTermMapper signalArrayNameForAccession:acc];
        if (arrName) { _binArrayName = arrName; return; }

        if ([acc isEqualToString:@"MS:1000521"] ||
            [acc isEqualToString:@"MS:1000523"] ||
            [acc isEqualToString:@"MS:1000519"] ||
            [acc isEqualToString:@"MS:1000522"]) {
            _binPrecision = [TTIOCVTermMapper precisionForAccession:acc];
            return;
        }
        if ([acc isEqualToString:@"MS:1000574"] ||
            [acc isEqualToString:@"MS:1000576"]) {
            _binCompression = [TTIOCVTermMapper compressionForAccession:acc];
            return;
        }
        return;
    }

    // 2a. (M74) Inside <precursor><activation>: dissociation method cvParams.
    // Gate on _precursorDepth so <product> siblings (SRM) are ignored.
    if (_activationDepth > 0 && _precursorDepth > 0 && _inSpectrum) {
        if ([TTIOCVTermMapper isActivationMethodAccession:acc]) {
            _activationMethod = [TTIOCVTermMapper activationMethodForAccession:acc];
            _anyActivationDetail = YES;
        }
        return;
    }

    // 2b. (M74) Inside <precursor><isolationWindow>: target m/z + offsets.
    if (_isolationWindowDepth > 0 && _precursorDepth > 0 && _inSpectrum) {
        if ([TTIOCVTermMapper isIsolationWindowTargetMzAccession:acc]) {
            _isolationTargetMz = [value doubleValue];
            _anyActivationDetail = YES;
        } else if ([TTIOCVTermMapper isIsolationWindowLowerOffsetAccession:acc]) {
            _isolationLowerOffset = [value doubleValue];
            _anyActivationDetail = YES;
        } else if ([TTIOCVTermMapper isIsolationWindowUpperOffsetAccession:acc]) {
            _isolationUpperOffset = [value doubleValue];
            _anyActivationDetail = YES;
        }
        return;
    }

    // 2. Inside selectedIon: precursor m/z and charge
    if (_selectedIonDepth > 0 && _inSpectrum) {
        if ([TTIOCVTermMapper isSelectedIonMzAccession:acc]) {
            _precursorMz = [value doubleValue];
            return;
        }
        if ([TTIOCVTermMapper isChargeStateAccession:acc]) {
            _precursorCharge = (NSUInteger)[value integerValue];
            return;
        }
        return;
    }

    // 3. Inside scanWindow: lower/upper limits
    if (_scanWindowDepth > 0 && _inSpectrum) {
        if ([TTIOCVTermMapper isScanWindowLowerAccession:acc]) {
            _scanWinLow = [value doubleValue];
            _hasScanWin = YES;
            return;
        }
        if ([TTIOCVTermMapper isScanWindowUpperAccession:acc]) {
            _scanWinHigh = [value doubleValue];
            _hasScanWin = YES;
            return;
        }
        return;
    }

    // 4. Inside scan (not scanWindow): scan start time
    if (_scanDepth > 0 && _inSpectrum) {
        if ([TTIOCVTermMapper isScanStartTimeAccession:acc]) {
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
        if ([TTIOCVTermMapper isMSLevelAccession:acc]) {
            _msLevel = (NSUInteger)[value integerValue];
            return;
        }
        if ([TTIOCVTermMapper isPositivePolarityAccession:acc]) {
            _polarity = TTIOPolarityPositive;
            return;
        }
        if ([TTIOCVTermMapper isNegativePolarityAccession:acc]) {
            _polarity = TTIOPolarityNegative;
            return;
        }
        // Scan start time can also appear directly inside <spectrum>
        if ([TTIOCVTermMapper isScanStartTimeAccession:acc]) {
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
        if ([TTIOCVTermMapper isTotalIonChromatogramAccession:acc]) {
            _chromType = TTIOChromatogramTypeTIC;
            return;
        }
        if ([acc isEqualToString:@"MS:1000627"]) {    // M24: XIC
            _chromType = TTIOChromatogramTypeXIC;
            return;
        }
        if ([TTIOCVTermMapper isSelectedReactionMonitoringAccession:acc]) {
            _chromType = TTIOChromatogramTypeSRM;
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

    BOOL needInflate = (_binCompression == TTIOCompressionZlib);
    NSData *decoded = [TTIOBase64 decodeString:_binText zlibInflate:needInflate];
    if (!decoded) {
        [self failWithCode:TTIOMzMLReaderErrorBase64Failed
                   message:@"Failed to decode binaryDataArray content"];
        return;
    }

    NSUInteger expected = _inSpectrum ? _specDefaultLen : _chromDefaultLen;
    NSString *name = _binArrayName ?: (_inChromatogram ? @"intensity" : @"intensity");
    NSString *unit = [self axisUnitForName:name];

    TTIOSignalArray *arr =
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

    TTIOSignalArray *mz  = _specArrays[@"mz"];
    TTIOSignalArray *ints = _specArrays[@"intensity"];

    if (!mz || !ints) {
        // Spectrum with no binary content — skip silently.
        [self resetSpectrumState];
        return;
    }

    TTIOValueRange *win = nil;
    if (_hasScanWin) {
        win = [TTIOValueRange rangeWithMinimum:_scanWinLow maximum:_scanWinHigh];
    }

    // M74: build an IsolationWindow only when any of the three offsets was
    // reported. All-zero means "no window" and we pass nil to match Python/Java.
    TTIOIsolationWindow *iso = nil;
    if (_isolationTargetMz != 0.0 ||
        _isolationLowerOffset != 0.0 ||
        _isolationUpperOffset != 0.0) {
        iso = [TTIOIsolationWindow windowWithTargetMz:_isolationTargetMz
                                          lowerOffset:_isolationLowerOffset
                                          upperOffset:_isolationUpperOffset];
    }

    NSError *err = nil;
    TTIOMassSpectrum *spec =
        [[TTIOMassSpectrum alloc] initWithMzArray:mz
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
        [self failWithCode:TTIOMzMLReaderErrorArrayLengthMismatch
                   message:err.localizedDescription ?: @"TTIOMassSpectrum init failed"];
        return;
    }
    [_runSpectra addObject:spec];
    [self resetSpectrumState];
}

- (void)finishChromatogram
{
    if (_internalError) { _inChromatogram = NO; return; }

    TTIOSignalArray *time = _chromArrays[@"time"];
    TTIOSignalArray *ints = _chromArrays[@"intensity"];

    if (time && ints) {
        NSError *err = nil;
        TTIOChromatogram *c =
            [[TTIOChromatogram alloc] initWithTimeArray:time
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

    TTIOInstrumentConfig *config =
        [[TTIOInstrumentConfig alloc] initWithManufacturer:@""
                                                     model:@""
                                              serialNumber:@""
                                                sourceType:@""
                                              analyzerType:@""
                                              detectorType:@""];

    TTIOAcquisitionRun *run =
        [[TTIOAcquisitionRun alloc] initWithSpectra:[_runSpectra copy]
                                    acquisitionMode:TTIOAcquisitionModeMS1DDA
                                   instrumentConfig:config];

    NSString *title = _runId ?: @"run";
    NSDictionary *msRuns = @{ title: run };

    _dataset = [[TTIOSpectralDataset alloc] initWithTitle:title
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
