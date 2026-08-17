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
#import "Import/TTIOSpectralStreamSource.h"
#import "Run/TTIOWrittenSpectralBatch.h"
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

// Mirrors Java MzMLReader.PROGRESS_INTERVAL_SPECTRA (100).
const NSUInteger TTIOMzMLReaderProgressIntervalSpectra = 100;

@interface TTIOMzMLReader () <NSXMLParserDelegate>
@property (nonatomic, copy) TTIOProgressBlock progressBlock;
@property (nonatomic) NSUInteger progressSpectraSeen;
/** When set, finished spectra go here instead of the run buffer and
 *  no dataset is built at </run>. */
@property (nonatomic, copy) void (^spectrumSink)(TTIOMassSpectrum *spectrum);
@end

/* The producer side of +streamFromPath:runName:batchSpectra:progress:
 * parses on its own thread and pushes TTIOWrittenSpectralBatch objects
 * into a queue of at most kMzMLStreamQueueCapacity batches; the
 * consumer pops in order. */
static const NSUInteger kMzMLStreamQueueCapacity = 4;

@interface TTIOMzMLBatchQueue : NSObject
@property (nonatomic, readonly) NSCondition *cond;
@property (nonatomic, readonly) NSMutableArray<TTIOWrittenSpectralBatch *> *queue;
@property (nonatomic) BOOL done;
@property (nonatomic) BOOL cancelled;
@property (nonatomic, strong) NSError *error;
@property (nonatomic, copy) NSArray<TTIOChromatogram *> *chromatograms;
@end

@implementation TTIOMzMLBatchQueue
- (instancetype)init
{
    self = [super init];
    if (self) { _cond = [[NSCondition alloc] init]; _queue = [NSMutableArray array]; }
    return self;
}
- (BOOL)push:(TTIOWrittenSpectralBatch *)b
{
    [_cond lock];
    while (_queue.count >= kMzMLStreamQueueCapacity && !_cancelled) [_cond wait];
    BOOL ok = !_cancelled;
    if (ok) [_queue addObject:b];
    [_cond broadcast];
    [_cond unlock];
    return ok;
}
- (TTIOWrittenSpectralBatch *)pop
{
    [_cond lock];
    while (_queue.count == 0 && !_done) [_cond wait];
    TTIOWrittenSpectralBatch *b = nil;
    if (_queue.count > 0) { b = _queue[0]; [_queue removeObjectAtIndex:0]; }
    [_cond broadcast];
    [_cond unlock];
    return b;
}
- (void)finishWithError:(NSError *)error chromatograms:(NSArray<TTIOChromatogram *> *)chroms
{
    [_cond lock];
    _error = error;
    _chromatograms = chroms;
    _done = YES;
    [_cond broadcast];
    [_cond unlock];
}
- (void)cancel
{
    [_cond lock];
    _cancelled = YES;
    [_cond broadcast];
    [_cond unlock];
}
- (void)drain
{
    [_cond lock];
    [_queue removeAllObjects];
    [_cond unlock];
}
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
    double _chromTargetMz;        // parsed from userParam
    double _chromPrecursorMz;
    double _chromProductMz;
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
    NSInteger _activationDepth;
    NSInteger _isolationWindowDepth;

    // per-spectrum activation + isolation window being accumulated
    TTIOActivationMethod _activationMethod;
    double _isolationTargetMz;
    double _isolationLowerOffset;
    double _isolationUpperOffset;
    BOOL _anyActivationDetail;

    // referenceableParamGroup support: collect cvParam attributes
    // under each group id, then replay them whenever a spectrum or
    // chromatogram references the group via
    // <referenceableParamGroupRef ref="…">. Without this, ref'd
    // polarity / MS-level CVs silently disappear from the import.
    NSMutableDictionary<NSString *,
        NSMutableArray<NSDictionary<NSString *, NSString *> *> *> *_paramGroups;
    NSString *_currentGroupId;
    BOOL _inRefGroup;
}

@synthesize dataset = _dataset;
@synthesize chromatograms = _chromatograms;

#pragma mark - Class entry points

+ (TTIOSpectralDataset *)readFromFilePath:(NSString *)path error:(NSError **)error
{
    return [self readFromFilePath:path progress:nil error:error];
}

+ (TTIOSpectralDataset *)readFromFilePath:(NSString *)path
                                 progress:(TTIOProgressBlock)progress
                                    error:(NSError **)error
{
    TTIOMzMLReader *r = [self parseFilePath:path progress:progress error:error];
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
    return [self parseFilePath:path progress:nil error:error];
}

+ (instancetype)parseFilePath:(NSString *)path
                     progress:(TTIOProgressBlock)progress
                        error:(NSError **)error
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
    return [self parseData:data progress:progress error:error];
}

+ (instancetype)parseData:(NSData *)data error:(NSError **)error
{
    return [self parseData:data progress:nil error:error];
}

