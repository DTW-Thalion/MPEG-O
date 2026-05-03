# HANDOFF.md — OpenStep-Style API Documentation Pass

## Goal

Add structured API documentation comments to every public class, protocol/interface, and method across all three TTI-O implementations (Objective-C, Python, Java). The comment format follows the OpenStep Programming Reference style — each class/protocol gets a header block listing **Inherits From**, **Conforms To**, **Declared In**, followed by a **Class Description**, then individual **Method** documentation blocks.

After adding the comments, configure the platform-native documentation generator for each language so that `make docs` (or equivalent) produces browsable API reference output.

**This is a documentation-only pass. No logic changes. No new tests. All existing tests must continue to pass.**

---

## Copyright & Authorship Rules (MANDATORY — read before writing any comment)

### Copyright line

All copyright lines — in new doc comments AND in existing file headers — must read exactly:

```
Copyright (c) 2026 The Thalion Initiative
```

No other entity may appear in copyright lines. Specifically:
- **No "DTW-Thalion"** — replace every occurrence.
- **No individual names** — no personal attribution.
- **No "Claude"**, **no "Anthropic"**, **no "AI-generated"** — no AI authorship credit anywhere.

### Author tags

- **Do NOT** add `@author` tags (Javadoc), `author` fields (pyproject.toml metadata is out of scope — leave it alone), `<author>` elements (gsdoc), or `Author:` lines in any doc comment.
- If existing file headers contain `@author` or author attribution lines, **remove them**.

### No development history in documentation

Documentation must read as a first-instance description of the code as it exists today. The history of its development is captured in source control and is not part of the API reference. Specifically:

- **No milestone references** — remove all occurrences of `M1`, `M32`, `M37`, `M40`, `M41.5`, `M57`, `M68`, `M70`, `M75`, `M79`, `M82`, `M83`, or any `M<number>` pattern in comments.
- **No version-history annotations** — remove `@since` tags (Javadoc), `.. versionadded::` directives (Sphinx), and phrases like "delivered in v0.9", "added in v0.11", "shipped in v1.0", "v0.10 M70", etc.
- **No "API status" lines that reference versions** — write `API status: Stable.` if the status is relevant. Never `Stable (v1.0+)` or `Stable since v0.8`.
- **No change-log prose** — do not describe when features were added or what release introduced them. Describe *what the code does*, not *when it arrived*.
- **No "deferred" / "planned" / "not yet implemented" notes** — if the code exists, document it. If it doesn't exist, don't mention it.
- **No comments referencing HANDOFF.md, WORKPLAN.md, or binding decisions** — these are internal project artefacts, not API documentation.

Examples of lines to **strip or rewrite** from existing comments:

```
# BEFORE (existing code):
/** v0.11 M82: zero or more named genomic runs. Empty for pre-M82
 *  files; populated when /study/genomic_runs/ is present. */

# AFTER:
/** Zero or more named genomic runs. Populated when the
 *  {@code /study/genomic_runs/} group is present in the container. */
```

```
# BEFORE:
/* TTI-O Java Implementation — v0.10 M70. */

# AFTER:
/* TTI-O Java Implementation */
```

```
# BEFORE:
# v0.7 M46: ZarrProvider reference implementation. v0.9 migrated the
# on-disk format from Zarr v2 to v3, so the dependency is pinned to
# zarr-python 3.x.

# AFTER:
# ZarrProvider reference implementation. The on-disk format uses
# Zarr v3; the dependency is pinned to zarr-python 3.x.
```

```
# BEFORE:
* API status: Stable. Encryptable conformance delivered in
* M41.5 in non-ObjC implementations.

# AFTER:
* API status: Stable.
```

### Pre-Step: Scrub existing headers across all three languages

Before writing any new documentation, do a global find-and-replace pass:

