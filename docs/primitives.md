# The Six MPEG-O Data Primitives

MPEG-O is built on six shared primitives that together span the data-generation pipeline from raw measurement to identified, quantified, and provenance-tracked biological entity.

---

## 1. SignalArray

The atomic unit of measured signal — a typed, axis-annotated numeric buffer.

| Field | Type | Description |
|---|---|---|
| `buffer` | `NSData` | Raw bytes, laid out according to `encodingSpec.precision` and `encodingSpec.byteOrder` |
| `encodingSpec` | `MPGOEncodingSpec` | Precision, compression algorithm, byte order |
| `axisDescriptor` | `MPGOAxisDescriptor` | What the indices mean (name, unit, range, sampling) |
| `cvAnnotations` | `NSArray<MPGOCVParam>` | CV parameters attached to this array |

Supported precisions: `Float32`, `Float64`, `Int32`, `Int64`, `UInt32`, `Complex128` (stored as compound `{double re; double im;}`).

A raw NMR FID is a `Complex128` SignalArray indexed by a uniform time axis. An MS m/z array is a `Float64` SignalArray indexed by a non-uniform m/z axis. A chromatogram intensity trace is a `Float32` SignalArray indexed by a uniform retention-time axis.

---

## 2. Spectrum

A named dictionary of SignalArrays that together describe a single spectral observation.

| Field | Type | Description |
|---|---|---|
| `signalArrays` | `NSDictionary<NSString*, MPGOSignalArray*>` | Named channels — e.g. `"mz"`, `"intensity"`, `"ion_mobility"` |
| `coordinateAxes` | `NSArray<MPGOAxisDescriptor>` | Ordered axes when the spectrum is multi-dimensional |
| `indexPosition` | `NSUInteger` | Position within the parent AcquisitionRun |
| `scanTime` | `double` | Acquisition time (seconds from run start) |
| `precursorInfo` | `NSDictionary` (optional) | For tandem MS: precursor m/z, charge, isolation window, activation |
| `cvAnnotations` | `NSArray<MPGOCVParam>` | Spectrum-level CV parameters |

Concrete subclasses (`MPGOMassSpectrum`, `MPGONMRSpectrum`, `MPGONMR2DSpectrum`) add mandatory named arrays and domain-specific metadata.

---

## 3. AcquisitionRun

An ordered, indexable, streamable collection of Spectrum objects that share an instrument configuration and provenance chain. The MPEG-G equivalent of a *Dataset*.

| Field | Type | Description |
|---|---|---|
| `spectra` | `NSArray<MPGOSpectrum>` | Ordered spectra |
| `chromatograms` | `NSArray<MPGOChromatogram>` | Derived or acquired chromatograms |
| `instrumentConfig` | `MPGOInstrumentConfig` | Shared across all spectra in the run |
| `sourceFiles` | `NSArray<NSString>` | Provenance pointers to raw vendor files |
| `provenance` | `NSArray<MPGOProvenanceRecord>` | Processing history |
| `spectrumIndex` | `MPGOSpectrumIndex` | Access Unit index (populated on write) |

An AcquisitionRun conforms to `MPGOIndexable`, `MPGOStreamable`, `MPGOProvenanceable`, and `MPGOEncryptable`.

---

## 4. CVAnnotation (`MPGOCVParam`)

A single controlled-vocabulary parameter bound to an annotatable object.

| Field | Type | Description |
|---|---|---|
| `ontologyRef` | `NSString` | Ontology identifier, e.g. `"MS"`, `"UO"`, `"nmrCV"`, `"BFO"`, `"CHEBI"` |
| `accession` | `NSString` | Term accession, e.g. `"MS:1000514"` |
| `name` | `NSString` | Human-readable term name, e.g. `"m/z array"` |
| `value` | `id` (nullable) | Optional value (string, number, or boolean) |
| `unit` | `NSString` (nullable) | Optional unit accession, e.g. `"MS:1000040"` for m/z |

CVAnnotations are the primary extensibility mechanism: any class conforming to `MPGOCVAnnotatable` can be tagged with any number of CVParams. This allows MPEG-O to remain minimal at the schema level while deferring semantic richness to well-curated ontologies (PSI-MS, nmrCV, CHEBI, BFO, UO).

---

## 5. Identification

A link from a spectrum (or region thereof) to a chemical entity, with confidence and an evidence chain.

| Field | Type | Description |
|---|---|---|
| `spectrumRef` | `NSUInteger` | Index into the parent run's `spectra` array |
| `chemicalEntity` | `NSString` | Identifier (CHEBI, HMDB, PubChem, SMILES, …) |
| `confidenceScore` | `double` | Numeric score whose semantics are declared via CVAnnotation |
| `evidenceChain` | `NSArray` | References to supporting provenance records |
| `cvAnnotations` | `NSArray<MPGOCVParam>` | e.g. search engine, score type, FDR controls |

Identifications are stored in the dataset root, not per-spectrum, so a single spectrum can carry multiple competing identifications.

---

## 6. ProvenanceRecord

A W3C PROV-compatible record of a single processing step.

| Field | Type | Description |
|---|---|---|
| `inputEntities` | `NSArray<NSString>` | URIs or intra-file references to inputs |
| `software` | `NSString` | Tool identifier and version |
| `parameters` | `NSDictionary` | Arbitrary parameter map |
| `outputEntities` | `NSArray<NSString>` | References to outputs |
| `timestamp` | `NSDate` | When the activity occurred |

Chains of ProvenanceRecords form a directed acyclic graph: any entity's history can be traced back to the raw vendor file that produced it, making MPEG-O files self-documenting and suitable for regulated environments.