+ (instancetype)parseData:(NSData *)data
                 progress:(TTIOProgressBlock)progress
                    error:(NSError **)error
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
    r.progressBlock = progress ?: TTIOProgressDiscard();
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
        _paramGroups = [NSMutableDictionary dictionary];
        _currentGroupId = nil;
        _inRefGroup = NO;
        _binText = [NSMutableString string];
        _progressBlock = TTIOProgressDiscard();
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

    if (!_dataset && !_spectrumSink) {
        // <run> closed but build failed, or no run present
        if (error) {
            *error = [NSError errorWithDomain:TTIOMzMLReaderErrorDomain
                                         code:TTIOMzMLReaderErrorMissingSpectrumList
                                     userInfo:@{NSLocalizedDescriptionKey: @"No usable <run> in document"}];
        }
        return NO;
    }

    // Final fire: parse complete, spectrum count is now known.
    // (_runSpectra is cleared by finishRun once the dataset is built,
    // so use the parser-lifetime counter.)
    _progressBlock((int64_t)_progressSpectraSeen, (int64_t)_progressSpectraSeen);
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
    if ([elementName isEqualToString:@"referenceableParamGroup"]) {
        NSString *gid = attrs[@"id"] ?: @"";
        _currentGroupId = [gid copy];
        _inRefGroup = YES;
        if (!_paramGroups[gid]) {
            _paramGroups[gid] = [NSMutableArray array];
        }
        return;
    }
    if ([elementName isEqualToString:@"referenceableParamGroupRef"]) {
        NSString *ref = attrs[@"ref"] ?: @"";
        NSArray<NSDictionary *> *cvs = _paramGroups[ref];
        for (NSDictionary *cv in cvs) {
            [self handleCVParamWithAttributes:cv];
        }
        return;
    }
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
        if (_inRefGroup && _currentGroupId) {
            // Buffer cvParams for replay through any
            // <referenceableParamGroupRef ref="..."> citing this id.
            [_paramGroups[_currentGroupId] addObject:[attrs copy]];
            return;
        }
        [self handleCVParamWithAttributes:attrs];
        return;
    }

    // parse userParam target/precursor/product m/z inside a chromatogram.
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
        if ([acc isEqualToString:@"MS:1000627"]) {    // XIC
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
    if ([elementName isEqualToString:@"referenceableParamGroup"]) {
        _inRefGroup = NO;
        _currentGroupId = nil;
        return;
    }

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

    // build an IsolationWindow only when any of the three offsets was
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
    if (_spectrumSink) _spectrumSink(spec);
    else [_runSpectra addObject:spec];
    [self resetSpectrumState];

    // Per-N progress fire. Total unknown mid-parse (mzML's
    // spectrumList count attribute is unreliable). _progressSpectraSeen
    // is a parser-lifetime counter so we can fire a final (n, n) even
    // after finishRun clears _runSpectra.
    _progressSpectraSeen++;
    if ((_progressSpectraSeen % TTIOMzMLReaderProgressIntervalSpectra) == 0) {
        _progressBlock((int64_t)_progressSpectraSeen, (int64_t)-1);
    }
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


+ (NSUInteger)defaultBatchSpectra { return 4096; }

+ (TTIOSpectralStreamSource *)streamFromPath:(NSString *)path
                                     runName:(NSString *)runName
                                batchSpectra:(NSUInteger)batchSpectra
                                    progress:(TTIOProgressBlock)progress
{
    NSUInteger batchN = MAX(batchSpectra, (NSUInteger)1);
    NSArray *channelNames = @[@"intensity", @"mz"];
    __block NSArray<TTIOChromatogram *> *chromsOut = @[];
    TTIOSpectralBatchProducer producer = ^BOOL(BOOL (^emit)(TTIOWrittenSpectralBatch *, NSError **), NSError **error) {
        TTIOMzMLBatchQueue *q = [[TTIOMzMLBatchQueue alloc] init];
        NSThread *thread = [[NSThread alloc] initWithBlock:^{
            @autoreleasepool {
                TTIOMzMLReader *r = [[TTIOMzMLReader alloc] init];
                r.progressBlock = progress ?: TTIOProgressDiscard();
                NSMutableArray<TTIOMassSpectrum *> *pending = [NSMutableArray arrayWithCapacity:batchN];
                __block BOOL cancelled = NO;
                r.spectrumSink = ^(TTIOMassSpectrum *sp) {
                    if (cancelled) return;
                    [pending addObject:sp];
                    if (pending.count >= batchN) {
                        TTIOWrittenSpectralBatch *b = [TTIOWrittenSpectralBatch batchWithSpectra:pending
                                                                                    channelNames:channelNames];
                        [pending removeAllObjects];
                        if (![q push:b]) cancelled = YES;
                    }
                };
                NSError *err = nil;
                NSData *data = [NSData dataWithContentsOfFile:path];
                BOOL ok = NO;
                if (!data) {
                    err = [NSError errorWithDomain:TTIOMzMLReaderErrorDomain
                                              code:TTIOMzMLReaderErrorParseFailed
                                          userInfo:@{NSLocalizedDescriptionKey:
                                              [NSString stringWithFormat:@"Cannot read %@", path]}];
                } else {
                    ok = [r parseData:data error:&err];
                }
                if (ok && !cancelled && pending.count > 0) {
                    TTIOWrittenSpectralBatch *b = [TTIOWrittenSpectralBatch batchWithSpectra:pending
                                                                                channelNames:channelNames];
                    [pending removeAllObjects];
                    if (![q push:b]) cancelled = YES;
                }
                [q finishWithError:(ok ? nil : err) chromatograms:r.chromatograms];
            }
        }];
        thread.name = @"ttio-mzml-stream";
        [thread start];
        BOOL ok = YES;
        TTIOWrittenSpectralBatch *b;
        while ((b = [q pop]) != nil) {
            NSError *e = nil;
            if (!emit(b, &e)) {
                if (error && e) *error = e;
                ok = NO;
                [q cancel];
                break;
            }
        }
        while (![thread isFinished]) [NSThread sleepForTimeInterval:0.001];
        [q drain];
        if (ok && q.error) {
            if (error) *error = q.error;
            ok = NO;
        }
        chromsOut = q.chromatograms ?: @[];
        return ok;
    };
    return [[TTIOSpectralStreamSource alloc] initWithName:runName
                                                  batches:producer
                                          acquisitionMode:TTIOAcquisitionModeMS1DDA
                                         instrumentConfig:nil
                                             batchSpectra:batchN
                                       chromatogramsAfter:^NSArray<TTIOChromatogram *> *{ return chromsOut; }];
}

@end