```bash
# 1. Replace DTW-Thalion copyright lines everywhere in source (not in README, LICENSE, CI configs):
find objc/Source python/src java/src -type f \( -name '*.h' -o -name '*.m' -o -name '*.py' -o -name '*.java' \) \
  -exec sed -i 's/Copyright (C) [0-9]* DTW-Thalion/Copyright (c) 2026 The Thalion Initiative/g' {} +

# 2. Replace any other "DTW-Thalion" mentions inside comment blocks (not in import paths or package names):
#    Be surgical — "DTW-Thalion" in package names like global.thalion.ttio must NOT be touched.
#    Only replace within /* */ and /** */ comment blocks or # comment lines or docstrings.
#    Use grep first to audit:
grep -rn "DTW-Thalion" objc/Source/ python/src/ java/src/ --include='*.h' --include='*.m' --include='*.py' --include='*.java'
#    Then manually replace only the comment-block occurrences.

# 3. Remove any @author lines:
find objc/Source python/src java/src -type f \( -name '*.h' -o -name '*.m' -o -name '*.py' -o -name '*.java' \) \
  -exec sed -i '/@author/d' {} +

# 4. Remove @since tags from Java files:
find java/src -name '*.java' -exec sed -i '/@since/d' {} +

# 5. Audit milestone references — these need manual rewriting, not blind deletion:
grep -rn ' M[0-9]' objc/Source/ python/src/ java/src/ --include='*.h' --include='*.m' --include='*.py' --include='*.java'
grep -rn 'v0\.[0-9]' objc/Source/ python/src/ java/src/ --include='*.h' --include='*.m' --include='*.py' --include='*.java' | grep -v 'import\|package\|from\|require'
#    For each hit: rewrite the comment to describe the current state without
#    referencing the version or milestone. See the before/after examples above.

# 6. Also scrub milestone comments from build/config files:
grep -rn ' M[0-9]\|v0\.[0-9].*M[0-9]' python/pyproject.toml java/pom.xml objc/Source/GNUmakefile 2>/dev/null
#    Rewrite these inline comments to describe the current purpose without
#    version/milestone prefixes (e.g. "# v0.7 M46: ZarrProvider" → "# ZarrProvider").

# 7. Strip "— v0.10 M70." and similar version stamps from file headers:
find java/src -name '*.java' -exec sed -i 's/ — v[0-9.]*\( M[0-9]*\)\?\.//' {} +

# 8. Verify nothing broke:
cd objc && make 2>&1 | tail -5
cd ../python && python -c "import ttio; print('ok')"
cd ../java && mvn compile -q
```

After the scrub, commit: `git commit -am "Normalise copyright to The Thalion Initiative, remove author tags, strip milestone references"`

Then proceed to Phase 0.

---

## Documentation Style Reference

The target output mirrors the 1996 OpenStep Programming Reference (Oracle/NeXT). Each class entry follows this structure:

```
ClassName

Inherits From:    ParentClass : GrandparentClass : ... : RootClass
Conforms To:      ProtocolA, ProtocolB
                  ParentClass (ProtocolC)
Declared In:      Module/FileName.h

Class Description

  [Prose paragraphs describing the class purpose, design rationale,
   thread safety, and usage patterns.]

Method Types

  Creating and Initializing
    - initWithFoo:bar:
    + classMethodBaz

  Querying
    - count
    - objectAtIndex:

Instance Methods

  initWithFoo:bar:
    - (instancetype)initWithFoo:(Type)foo bar:(Type)bar

    Description of what this method does, its preconditions,
    error behavior, and return value semantics.

  count
    - (NSUInteger)count

    Returns the number of elements.

Class Methods

  classMethodBaz
    + (instancetype)classMethodBaz

    Factory method that ...
```

---

## Phase 0 — Inventory & Orientation

Before writing any comments, build a file inventory for each language.

```bash
# Run these to see exactly what needs documenting:
find objc/Source -name '*.h' | sort > /tmp/objc_headers.txt
find objc/Source -name '*.m' | sort > /tmp/objc_impl.txt
find python/src/ttio -name '*.py' ! -name '__pycache__' | sort > /tmp/python_src.txt
find java/src/main/java -name '*.java' | sort > /tmp/java_src.txt
wc -l /tmp/objc_headers.txt /tmp/objc_impl.txt /tmp/python_src.txt /tmp/java_src.txt
```

Work through the files in this directory order (matches the architectural layers, bottom-up):

1. **Protocols / Interfaces / ABCs** — foundation contracts
2. **ValueClasses / value types** — immutable data holders
3. **HDF5 wrappers** — storage layer
4. **Core** (SignalArray, Numpress) — atomic primitives
5. **Spectra** — spectrum class hierarchy
6. **Run** — AcquisitionRun, InstrumentConfig, SpectrumIndex
7. **Genomics** — GenomicRun, AlignedRead, etc.
8. **Dataset** — SpectralDataset, Identification, Quantification, etc.
9. **Image** — MSImage, RamanImage, IRImage
10. **Protection** — encryption, signatures, anonymization
11. **Query** — compressed-domain query, stream reader/writer
12. **Import** — all readers (mzML, nmrML, Thermo, Bruker, etc.)
13. **Export** — all writers (mzML, nmrML, ISA, etc.)
14. **Providers** — StorageProtocols, HDF5Provider, MemoryProvider, etc.
15. **Transport** — packets, codec, server, client
16. **Analysis** — TwoDCos
17. **Tools / CLI** — command-line entry points

