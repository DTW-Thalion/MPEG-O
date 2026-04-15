# MPEG-O Class Hierarchy

UML-style description of the three-layer class hierarchy. See [`ARCHITECTURE.md`](../ARCHITECTURE.md) for protocol summaries and HDF5 mapping.

---

## Layer 1 — Protocols

```
<<protocol>> MPGOIndexable
  + objectAtIndex:(NSUInteger) -> id
  + objectForKey:(id) -> id
  + objectsInRange:(NSRange) -> NSArray
  + count -> NSUInteger

<<protocol>> MPGOStreamable
  + nextObject -> id
  + seekToPosition:(NSUInteger) -> BOOL
  + currentPosition -> NSUInteger
  + hasMore -> BOOL
  + reset -> void

<<protocol>> MPGOCVAnnotatable
  + addCVParam:(MPGOCVParam*)
  + removeCVParam:(MPGOCVParam*)
  + cvParamsForAccession:(NSString*) -> NSArray<MPGOCVParam*>
  + cvParamsForOntologyRef:(NSString*) -> NSArray<MPGOCVParam*>
  + allCVParams -> NSArray<MPGOCVParam*>
  + hasCVParamWithAccession:(NSString*) -> BOOL

<<protocol>> MPGOProvenanceable
  + addProcessingStep:(MPGOProvenanceRecord*)
  + provenanceChain -> NSArray<MPGOProvenanceRecord*>
  + inputEntities -> NSArray<NSString*>
  + outputEntities -> NSArray<NSString*>

<<protocol>> MPGOEncryptable
  + encryptWithKey:(NSData*) level:(MPGOEncryptionLevel) error:(NSError**) -> BOOL
  + decryptWithKey:(NSData*) error:(NSError**) -> BOOL
  + accessPolicy -> MPGOAccessPolicy*
  + setAccessPolicy:(MPGOAccessPolicy*)
```

---

## Layer 2 — Abstract Base Classes

```
NSObject
│
├── MPGOCVParam <NSCoding, NSCopying>
│     - ontologyRef : NSString
│     - accession   : NSString
│     - name        : NSString
│     - value       : id (nullable)
│     - unit        : NSString (nullable)
│
├── MPGOAxisDescriptor <NSCoding, NSCopying>
│     - name         : NSString
│     - unit         : NSString
│     - valueRange   : MPGOValueRange
│     - samplingMode : MPGOSamplingMode
│
├── MPGOEncodingSpec <NSCoding, NSCopying>
│     - precision            : MPGOPrecision
│     - compressionAlgorithm : MPGOCompression
│     - byteOrder            : MPGOByteOrder
│
├── MPGOValueRange <NSCoding, NSCopying>
│     - minimum : double
│     - maximum : double
│
├── MPGOSignalArray <MPGOCVAnnotatable>
│     - buffer         : NSData
│     - encodingSpec   : MPGOEncodingSpec
│     - axisDescriptor : MPGOAxisDescriptor
│     - cvAnnotations  : NSArray<MPGOCVParam*>
│     + floatValueAtIndex:  / doubleValueAtIndex: / int32ValueAtIndex:
│     + writeToHDF5Group:withName:error:
│     + readFromHDF5Group:withName:error:
│
├── MPGOSpectrum <MPGOCVAnnotatable, MPGOIndexable>
│     - signalArrays   : NSDictionary<NSString*, MPGOSignalArray*>
│     - coordinateAxes : NSArray<MPGOAxisDescriptor*>
│     - indexPosition  : NSUInteger
│     - scanTime       : double
│     - precursorInfo  : NSDictionary (nullable)
│
├── MPGOSpectrumIndex
│     - offsets : NSData (uint64[])
│     - lengths : NSData (uint32[])
│     - headers : NSArray<NSDictionary*>  (in-memory form of compound dataset)
│     + appendSpectrum:withOffset:length:header:
│     + lookupIndex:(NSUInteger) -> NSDictionary
│
├── MPGOInstrumentConfig <NSCoding, NSCopying, MPGOCVAnnotatable>
│     - manufacturer  : NSString
│     - model         : NSString
│     - serialNumber  : NSString
│     - sourceType    : NSString
│     - analyzerType  : NSString
│     - detectorType  : NSString
│
├── MPGOAcquisitionRun <MPGOIndexable, MPGOStreamable, MPGOProvenanceable, MPGOEncryptable>
│     - spectra          : NSArray<MPGOSpectrum*>
│     - chromatograms    : NSArray<MPGOChromatogram*>
│     - instrumentConfig : MPGOInstrumentConfig
│     - sourceFiles      : NSArray<NSString*>
│     - provenance       : NSMutableArray<MPGOProvenanceRecord*>
│     - spectrumIndex    : MPGOSpectrumIndex
│
├── MPGOSpectralDataset <MPGOIndexable, MPGOEncryptable, MPGOProvenanceable>
│     - runs             : NSArray<MPGOAcquisitionRun*>
│     - identifications  : NSArray<MPGOIdentification*>
│     - quantifications  : NSArray<MPGOQuantification*>
│     - studyMetadata    : NSDictionary
│     - hdf5File         : MPGOHDF5File  (nullable — memory-only datasets)
│
├── MPGOIdentification <MPGOCVAnnotatable>
│     - spectrumRef     : NSUInteger
│     - chemicalEntity  : NSString
│     - confidenceScore : double
│     - evidenceChain   : NSArray
│
├── MPGOQuantification <MPGOCVAnnotatable>
│     - abundanceValue        : double
│     - sampleRef              : NSString
│     - normalizationMetadata  : NSDictionary
│
└── MPGOProvenanceRecord <NSCoding, NSCopying>
      - inputEntities  : NSArray<NSString*>
      - software       : NSString
      - parameters     : NSDictionary
      - outputEntities : NSArray<NSString*>
      - timestamp      : NSDate
```

