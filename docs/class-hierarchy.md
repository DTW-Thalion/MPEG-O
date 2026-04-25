# TTI-O Class Hierarchy

UML-style description of the three-layer class hierarchy. See [`ARCHITECTURE.md`](../ARCHITECTURE.md) for protocol summaries and HDF5 mapping.

---

## Layer 1 — Protocols

```
<<protocol>> TTIOIndexable
  + objectAtIndex:(NSUInteger) -> id
  + objectForKey:(id) -> id
  + objectsInRange:(NSRange) -> NSArray
  + count -> NSUInteger

<<protocol>> TTIOStreamable
  + nextObject -> id
  + seekToPosition:(NSUInteger) -> BOOL
  + currentPosition -> NSUInteger
  + hasMore -> BOOL
  + reset -> void

<<protocol>> TTIOCVAnnotatable
  + addCVParam:(TTIOCVParam*)
  + removeCVParam:(TTIOCVParam*)
  + cvParamsForAccession:(NSString*) -> NSArray<TTIOCVParam*>
  + cvParamsForOntologyRef:(NSString*) -> NSArray<TTIOCVParam*>
  + allCVParams -> NSArray<TTIOCVParam*>
  + hasCVParamWithAccession:(NSString*) -> BOOL

<<protocol>> TTIOProvenanceable
  + addProcessingStep:(TTIOProvenanceRecord*)
  + provenanceChain -> NSArray<TTIOProvenanceRecord*>
  + inputEntities -> NSArray<NSString*>
  + outputEntities -> NSArray<NSString*>

<<protocol>> TTIOEncryptable
  + encryptWithKey:(NSData*) level:(TTIOEncryptionLevel) error:(NSError**) -> BOOL
  + decryptWithKey:(NSData*) error:(NSError**) -> BOOL
  + accessPolicy -> TTIOAccessPolicy*
  + setAccessPolicy:(TTIOAccessPolicy*)
```

---

## Layer 2 — Abstract Base Classes