---

## Phase 1 — Objective-C (`.h` headers + `.m` implementation files)

### 1A — Header files (`.h`): autogsdoc-compatible `/** */` blocks

**Tool**: GNUstep `autogsdoc`. It extracts documentation from `/** ... */` comment blocks placed immediately before `@interface`, `@protocol`, `@property`, and method declarations.

autogsdoc **automatically** generates "Inherits From", "Conforms To", and "Declared In" from the parsed source. Your job is to provide the **Class Description** and **method-level** documentation in the right format.

#### Class/Protocol header comment (before `@interface` or `@protocol`):

```objc
/**
 * <heading>TTIOSignalArray</heading>
 *
 * <p><em>Inherits From:</em> NSObject</p>
 * <p><em>Conforms To:</em> TTIOCVAnnotatable</p>
 * <p><em>Declared In:</em> Core/TTIOSignalArray.h</p>
 *
 * <p>The atomic unit of measured signal in TTI-O. A SignalArray wraps a
 * typed numeric buffer with an encoding spec, an optional axis descriptor,
 * and an arbitrary number of controlled-vocabulary annotations.</p>
 *
 * <p>Construction is via <code>-initWithBuffer:length:encoding:axis:</code>
 * with raw bytes; the caller is responsible for matching the buffer layout
 * to the encoding's <code>elementSize</code>. HDF5 round-trip is via
 * <code>-writeToGroup:name:chunkSize:compressionLevel:error:</code> and
 * <code>+readFromGroup:name:error:</code>.</p>
 *
 * <p>Not thread-safe. Mutating CV annotations from multiple threads
 * is undefined behaviour.</p>
 *
 * <p><strong>API status:</strong> Stable.</p>
 *
 * <p><strong>Cross-language equivalents:</strong><br/>
 * Python: <code>ttio.signal_array.SignalArray</code><br/>
 * Java: <code>global.thalion.ttio.SignalArray</code></p>
 */
@interface TTIOSignalArray : NSObject <TTIOCVAnnotatable>
```

#### Property comment:

```objc
/** The raw byte buffer holding the signal data. Length in bytes equals
 *  <code>length * encoding.elementSize</code>. */
@property (readonly, copy) NSData *buffer;
```

#### Method comment:

```objc
/**
 * Designated initialiser. Creates a SignalArray from a raw byte buffer.
 *
 * @param buffer   Raw bytes. Must contain exactly
 *                 <code>length * encoding.elementSize</code> bytes.
 * @param length   Number of signal elements (not bytes).
 * @param encoding Wire-format encoding (precision + compression + byte order).
 * @param axis     Optional axis descriptor; pass <code>nil</code> if unknown.
 * @return An initialised SignalArray, or <code>nil</code> on failure.
 */
- (instancetype)initWithBuffer:(NSData *)buffer
                        length:(NSUInteger)length
                      encoding:(TTIOEncodingSpec *)encoding
                          axis:(TTIOAxisDescriptor *)axis;
```

#### Protocol comment:

```objc
/**
 * <heading>TTIOCVAnnotatable</heading>
 *
 * <p><em>Conforms To:</em> (none — root protocol)</p>
 * <p><em>Declared In:</em> Protocols/TTIOCVAnnotatable.h</p>
 *
 * <p>Declares the interface for attaching and querying controlled-vocabulary
 * (CV) annotations on any TTI-O object. Annotations are <code>TTIOCVParam</code>
 * instances keyed by ontology reference and accession number.</p>
 *
 * <p>All five concrete spectrum types, <code>SignalArray</code>, and
 * <code>AcquisitionRun</code> conform to this protocol.</p>
 */
@protocol TTIOCVAnnotatable <NSObject>
```

### 1B — Implementation files (`.m`): file-level `/* */` comment block

At the **top of each `.m` file**, add or replace the existing header comment with a structured block. This is a plain `/* */` comment (not `/** */`) since it is not parsed by autogsdoc — it is for human readers of the source.