---

## Layer 3 — Concrete Domain Classes

```
MPGOSpectrum
├── MPGOMassSpectrum
│     - mzArray          : MPGOSignalArray  (mandatory, keyed "mz")
│     - intensityArray   : MPGOSignalArray  (mandatory, keyed "intensity")
│     - ionMobilityArray : MPGOSignalArray  (nullable, keyed "ion_mobility")
│     - msLevel          : NSUInteger
│     - polarity         : MPGOPolarity
│     - scanWindow       : MPGOValueRange (nullable)
│
├── MPGONMRSpectrum
│     - chemicalShiftArray : MPGOSignalArray  (keyed "chemical_shift")
│     - intensityArray     : MPGOSignalArray  (keyed "intensity")
│     - nucleusType        : NSString         (e.g. "1H", "13C", "15N")
│     - spectrometerFreq   : double           (MHz)
│
└── MPGONMR2DSpectrum
      - intensityMatrix    : MPGOSignalArray  (2D, keyed "intensity_matrix")
      - f1AxisDescriptor   : MPGOAxisDescriptor
      - f2AxisDescriptor   : MPGOAxisDescriptor
      - experimentType     : NSString         (e.g. "COSY", "HSQC", "NOESY")

MPGOSignalArray
└── MPGOFreeInductionDecay
      - realComponent    : NSData
      - imaginaryComponent : NSData
      - dwellTime        : double
      - numberOfScans    : NSUInteger
      - receiverGain     : double

NSObject
├── MPGOChromatogram <MPGOCVAnnotatable>
│     - timeArray        : MPGOSignalArray
│     - intensityArray   : MPGOSignalArray
│     - chromatogramType : MPGOChromatogramType  (TIC / XIC / SRM)
│
└── MPGOTransitionList
      - transitions : NSArray<MPGOTransition*>

MPGOSpectralDataset
└── MPGOMSImage
      - spatialDimensions : CGSize (or {width,height} struct)
      - pixelSize         : CGSize
      - scanPattern       : NSString
      - gridSpectra       : NSArray<NSArray<MPGOMassSpectrum*>*>
```

---

## Enumerations

```objc
typedef NS_ENUM(NSUInteger, MPGOSamplingMode) {
    MPGOSamplingModeUniform = 0,
    MPGOSamplingModeNonUniform
};

typedef NS_ENUM(NSUInteger, MPGOPrecision) {
    MPGOPrecisionFloat32 = 0,
    MPGOPrecisionFloat64,
    MPGOPrecisionInt32,
    MPGOPrecisionInt64,
    MPGOPrecisionUInt32,
    MPGOPrecisionComplex128
};

typedef NS_ENUM(NSUInteger, MPGOCompression) {
    MPGOCompressionNone = 0,
    MPGOCompressionZlib,
    MPGOCompressionLZ4
};

typedef NS_ENUM(NSUInteger, MPGOByteOrder) {
    MPGOByteOrderLittleEndian = 0,
    MPGOByteOrderBigEndian
};

typedef NS_ENUM(NSInteger, MPGOPolarity) {
    MPGOPolarityUnknown  =  0,
    MPGOPolarityPositive = +1,
    MPGOPolarityNegative = -1
};

typedef NS_ENUM(NSUInteger, MPGOChromatogramType) {
    MPGOChromatogramTypeTIC = 0,
    MPGOChromatogramTypeXIC,
    MPGOChromatogramTypeSRM
};

typedef NS_ENUM(NSUInteger, MPGOAcquisitionMode) {
    MPGOAcquisitionModeMS1DDA = 0,
    MPGOAcquisitionModeMS2DDA,
    MPGOAcquisitionModeDIA,
    MPGOAcquisitionModeSRM,
    MPGOAcquisitionMode1DNMR,
    MPGOAcquisitionMode2DNMR,
    MPGOAcquisitionModeImaging
};

typedef NS_ENUM(NSUInteger, MPGOEncryptionLevel) {
    MPGOEncryptionLevelNone = 0,
    MPGOEncryptionLevelDatasetGroup,
    MPGOEncryptionLevelDataset,
    MPGOEncryptionLevelDescriptorStream,
    MPGOEncryptionLevelAccessUnit
};
```