```
NSObject
│
├── TTIOCVParam <NSCoding, NSCopying>
│     - ontologyRef : NSString
│     - accession   : NSString
│     - name        : NSString
│     - value       : id (nullable)
│     - unit        : NSString (nullable)
│
├── TTIOAxisDescriptor <NSCoding, NSCopying>
│     - name         : NSString
│     - unit         : NSString
│     - valueRange   : TTIOValueRange
│     - samplingMode : TTIOSamplingMode
│
├── TTIOEncodingSpec <NSCoding, NSCopying>
│     - precision            : TTIOPrecision
│     - compressionAlgorithm : TTIOCompression
│     - byteOrder            : TTIOByteOrder
│
├── TTIOValueRange <NSCoding, NSCopying>
│     - minimum : double
│     - maximum : double
│
├── TTIOSignalArray <TTIOCVAnnotatable>
│     - buffer         : NSData
│     - encodingSpec   : TTIOEncodingSpec
│     - axisDescriptor : TTIOAxisDescriptor
│     - cvAnnotations  : NSArray<TTIOCVParam*>
│     + floatValueAtIndex:  / doubleValueAtIndex: / int32ValueAtIndex:
│     + writeToHDF5Group:withName:error:
│     + readFromHDF5Group:withName:error:
│
├── TTIOSpectrum <TTIOCVAnnotatable, TTIOIndexable>
│     - signalArrays   : NSDictionary<NSString*, TTIOSignalArray*>
│     - coordinateAxes : NSArray<TTIOAxisDescriptor*>
│     - indexPosition  : NSUInteger
│     - scanTime       : double
│     - precursorInfo  : NSDictionary (nullable)
│
├── TTIOSpectrumIndex
│     - offsets : NSData (uint64[])
│     - lengths : NSData (uint32[])
│     - headers : NSArray<NSDictionary*>  (in-memory form of compound dataset)
│     + appendSpectrum:withOffset:length:header:
│     + lookupIndex:(NSUInteger) -> NSDictionary
│
├── TTIOInstrumentConfig <NSCoding, NSCopying, TTIOCVAnnotatable>
│     - manufacturer  : NSString
│     - model         : NSString
│     - serialNumber  : NSString
│     - sourceType    : NSString
│     - analyzerType  : NSString
│     - detectorType  : NSString
│
├── TTIOAcquisitionRun <TTIOIndexable, TTIOStreamable, TTIOProvenanceable, TTIOEncryptable>
│     - spectra          : NSArray<TTIOSpectrum*>
│     - chromatograms    : NSArray<TTIOChromatogram*>
│     - instrumentConfig : TTIOInstrumentConfig
│     - sourceFiles      : NSArray<NSString*>
│     - provenance       : NSMutableArray<TTIOProvenanceRecord*>
│     - spectrumIndex    : TTIOSpectrumIndex
│
├── TTIOSpectralDataset <TTIOIndexable, TTIOEncryptable, TTIOProvenanceable>
│     - runs             : NSArray<TTIOAcquisitionRun*>
│     - identifications  : NSArray<TTIOIdentification*>
│     - quantifications  : NSArray<TTIOQuantification*>
│     - studyMetadata    : NSDictionary
│     - hdf5File         : TTIOHDF5File  (nullable — memory-only datasets)
│
├── TTIOIdentification <TTIOCVAnnotatable>
│     - spectrumRef     : NSUInteger
│     - chemicalEntity  : NSString
│     - confidenceScore : double
│     - evidenceChain   : NSArray
│
├── TTIOQuantification <TTIOCVAnnotatable>
│     - abundanceValue        : double
│     - sampleRef              : NSString
│     - normalizationMetadata  : NSDictionary
│
└── TTIOProvenanceRecord <NSCoding, NSCopying>
      - inputEntities  : NSArray<NSString*>
      - software       : NSString
      - parameters     : NSDictionary
      - outputEntities : NSArray<NSString*>
      - timestamp      : NSDate
```

---

## Layer 3 — Concrete Domain Classes