```objc
/*
 * TTIOSignalArray.m
 * TTI-O Objective-C Implementation
 *
 * Class:        TTIOSignalArray
 * Inherits From: NSObject
 * Conforms To:  TTIOCVAnnotatable
 * Declared In:  Core/TTIOSignalArray.h
 *
 * The atomic unit of measured signal in TTI-O. A SignalArray wraps a
 * typed numeric buffer with encoding metadata, an optional axis
 * descriptor, and controlled-vocabulary annotations.
 *
 * This file implements HDF5 serialisation (write + read), equality,
 * hashing, and the CVAnnotatable protocol methods.
 *
 * SPDX-License-Identifier: LGPL-3.0-or-later
 * Copyright (c) 2026 The Thalion Initiative
 */
```

For each method implementation in the `.m`, add a `/* */` block:

```objc
/*
 * -initWithBuffer:length:encoding:axis:
 *
 * Designated initialiser. Copies the buffer bytes, retains encoding
 * and axis. Does NOT validate that buffer.length == length * elementSize;
 * that is the caller's responsibility.
 *
 * Inputs:
 *   buffer   — NSData with raw signal bytes.
 *   length   — element count (not byte count).
 *   encoding — TTIOEncodingSpec (precision + compression + byte order).
 *   axis     — TTIOAxisDescriptor or nil.
 *
 * Output:
 *   Returns self.
 */
- (instancetype)initWithBuffer:(NSData *)buffer
                        length:(NSUInteger)length
                      encoding:(TTIOEncodingSpec *)encoding
                          axis:(TTIOAxisDescriptor *)axis {
```

### 1C — Protocols (`.h` only, no `.m`)

Apply the same `/** */` pattern as 1A to every protocol header under `objc/Source/Protocols/`. Protocols have no "Inherits From" — use `(root protocol)` or list the protocol they extend.

### 1D — Build autogsdoc

After all comments are in place, add a documentation target:

```bash
# In objc/, create a docs/ output directory and run autogsdoc:
mkdir -p objc/docs/api

# Create objc/Documentation/ttio.gsdoc with project-level metadata:
cat > objc/Documentation/ttio.gsdoc << 'GSDOC'
<?xml version="1.0"?>
<!DOCTYPE gsdoc PUBLIC "-//GNUstep//DTD gsdoc 1.0.4//EN"
  "http://www.gnustep.org/gsdoc-1_0_4.dtd">
<gsdoc base="TTI-O">
  <head>
    <title>TTI-O Objective-C API Reference</title>
    <version>1.1.0</version>
    <date>2026</date>
  </head>
  <body>
    <chapter>
      <heading>TTI-O Objective-C API Reference</heading>
      <p>API documentation for the Objective-C reference implementation
      of the TTI-O multi-omics data standard.</p>
    </chapter>
  </body>
</gsdoc>
GSDOC
```

If `autogsdoc` is not available on the WSL build environment, fall back to **HeaderDoc** or **Doxygen** (both parse `/** */` with `@param`/`@return` tags). For Doxygen, create `objc/Doxyfile`:

```
PROJECT_NAME     = "TTI-O Objective-C"
INPUT            = Source/
FILE_PATTERNS    = *.h *.m
RECURSIVE        = YES
OUTPUT_DIRECTORY = docs/api
GENERATE_HTML    = YES
GENERATE_LATEX   = NO
EXTRACT_ALL      = YES
JAVADOC_AUTOBRIEF = YES
```

Run: `cd objc && doxygen Doxyfile`

---

## Phase 2 — Python (`python/src/ttio/**/*.py`)

### Tool: Sphinx with autodoc + NumPy-style docstrings

Python does not use `/* */` comments. The equivalent is:
- **Module-level docstring** (triple-quoted at top of file) — acts as the file header block
- **Class docstring** — acts as the Class Description
- **Method docstrings** — acts as method documentation

### 2A — Module-level docstring (top of each `.py` file)

Replace or augment the existing module docstring with a structured header:

```python
"""
TTIOSignalArray — numpy buffer + axis + encoding metadata.

Class:           SignalArray
Inherits From:   (none — dataclass)
Conforms To:     CVAnnotatable (duck-typed)
Declared In:     ttio/signal_array.py

The atomic unit of measured signal in TTI-O. A SignalArray wraps a
numpy 1-D array with encoding metadata, an optional axis descriptor,
and controlled-vocabulary annotations.

SPDX-License-Identifier: LGPL-3.0-or-later
Copyright (c) 2026 The Thalion Initiative
"""
```

