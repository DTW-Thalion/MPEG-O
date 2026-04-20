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

### Layer 3b — Transport + Per-AU Encryption (v0.10)

Added in v0.10.0 across all three languages. Names shown are the
ObjC surface; Python uses snake_case in `mpeg_o.transport` /
`mpeg_o.encryption_per_au`, Java uses PascalCase in
`com.dtwthalion.mpgo.transport` / `.protection`.

**Transport codec + networking** (`MPGOTransport*`; see
`docs/transport-spec.md`):

```
MPGOTransportPacketHeader  (24-byte wire header)
MPGOTransportPacketRecord  (header + payload pair)
MPGOTransportWriter        (.mots emission)
MPGOTransportReader        (.mots parsing)
MPGOTransportClient        (WebSocket push)
MPGOTransportServer        (WebSocket accept + route)
MPGOAccessUnit             (single-spectrum transport-level record)
MPGOChannelData            (per-channel payload inside an AU)
MPGOProtectionMetadata     (cipher_suite + wrapped_dek + signature_algorithm + public_key)
MPGOAcquisitionSimulator   (replay fixtures at wall-clock pace)
MPGOAUFilter               (selective access predicate)
```

**Per-AU encryption** (`MPGOPerAU*` /
`com.dtwthalion.mpgo.protection.PerAU*` /
`mpeg_o.encryption_per_au`; see
`docs/transport-encryption-design.md`):

```
MPGOChannelSegment       (offset, length, iv, tag, ciphertext)
MPGOHeaderSegment        (iv, tag, ciphertext[36])
MPGOAUHeaderPlaintext    (acq_mode, ms_level, polarity, rt,
                           precursor_mz, precursor_charge,
                           ion_mobility, base_peak_intensity)
MPGOPerAUEncryption      (AAD helpers + encrypt/decrypt with AAD)
MPGOPerAUFile            (file-level orchestrator via StorageProvider)
MPGOEncryptedTransport   (writer + reader for encrypted .mots streams)
```

All per-AU APIs are **class methods** (no instance state) on the
manager classes. Segment / plaintext / metadata classes are value
objects.

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
    // v0.10: AccessUnit-level encryption is realised via
    // opt_per_au_encryption + MPGOPerAUFile (see
    // docs/transport-encryption-design.md) rather than a new enum
    // case. The enum is kept for the v0.4 channel-granular mode that
    // remains valid.
};

// v0.10 compound field kind catalog (docs/format-spec.md §6):
typedef NS_ENUM(NSUInteger, MPGOCompoundFieldKind) {
    MPGOCompoundFieldKindUInt32 = 0,
    MPGOCompoundFieldKindInt64,
    MPGOCompoundFieldKindFloat64,
    MPGOCompoundFieldKindVLString,
    MPGOCompoundFieldKindVLBytes   // added v0.10 for <channel>_segments
};

// v0.10 transport packet wire types (docs/transport-spec.md §3.2):
typedef NS_ENUM(uint8_t, MPGOTransportPacketType) {
    MPGOTransportPacketStreamHeader        = 0x01,
    MPGOTransportPacketDatasetHeader       = 0x02,
    MPGOTransportPacketAccessUnit          = 0x03,
    MPGOTransportPacketProtectionMetadata  = 0x04,
    MPGOTransportPacketAnnotation          = 0x05,
    MPGOTransportPacketProvenance          = 0x06,
    MPGOTransportPacketChromatogram        = 0x07,
    MPGOTransportPacketEndOfDataset        = 0x08,
    MPGOTransportPacketEndOfStream         = 0xFF
};
```