```
TTIOSpectrum
├── TTIOMassSpectrum
│     - mzArray          : TTIOSignalArray  (mandatory, keyed "mz")
│     - intensityArray   : TTIOSignalArray  (mandatory, keyed "intensity")
│     - ionMobilityArray : TTIOSignalArray  (nullable, keyed "ion_mobility")
│     - msLevel          : NSUInteger
│     - polarity         : TTIOPolarity
│     - scanWindow       : TTIOValueRange (nullable)
│
├── TTIONMRSpectrum
│     - chemicalShiftArray : TTIOSignalArray  (keyed "chemical_shift")
│     - intensityArray     : TTIOSignalArray  (keyed "intensity")
│     - nucleusType        : NSString         (e.g. "1H", "13C", "15N")
│     - spectrometerFreq   : double           (MHz)
│
├── TTIONMR2DSpectrum
│     - intensityMatrix    : TTIOSignalArray  (2D, keyed "intensity_matrix")
│     - f1AxisDescriptor   : TTIOAxisDescriptor
│     - f2AxisDescriptor   : TTIOAxisDescriptor
│     - experimentType     : NSString         (e.g. "COSY", "HSQC", "NOESY")
│
├── TTIORamanSpectrum                                    ← v0.11 (M73)
│     - wavenumberArray         : TTIOSignalArray  (keyed "wavenumber")
│     - intensityArray          : TTIOSignalArray  (keyed "intensity")
│     - excitationWavelengthNm  : double
│     - laserPowerMw            : double
│     - integrationTimeSec      : double
│
├── TTIOIRSpectrum                                       ← v0.11 (M73)
│     - wavenumberArray  : TTIOSignalArray  (keyed "wavenumber")
│     - intensityArray   : TTIOSignalArray  (keyed "intensity")
│     - mode             : TTIOIRMode       (Transmittance=0 / Absorbance=1)
│     - resolutionCmInv  : double
│     - numberOfScans    : NSUInteger
│
├── TTIOUVVisSpectrum                                    ← v0.11.1 (M73.1)
│     - wavelengthArray    : TTIOSignalArray  (keyed "wavelength", nm)
│     - absorbanceArray    : TTIOSignalArray  (keyed "absorbance")
│     - pathLengthCm       : double           (nullable)
│     - solvent            : NSString         (nullable)
│
└── TTIOTwoDimensionalCorrelationSpectrum                ← v0.11.1 (M73.1)
      - variableAxis       : TTIOSignalArray  (keyed "variable_axis", float64[N])
      - synchronousMatrix  : TTIOSignalArray  (keyed "synchronous", rank-2 float64[N×N])
      - asynchronousMatrix : TTIOSignalArray  (keyed "asynchronous", rank-2 float64[N×N])
      - (feature-flagged   : opt_native_2d_cos)

TTIOSignalArray
└── TTIOFreeInductionDecay
      - realComponent    : NSData
      - imaginaryComponent : NSData
      - dwellTime        : double
      - numberOfScans    : NSUInteger
      - receiverGain     : double

NSObject
├── TTIOChromatogram <TTIOCVAnnotatable>
│     - timeArray        : TTIOSignalArray
│     - intensityArray   : TTIOSignalArray
│     - chromatogramType : TTIOChromatogramType  (TIC / XIC / SRM)
│
└── TTIOTransitionList
      - transitions : NSArray<TTIOTransition*>

TTIOSpectralDataset
├── TTIOMSImage
│     - spatialDimensions : CGSize (or {width,height} struct)
│     - pixelSize         : CGSize
│     - scanPattern       : NSString
│     - gridSpectra       : NSArray<NSArray<TTIOMassSpectrum*>*>
│
├── TTIORamanImage                                       ← v0.11 (M73)
│     - width, height, spectralPoints, tileSize   : NSUInteger
│     - pixelSizeX, pixelSizeY                    : double
│     - scanPattern                               : NSString
│     - excitationWavelengthNm, laserPowerMw      : double
│     - intensityCube                             : NSData (float64[H][W][SP])
│     - wavenumbers                               : NSData (float64[SP])
│
└── TTIOIRImage                                          ← v0.11 (M73)
      - width, height, spectralPoints, tileSize   : NSUInteger
      - pixelSizeX, pixelSizeY                    : double
      - scanPattern                               : NSString
      - mode                                      : TTIOIRMode
      - resolutionCmInv                           : double
      - intensityCube                             : NSData (float64[H][W][SP])
      - wavenumbers                               : NSData (float64[SP])
```

### Layer 3b — Transport + Per-AU Encryption (v0.10)

Added in v0.10.0 across all three languages. Names shown are the
ObjC surface; Python uses snake_case in `ttio.transport` /
`ttio.encryption_per_au`, Java uses PascalCase in
`com.dtwthalion.tio.transport` / `.protection`.

**Transport codec + networking** (`TTIOTransport*`; see
`docs/transport-spec.md`):

```
TTIOTransportPacketHeader  (24-byte wire header)
TTIOTransportPacketRecord  (header + payload pair)
TTIOTransportWriter        (.tis emission)
TTIOTransportReader        (.tis parsing)
TTIOTransportClient        (WebSocket push)
TTIOTransportServer        (WebSocket accept + route)
TTIOAccessUnit             (single-spectrum transport-level record)
TTIOChannelData            (per-channel payload inside an AU)
TTIOProtectionMetadata     (cipher_suite + wrapped_dek + signature_algorithm + public_key)
TTIOAcquisitionSimulator   (replay fixtures at wall-clock pace)
TTIOAUFilter               (selective access predicate)
```

**Per-AU encryption** (`TTIOPerAU*` /
`com.dtwthalion.tio.protection.PerAU*` /
`ttio.encryption_per_au`; see
`docs/transport-encryption-design.md`):