### 2B — Class docstring (OpenStep-style, NumPy format)

```python
@dataclass(slots=True)
class SignalArray:
    """The atomic unit of measured signal in TTI-O.

    Inherits From
    -------------
    (none — ``@dataclass``)

    Conforms To
    -----------
    CVAnnotatable (duck-typed protocol)

    Declared In
    -----------
    ``ttio.signal_array``

    Class Description
    -----------------
    A SignalArray wraps a numpy 1-D array with encoding metadata,
    an optional axis descriptor, and controlled-vocabulary annotations.

    Construction is via the dataclass constructor. HDF5 round-trip is
    handled by ``ttio.hdf5_io`` helper functions.

    Not thread-safe.

    API status: Stable.

    Cross-language equivalents:
        Objective-C: ``TTIOSignalArray``
        Java: ``global.thalion.ttio.SignalArray``

    Parameters
    ----------
    data : numpy.ndarray
        1-D numeric array holding the raw signal values.
    axis : AxisDescriptor or None, optional
        Descriptor of the physical dimension represented by ``data``.
    encoding : EncodingSpec, optional
        Wire-format encoding for HDF5 serialisation.
    cv_params : list of CVParam, optional
        Initial CV annotations.
    """
```

### 2C — Method docstrings (NumPy format)

```python
def add_cv_param(self, param: CVParam) -> None:
    """Attach a controlled-vocabulary annotation to this array.

    Parameters
    ----------
    param : CVParam
        The annotation to attach. Duplicates are allowed;
        annotations are stored in insertion order.

    Returns
    -------
    None
    """
```

For `@staticmethod` and `@classmethod`, include the same structure.

### 2D — Build Sphinx

Create `python/docs/` with Sphinx configuration:

```bash
mkdir -p python/docs
```

Create `python/docs/conf.py`:

```python
project = 'TTI-O Python'
version = '1.1.0'
extensions = ['sphinx.ext.autodoc', 'sphinx.ext.napoleon', 'sphinx.ext.viewcode']
napoleon_google_docstring = False
napoleon_numpy_docstring = True
autodoc_member_order = 'bysource'
html_theme = 'alabaster'
```

Create `python/docs/index.rst`:

```rst
TTI-O Python API Reference
===========================

.. toctree::
   :maxdepth: 2
   :caption: Contents:

   api/signal_array
   api/spectrum
   api/mass_spectrum
   ...

.. automodule:: ttio
   :members:
```

Create per-module `.rst` files under `python/docs/api/` using `sphinx-apidoc`:

```bash
cd python && pip install sphinx --break-system-packages
sphinx-apidoc -o docs/api src/ttio --separate
cd docs && make html
```

---

## Phase 3 — Java (`java/src/main/java/global/thalion/ttio/**/*.java`)

### Tool: Javadoc (standard JDK tool)

Java already uses `/** */` for Javadoc. Augment every class and method.

### 3A — File-level comment (top of each `.java` file, before `package`)

```java
/*
 * SignalArray.java
 * TTI-O Java Implementation
 *
 * Class:        SignalArray
 * Inherits From: Object
 * Implements:   CVAnnotatable
 * Declared In:  global.thalion.ttio.SignalArray
 *
 * The atomic unit of measured signal in TTI-O. A SignalArray wraps a
 * typed numeric buffer with encoding metadata, an optional axis
 * descriptor, and controlled-vocabulary annotations.
 *
 * SPDX-License-Identifier: LGPL-3.0-or-later
 * Copyright (c) 2026 The Thalion Initiative
 */
package global.thalion.ttio;
```

### 3B — Class-level Javadoc (before `public class`)

```java
/**
 * The atomic unit of measured signal in TTI-O.
 *
 * <h2>Inherits From</h2>
 * <p>{@link Object}</p>
 *
 * <h2>Implements</h2>
 * <p>{@link CVAnnotatable}</p>
 *
 * <h2>Declared In</h2>
 * <p>{@code global.thalion.ttio.SignalArray}</p>
 *
 * <h2>Class Description</h2>
 * <p>A {@code SignalArray} wraps a typed numeric buffer with an encoding
 * spec, an optional axis descriptor, and an arbitrary number of
 * controlled-vocabulary annotations.</p>
 *
 * <p>Construction is via the full constructor or convenience factory
 * methods ({@link #ofDoubles}, {@link #ofFloats}). HDF5 round-trip is
 * handled by {@link global.thalion.ttio.hdf5.Hdf5Dataset}.</p>
 *
 * <p><strong>API status:</strong> Stable.</p>
 *
 * <p><strong>Cross-language equivalents:</strong><br>
 * Objective-C: {@code TTIOSignalArray}<br>
 * Python: {@code ttio.signal_array.SignalArray}</p>
 */
public class SignalArray implements CVAnnotatable {
```

