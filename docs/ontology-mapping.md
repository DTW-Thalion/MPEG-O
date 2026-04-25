# TTI-O Ontology Mapping

TTI-O defers semantic richness to external, well-curated ontologies. Any class conforming to `TTIOCVAnnotatable` can be tagged with any number of CV parameters, each referencing a specific term in a specific ontology.

This document lists the primary ontologies that TTI-O readers and writers should recognize, and gives common accession examples.

---

## Primary Ontologies

| Ontology | `ontologyRef` | Scope | URL |
|---|---|---|---|
| PSI-MS Controlled Vocabulary | `MS` | Mass spectrometry terms, instruments, parameters | https://www.ebi.ac.uk/ols/ontologies/ms |
| Units Ontology | `UO` | Units of measurement | https://www.ebi.ac.uk/ols/ontologies/uo |
| NMR Controlled Vocabulary | `nmrCV` | NMR-specific terms | https://nmrml.org/cv/ |
| ChEBI | `CHEBI` | Chemical entities of biological interest | https://www.ebi.ac.uk/chebi/ |
| Basic Formal Ontology | `BFO` | Upper-level ontology (continuants, occurrents) | https://basic-formal-ontology.org/ |
| PATO | `PATO` | Phenotype and trait attributes | https://www.ebi.ac.uk/ols/ontologies/pato |
| OBI | `OBI` | Ontology for Biomedical Investigations | https://obi-ontology.org/ |
| HMDB | `HMDB` | Human Metabolome Database identifiers | https://hmdb.ca/ |

---

## Common CV Parameter Examples

### Mass spectrometry arrays (PSI-MS)

| Accession | Name | Attached To |
|---|---|---|
| `MS:1000514` | m/z array | `TTIOMassSpectrum.mzArray` |
| `MS:1000515` | intensity array | `TTIOMassSpectrum.intensityArray` |
| `MS:1000595` | time array | `TTIOChromatogram.timeArray` |
| `MS:1002816` | mean ion mobility array | `TTIOMassSpectrum.ionMobilityArray` |

### MS instrument components (PSI-MS)

| Accession | Name |
|---|---|
| `MS:1000073` | electrospray ionization (`sourceType`) |
| `MS:1000075` | matrix-assisted laser desorption ionization (`sourceType`) |
| `MS:1000484` | orbitrap (`analyzerType`) |
| `MS:1000084` | time-of-flight (`analyzerType`) |
| `MS:1000253` | electron multiplier (`detectorType`) |

### Acquisition parameters (PSI-MS)

| Accession | Name |
|---|---|
| `MS:1000511` | ms level |
| `MS:1000465` | scan polarity |
| `MS:1000744` | selected ion m/z |
| `MS:1000827` | isolation window target m/z |
| `MS:1000045` | collision energy |

### NMR (nmrCV)

| Accession | Name |
|---|---|
| `NMR:1000049` | nucleus |
| `NMR:1000050` | spectrometer frequency |
| `NMR:1000001` | 1D NMR experiment |
| `NMR:1000332` | COSY |
| `NMR:1000333` | HSQC |
| `NMR:1000334` | NOESY |
| `NMR:1400155` | free induction decay |

### Units (UO)

| Accession | Name |
|---|---|
| `UO:0000010` | second |
| `UO:0000031` | minute |
| `UO:0000169` | parts per million (for NMR chemical shift) |
| `UO:0000221` | dalton |
| `MS:1000040` | m/z (unit) |

### Chemical entities (CHEBI / HMDB)

Identifications reference chemical entities by accession:

```objc
TTIOIdentification *id1 = [TTIOIdentification new];
[id1 setChemicalEntity:@"CHEBI:17234"];   // D-glucose
[id1 setConfidenceScore:0.97];
[id1 addCVParam:[TTIOCVParam paramWithOntologyRef:@"MS"
                                         accession:@"MS:1002356"
                                              name:@"PSM-level FDR"
                                             value:@(0.01)
                                              unit:nil]];
```

---

## BFO Alignment

TTI-O's primitives align to upper-level BFO categories:

| TTI-O class | BFO category |
|---|---|
| `TTIOSignalArray` | `BFO:0000031` (generically dependent continuant — an information artifact) |
| `TTIOSpectrum` | `BFO:0000031` |
| `TTIOAcquisitionRun` | `BFO:0000015` (process) |
| `TTIOProvenanceRecord` | `BFO:0000015` (process) — each record denotes a processing activity |
| `TTIOIdentification` | `BFO:0000031` (assertion artifact) |
| `TTIOInstrumentConfig` | `BFO:0000040` (material entity) via the represented instrument |

This alignment is **optional** — TTI-O files remain valid without any BFO annotation — but supports integration with upper-ontology-aware knowledge graphs.

---

## Implementation Notes

- CV parameter validation (checking that an accession exists in the referenced ontology) is **out of scope** for the core library. A separate validation tool is planned.
- Readers MUST preserve unknown CV parameters on round-trip. A reader that encounters an unfamiliar ontology reference must not drop the annotation.
- The `value` field is typed `id` in Objective-C and serializes as a string in HDF5. Writers should format numeric values with sufficient precision for lossless round-trip where the semantics require it.