```
TTIOChannelSegment       (offset, length, iv, tag, ciphertext)
TTIOHeaderSegment        (iv, tag, ciphertext[36])
TTIOAUHeaderPlaintext    (acq_mode, ms_level, polarity, rt,
                           precursor_mz, precursor_charge,
                           ion_mobility, base_peak_intensity)
TTIOPerAUEncryption      (AAD helpers + encrypt/decrypt with AAD)
TTIOPerAUFile            (file-level orchestrator via StorageProvider)
TTIOEncryptedTransport   (writer + reader for encrypted .tis streams)
```

All per-AU APIs are **class methods** (no instance state) on the
manager classes. Segment / plaintext / metadata classes are value
objects.

### Layer 3c — Vibrational spectroscopy (v0.11 / M73)

Four concrete classes add Raman and IR support alongside the
existing MS / NMR hierarchy. Python uses snake_case in
`ttio.{raman_spectrum,ir_spectrum,raman_image,ir_image}`; Java
uses PascalCase in `com.dtwthalion.tio.{RamanSpectrum,IRSpectrum,
RamanImage,IRImage}`.

- **TTIORamanSpectrum / TTIOIRSpectrum** — `TTIOSpectrum`
  subclasses keyed by `"wavenumber"` + `"intensity"`. Raman carries
  excitation / laser / integration; IR carries mode (transmittance
  vs absorbance, `TTIOIRMode` enum), spectral resolution, and
  scan count.
- **TTIORamanImage / TTIOIRImage** — spatial intensity cubes with
  a shared `wavenumbers` axis. HDF5 layout is documented in
  `docs/format-spec.md` §7a.
- **JCAMP-DX 5.01 AFFN bridge** — `TTIOJcampDxReader` /
  `TTIOJcampDxWriter` (plus `ttio.importers/exporters.jcamp_dx`
  and `com.dtwthalion.tio.{importers,exporters}.JcampDx*`). All
  three writers emit byte-identical output for the same logical
  spectrum and all three readers parse each other's output
  bit-for-bit (see
  `python/tests/integration/test_raman_ir_cross_language.py`).

### Layer 3d — UV-Vis and 2D correlation (v0.11.1 / M73.1)

Two additional `TTIOSpectrum` subclasses + JCAMP-DX compression
reader support shipped in the v0.11.1 patch release. All three
languages expose matching surfaces.

- **TTIOUVVisSpectrum / UVVisSpectrum** — 1-D UV/visible absorption
  spectrum keyed by `"wavelength"` (nm) + `"absorbance"`, with
  optional `pathLengthCm` + `solvent` metadata. The JCAMP-DX
  reader dispatches `UV/VIS SPECTRUM`, `UV-VIS SPECTRUM`, and
  `UV/VISIBLE SPECTRUM` variants here. The JCAMP-DX writer emits
  `##DATA TYPE=UV/VIS SPECTRUM` with `##XUNITS=NANOMETERS`,
  `##YUNITS=ABSORBANCE`, and `##$PATH LENGTH CM` / `##$SOLVENT`
  custom LDRs.
- **TTIOTwoDimensionalCorrelationSpectrum /
  TwoDimensionalCorrelationSpectrum** — Noda 2D-COS representation
  with rank-2 synchronous (in-phase, symmetric) and asynchronous
  (quadrature, antisymmetric) correlation matrices sharing a single
  variable axis. Row-major `float64[N×N]`; construction validates
  rank, shape match, and squareness. Persistence is gated behind
  the `opt_native_2d_cos` feature flag (see
  `docs/feature-flags.md`).
- **JCAMP-DX 5.01 compression reader** — readers in all three
  languages now decode §5.9 PAC / SQZ / DIF / DUP bodies, with the
  full SQZ (`@`, `A-I`, `a-i`), DIF (`%`, `J-R`, `j-r`), and DUP
  (`S-Z`, `s`) alphabets plus the DIF Y-check convention. Writers
  remain AFFN-only. See `docs/vendor-formats.md`.