### 3C — Method-level Javadoc

```java
/**
 * Creates a SignalArray from a {@code double[]} with default
 * FLOAT64 / ZLIB / little-endian encoding.
 *
 * <p>This is a convenience factory. The returned array has no axis
 * descriptor and no CV annotations.</p>
 *
 * @param data  the signal values; must not be {@code null}
 * @return a new SignalArray wrapping {@code data}
 * @throws NullPointerException if {@code data} is null
 */
public static SignalArray ofDoubles(double[] data) {
```

### 3D — Build Javadoc

Add a Javadoc profile to `java/pom.xml` (or just run directly):

```bash
cd java
mvn javadoc:javadoc -Dshow=public -DdestDir=docs/api
```

Or add to `pom.xml`:

```xml
<plugin>
  <groupId>org.apache.maven.plugins</groupId>
  <artifactId>maven-javadoc-plugin</artifactId>
  <version>3.6.3</version>
  <configuration>
    <show>public</show>
    <reportOutputDirectory>${project.basedir}/docs</reportOutputDirectory>
    <destDir>api</destDir>
    <doctitle>TTI-O Java API Reference</doctitle>
    <windowtitle>TTI-O Java API</windowtitle>
  </configuration>
</plugin>
```

---

## Structural Rules (All Languages)

### What to document

1. **Every public class / protocol / interface** — full structured header block.
2. **Every public method** — description, parameters, return value, exceptions/errors.
3. **Every public property / field** — one-line description.
4. **Enums** — brief description of each case/constant.

### What NOT to document

1. **Test files** — skip everything under `Tests/`, `tests/`, `src/test/`.
2. **Private/internal methods** — skip methods prefixed with `_` (Python) or not in the public header (ObjC). For Java, skip `private` methods.
3. **Generated code** — skip if any exists.

### Content guidelines

- **First sentence** of every description must be a concise summary (Javadoc "summary sentence" rule).
- **Describe the present** — document what the code *does*, not when or why it was added. No version history, no milestone references, no change-log narrative.
- **Thread safety** — always state whether the class is thread-safe, not thread-safe, or conditionally thread-safe.
- **Error handling** — document what happens on invalid input (nil/null, wrong types, range violations).
- **Cross-language equivalents** — always include the mapping to the other two implementations.
- Keep prose **factual and precise** — no marketing language. Mirror the flat, declarative tone of the OpenStep reference.
- Use **present tense**: "Returns the count" not "This method will return the count."

### Preserving existing comments

- If a file already has a `/** */` or docstring with useful content, **preserve and augment** it — do not delete information. Merge the existing text into the new structured format.
- Preserve all existing `SPDX-License-Identifier` lines. If missing, add `SPDX-License-Identifier: LGPL-3.0-or-later`.
- **Replace** any existing `Copyright` lines with `Copyright (c) 2026 The Thalion Initiative` (the pre-step scrub should have caught these, but double-check each file as you touch it).
- **Remove** any `@author`, `Author:`, or author-attribution lines. Do not add new ones.

---

## Processing Order & Batching

Given the file count (~80+ per language), work in **directory batches**. Complete one directory fully (all files in it) before moving to the next. Within each directory, process files alphabetically.

### Batch sequence:

```
BATCH 1:  ObjC Protocols/       (5 .h files)
BATCH 2:  ObjC ValueClasses/    (6 .h + 5 .m files)
BATCH 3:  ObjC HDF5/            (7 .h + 7 .m files)
BATCH 4:  ObjC Core/            (2 .h + 2 .m files)
BATCH 5:  ObjC Spectra/         (10 .h + 10 .m files)
BATCH 6:  ObjC Run/             (3 .h + 3 .m files)
BATCH 7:  ObjC Genomics/        (4 .h + 4 .m files)
BATCH 8:  ObjC Dataset/         (7 .h + 7 .m files)
BATCH 9:  ObjC Image/           (3 .h + 3 .m files)
BATCH 10: ObjC Protection/      (~10 .h + ~10 .m files)
BATCH 11: ObjC Query/           (3 .h + 3 .m files)
BATCH 12: ObjC Import/          (~10 .h + ~10 .m files)
BATCH 13: ObjC Export/          (~7 .h + ~7 .m files)
BATCH 14: ObjC Providers/       (~6 .h + ~6 .m files)
BATCH 15: ObjC Transport/       (~10 .h + ~10 .m files)
BATCH 16: ObjC Analysis/        (1 .h + 1 .m files)
BATCH 17: Python src/ttio/ core modules (signal_array, spectrum, mass_spectrum, etc.)
BATCH 18: Python src/ttio/ remaining modules (importers, exporters, providers, etc.)
BATCH 19: Java core classes (SignalArray, Spectrum, SpectralDataset, etc.)
BATCH 20: Java remaining (importers, exporters, protection, transport, etc.)
BATCH 21: Documentation build config (autogsdoc/Doxygen, Sphinx, Javadoc)
```

**If context window fills up mid-batch**, commit what you have, then continue in the next invocation starting from where you left off. Use `git diff --stat` to confirm what has been modified.

---

## Acceptance Criteria

1. **Every public `.h` file** in `objc/Source/` has a structured `/** */` class/protocol block with Inherits From, Conforms To, Declared In, and Class Description.
2. **Every public method** in ObjC `.h` files has a `/** */` block with `@param` and `@return` tags.
3. **Every `.m` file** has a `/* */` file-level header and `/* */` per-method blocks.
4. **Every Python `.py` file** in `python/src/ttio/` has a module docstring, class docstring with structured OpenStep-style sections, and method docstrings in NumPy format.
5. **Every Java `.java` file** in `java/src/main/java/` has a file-level `/* */`, class Javadoc with structured sections, and method Javadoc with `@param`/`@return`/`@throws`.
6. **All existing tests pass** — `make check` (ObjC), `pytest` (Python), `mvn verify` (Java).
7. **Documentation generation config exists** — at least one of autogsdoc/Doxygen (ObjC), Sphinx (Python), Javadoc (Java) is configured and produces output without errors.
8. **No logic changes** — `git diff` shows only comment additions/modifications and doc config files.
9. **Zero milestone or version-history references** remain in any source comment. Verify: `grep -rn ' M[0-9]' objc/Source/ python/src/ java/src/ --include='*.h' --include='*.m' --include='*.py' --include='*.java'` returns nothing. `grep -rn '@since' java/src/` returns nothing.
10. **Zero DTW-Thalion references** remain in source comments. All copyright lines read `Copyright (c) 2026 The Thalion Initiative`.

---

## Anti-Patterns to Avoid

- **Do NOT** add `@author` tags, `Author:` lines, or any personal/AI authorship attribution.
- **Do NOT** write "DTW-Thalion" anywhere in comments — use "The Thalion Initiative" only in the copyright line.
- **Do NOT** reference milestones (M1, M32, M82, etc.), version history ("added in v0.9"), `@since` tags, or any development timeline.
- **Do NOT** reference HANDOFF.md, WORKPLAN.md, or binding decisions in doc comments.
- **Do NOT** write "deferred", "planned", "not yet implemented", or "reserved for" in API docs.
- **Do NOT** add `@interface` or `@implementation` blocks — this is comments only.
- **Do NOT** change any method signatures, property types, or access levels.
- **Do NOT** add new imports or dependencies to the production code.
- **Do NOT** modify test files.
- **Do NOT** use `//` single-line comments for the structured documentation — use `/* */` or `/** */` blocks as specified.
- **Do NOT** invent functionality that doesn't exist — describe what the code actually does, not what it might do.
- **Do NOT** document private methods in ObjC `.m` files that have `static` linkage or are in class extensions — a brief `/* */` is fine but don't invest in full OpenStep-style docs for internals.

---

## Quick-Start Checklist

```
[ ] Read the existing header/source for the file
[ ] Identify: class name, parent class, protocols/interfaces, file path
[ ] Write the structured header block (Inherits From, Conforms To, Declared In)
[ ] Write the Class Description (preserve existing content, augment)
[ ] Write method docs for each public method (params, return, errors)
[ ] Write property docs (one-liners)
[ ] Verify the file still compiles (no syntax errors in comments)
[ ] Move to next file
```