---

## Enumerations

```objc
typedef NS_ENUM(NSUInteger, TTIOSamplingMode) {
    TTIOSamplingModeUniform = 0,
    TTIOSamplingModeNonUniform
};

typedef NS_ENUM(NSUInteger, TTIOPrecision) {
    TTIOPrecisionFloat32 = 0,
    TTIOPrecisionFloat64,
    TTIOPrecisionInt32,
    TTIOPrecisionInt64,
    TTIOPrecisionUInt32,
    TTIOPrecisionComplex128
};

typedef NS_ENUM(NSUInteger, TTIOCompression) {
    TTIOCompressionNone = 0,
    TTIOCompressionZlib,
    TTIOCompressionLZ4
};

typedef NS_ENUM(NSUInteger, TTIOByteOrder) {
    TTIOByteOrderLittleEndian = 0,
    TTIOByteOrderBigEndian
};

typedef NS_ENUM(NSInteger, TTIOPolarity) {
    TTIOPolarityUnknown  =  0,
    TTIOPolarityPositive = +1,
    TTIOPolarityNegative = -1
};

typedef NS_ENUM(NSUInteger, TTIOIRMode) {        // v0.11 / M73
    TTIOIRModeTransmittance = 0,
    TTIOIRModeAbsorbance    = 1
};

typedef NS_ENUM(NSUInteger, TTIOChromatogramType) {
    TTIOChromatogramTypeTIC = 0,
    TTIOChromatogramTypeXIC,
    TTIOChromatogramTypeSRM
};

typedef NS_ENUM(NSUInteger, TTIOAcquisitionMode) {
    TTIOAcquisitionModeMS1DDA = 0,
    TTIOAcquisitionModeMS2DDA,
    TTIOAcquisitionModeDIA,
    TTIOAcquisitionModeSRM,
    TTIOAcquisitionMode1DNMR,
    TTIOAcquisitionMode2DNMR,
    TTIOAcquisitionModeImaging
};

typedef NS_ENUM(NSUInteger, TTIOEncryptionLevel) {
    TTIOEncryptionLevelNone = 0,
    TTIOEncryptionLevelDatasetGroup,
    TTIOEncryptionLevelDataset,
    TTIOEncryptionLevelDescriptorStream,
    TTIOEncryptionLevelAccessUnit
    // v0.10: AccessUnit-level encryption is realised via
    // opt_per_au_encryption + TTIOPerAUFile (see
    // docs/transport-encryption-design.md) rather than a new enum
    // case. The enum is kept for the v0.4 channel-granular mode that
    // remains valid.
};

// v0.10 compound field kind catalog (docs/format-spec.md §6):
typedef NS_ENUM(NSUInteger, TTIOCompoundFieldKind) {
    TTIOCompoundFieldKindUInt32 = 0,
    TTIOCompoundFieldKindInt64,
    TTIOCompoundFieldKindFloat64,
    TTIOCompoundFieldKindVLString,
    TTIOCompoundFieldKindVLBytes   // added v0.10 for <channel>_segments
};

// v0.10 transport packet wire types (docs/transport-spec.md §3.2):
typedef NS_ENUM(uint8_t, TTIOTransportPacketType) {
    TTIOTransportPacketStreamHeader        = 0x01,
    TTIOTransportPacketDatasetHeader       = 0x02,
    TTIOTransportPacketAccessUnit          = 0x03,
    TTIOTransportPacketProtectionMetadata  = 0x04,
    TTIOTransportPacketAnnotation          = 0x05,
    TTIOTransportPacketProvenance          = 0x06,
    TTIOTransportPacketChromatogram        = 0x07,
    TTIOTransportPacketEndOfDataset        = 0x08,
    TTIOTransportPacketEndOfStream         = 0xFF
};
```
