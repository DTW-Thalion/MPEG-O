# P2.7 — Java SqliteProvider JSON reader → Jackson — Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development. Checkbox (`- [ ]`) steps.

**Goal:** Replace Java `SqliteProvider`'s brittle hand-rolled JSON **reader** (the `splitJsonObjects` "split on `},{`" + whitespace-fragile `extractJsonString` parser — the #205 bug class) with **Jackson** (`jackson-databind`, already on the classpath transitively via Arrow; declared as a direct dependency). Keep the hand-rolled **serializer** untouched (its output is the cross-language canonical-bytes contract). Add a cross-language compound round-trip conformance test. Java-only, one PR. (OO-assessment P2.7.)

**Architecture:** Reader-only swap. The serializer (`fieldsToJson`/`rowsToJson`/`shapeToJson`/`jsonString`/`jsonValue`) defines byte-identical canonical JSON across the 3 SDKs (`test_compound_writer_parity.py`) and is NOT touched. The reader becomes a robust Jackson tree parse that tolerates whitespace/key-order/escapes — exactly what the brittle parser didn't.

**Tech Stack:** Java 22, Jackson 2.17.0, JUnit 5. Test: `cd ~/TTI-O/java && JAVA_HOME=~/jdk25 mvn -o -Djacoco.skip=true -Dtest=<Class> test` (full `verify` for the ≥0.84 gate). Push from Windows git.

**Hard invariants:**
- **Serializer bytes unchanged** — `fieldsToJson`/`rowsToJson`/`shapeToJson`/`jsonString`/`jsonValue`/`fieldKindValue` UNTOUCHED; `test_compound_writer_parity.py` (Java dumper byte-parity vs Python/ObjC) + `test_canonical_bytes_cross_backend.py` stay green.
- **Reader semantics preserved + more robust** — `fieldsFromJson`/`rowsFromJson`/`shapeFromJson` return the SAME values/types as before for valid input, AND now tolerate whitespace, key reordering, and escaped strings. The row value typing (`parseJsonObject` → Map<String,Object>) must match exactly (textual→String, integral→Long, floating→Double, boolean→Boolean, null→null).
- **No `.tio`/SQLite schema change** — only the in-Java parse of the `shape_json`/`fields_json`/row-JSON columns changes.
- **jacoco BUNDLE line ≥0.84** holds.

**Reference:** OO assessment P2.7; #205 (the whitespace symptom this structurally fixes). File: `java/src/main/java/global/thalion/ttio/providers/SqliteProvider.java`. Parity test: `python/tests/test_compound_writer_parity.py`.

**Verified facts:**
- Reader methods (replace): `fieldsFromJson(String)` (`:457`) → `List<CompoundField>`; `rowsFromJson(String)` (`:475`) → `List<Map<String,Object>>`; `shapeFromJson(String)` (`:487`) → `long[]`. They use the brittle private helpers `splitJsonObjects` (`:548`), `extractJsonString`, `parseJsonObject` (remove these once unused). `fieldKindFromValue` (value→enum, `:543`) is KEPT (not JSON parsing).
- Serializer methods (KEEP, byte-canonical): `fieldsToJson` (`:444`), `rowsToJson`, `shapeToJson` (`:500`), `jsonString` (`:512`), `jsonValue` (`:516`), `fieldKindValue` (`:524`).
- Callers: `shapeFromJson`/`fieldsFromJson` at `:876-877` (compound open), `rowsFromJson` at `:1110` (read rows).
- `jackson-databind:2.17.0` + `jackson-core` + `jackson-annotations` are on the classpath at **compile** scope (transitive via `org.apache.arrow`). The pom has NO direct JSON dependency.
- `test_compound_writer_parity.py` = 1-writer (Python) × 3-dumpers (Py/Java/ObjC) byte-parity, the read-side direction that caught the 303e324 bug; skips gracefully when Java/ObjC tooling isn't built.

---

### Task QT1: Declare Jackson + replace the SqliteProvider JSON reader

**Files:**
- Modify: `java/pom.xml` (add direct jackson-databind dependency)
- Modify: `java/src/main/java/global/thalion/ttio/providers/SqliteProvider.java`
- Test: `java/src/test/java/global/thalion/ttio/providers/SqliteProviderJsonReaderTest.java`

- [ ] **Step 1: Study** `SqliteProvider.java` — the three reader methods + `splitJsonObjects`/`extractJsonString`/`parseJsonObject` (note EXACTLY how `parseJsonObject` types each value: number→Long vs Double, string, boolean, null), the serializers (to NOT touch), and `fieldKindFromValue`. Confirm `jackson-databind:2.17.0` resolves (`JAVA_HOME=~/jdk25 mvn -o dependency:tree | grep jackson`).
- [ ] **Step 2: Write the fence test** `SqliteProviderJsonReaderTest.java`:
  - **Round-trip:** for representative `List<CompoundField>`, `List<Map<String,Object>>` (with String/Long/Double/Boolean/null values + a string containing `,`/`{`/`}`/`"`/escape), and `long[]` shapes — `assertEquals(x, fieldsFromJson(fieldsToJson(x)))` etc. (the serializer→reader round-trip must be identity, with EXACT value types: `instanceof Long`/`Double`).
  - **Robustness (the #205 fix):** feed the reader whitespace-padded JSON (`[ { "name" : "x" , "kind" : "vl_string" } ]`), reordered keys (`{"kind":"int64","name":"y"}`), and escaped strings — assert correct parse. These should FAIL on the current brittle parser for at least the whitespace/reorder cases (confirm the RED), and PASS after Jackson.
  - Use the static package-private reader/serializer methods directly (test is in the same package).
- [ ] **Step 3: Run against current code** — round-trip passes (baseline); the whitespace/reorder robustness cases FAIL (the brittle parser's gap = the RED). `cd ~/TTI-O/java && JAVA_HOME=~/jdk25 mvn -o -Djacoco.skip=true -Dtest=SqliteProviderJsonReaderTest test`
- [ ] **Step 4: Add the Jackson dependency** to `java/pom.xml` (in the `<dependencies>`, matching the existing style):
  ```xml
  <dependency>
      <groupId>com.fasterxml.jackson.core</groupId>
      <artifactId>jackson-databind</artifactId>
      <version>2.17.0</version>
  </dependency>
  ```
  (Pin 2.17.0 = the version already resolved transitively, so no version conflict; this just makes the compile-scope dep direct/stable.)
- [ ] **Step 5: Replace the reader** in `SqliteProvider.java`:
  - A single shared `static final com.fasterxml.jackson.databind.ObjectMapper JSON = new ObjectMapper();`.
  - `fieldsFromJson`: `JsonNode arr = JSON.readTree(json);` iterate the array nodes, `new CompoundField(obj.get("name").asText(), fieldKindFromValue(obj.get("kind").asText()))`. Empty array → empty list.
  - `rowsFromJson`: parse to array; for each object node, build a `LinkedHashMap<String,Object>` mapping each field by JsonNode type EXACTLY as `parseJsonObject` did: `isNull`→null, `isBoolean`→`asBoolean()`(Boolean), `isIntegralNumber`→`asLong()`(Long), `isFloatingPointNumber`/`isDouble`→`asDouble()`(Double), `isTextual`→`asText()`(String). (Match the OLD typing precisely — verify against `parseJsonObject` + `jsonValue` round-trip.)
  - `shapeFromJson`: parse the array; `long[]` via `node.asLong()` per element. Empty → `new long[0]`.
  - Wrap Jackson's checked `JsonProcessingException`/`IOException` in the same exception type the old reader threw (or an `IllegalArgumentException`/the provider's exception) so callers' error contract is unchanged — check what the old methods threw + match.
  - DELETE the now-unused `splitJsonObjects`, `extractJsonString`, `parseJsonObject` (grep to confirm no other caller). KEEP `fieldKindFromValue` + ALL serializers.
- [ ] **Step 6: Run** the fence + the SQLite provider suite:
  `cd ~/TTI-O/java && JAVA_HOME=~/jdk25 mvn -o -Djacoco.skip=true -Dtest='SqliteProviderJsonReaderTest,SqliteProviderTest,*Sqlite*,*Compound*' test` → all green (round-trip + robustness now pass).
- [ ] **Step 7: Commit** `refactor(java-sqlite): replace hand-rolled JSON reader with Jackson (robust parse)`.

---

### Task QT2: Cross-language compound round-trip conformance + regression + CHANGELOG

**Files:**
- Test: extend `python/tests/test_compound_writer_parity.py` OR add a Java-side cross-language read test
- Modify: `CHANGELOG.md`

- [ ] **Step 1: Study** `python/tests/test_compound_writer_parity.py` — how it builds a `.tio` fixture, runs the Java compound dumper, and asserts byte-parity. Determine the cleanest way to add a **round-trip** assertion that exercises the new robust Java reader against non-canonical (whitespace/reordered) JSON that another language could produce.
- [ ] **Step 2: Add the conformance test.** Two viable forms (pick the cleaner given the harness):
  - (a) Extend the Python parity harness with a **read-back round-trip**: Python writes a `.tio.sqlite` compound dataset, the Java SDK reads it (via a small dump/verify tool) and re-emits the rows/fields; assert the Java-read values equal the Python-written values (semantic round-trip, the #205 direction). Skip-guard on Java tooling absence (as the harness already does).
  - (b) If (a) is heavy, a Java-side `CompoundCrossLangReadTest` that parses JSON variants a non-Java writer could legitimately emit (whitespace, key order, both number forms) and asserts the typed values — the robustness that the brittle parser lacked. (Some overlap with QT1's robustness test; make this one explicitly the "cross-language tolerance" conformance fence with a comment tying it to #205.)
  Prefer (a) if a Python-written-sqlite + Java-reader path exists; else (b).
- [ ] **Step 3: Run** the conformance test + the byte-parity fence (serializer unchanged):
  - `cd ~/TTI-O/python && TTIO_RANS_LIB_PATH=$HOME/TTI-O/native/_build/libttio_rans.so .venv/bin/pytest tests/test_compound_writer_parity.py tests/test_canonical_bytes_cross_backend.py -q` (the parity test may skip the Java leg locally if the Java tool isn't built — note it; it runs on CI).
  - Build the Java SDK if the parity test needs the dumper: `cd ~/TTI-O/java && JAVA_HOME=~/jdk25 mvn -o -B install -DskipTests -Djacoco.skip=true`.
- [ ] **Step 4: Java FULL verify (jacoco gate):**
  `cd ~/TTI-O/java && JAVA_HOME=~/jdk25 mvn -o verify -B 2>&1 | tail -15` → BUILD SUCCESS, "All coverage checks have been met" (≥0.84). Replacing ~80 lines of brittle parser with Jackson calls should hold/improve coverage; if it dips, add focused reader tests (real assertions). Do NOT lower the gate.
- [ ] **Step 5: CHANGELOG** under `## [Unreleased]`:
  ```markdown
  ### Changed — Java SqliteProvider JSON reader uses Jackson (Java)

  The Java `SqliteProvider`'s hand-rolled compound-JSON reader (a brittle
  string-splitter that mis-parsed whitespace/reordered keys — the class of bug
  behind #205) is replaced by Jackson (`jackson-databind`, declared as a direct
  dependency; already on the classpath via Arrow). The byte-canonical JSON
  *serializer* is unchanged, so cross-language compound byte-parity is preserved;
  a cross-language compound round-trip conformance test is added. No `.tio`/SQLite
  schema change. (OO-assessment P2.7.)
  ```
- [ ] **Step 6: Commit** `test(java-sqlite): cross-language compound round-trip + changelog (P2.7)`.

---

## Self-review notes (author)
- **Reader-only** — serializer byte-canonical output untouched (the `compound_writer_parity` + `canonical_bytes` tests are the fence). The reader must return identical value TYPES (Long/Double/String/Boolean/null) for valid input AND tolerate whitespace/order/escapes (the #205 fix), verified by QT1's round-trip + robustness fences.
- **Jackson is already on the classpath** (compile scope via Arrow); declaring it direct pins 2.17.0 and removes the transitive-fragility. No new download.
- **jacoco** is the explicit regression (QT2 Step 4).
- Java-only, single PR. No Python/ObjC code change (the conformance test may live on the Python parity harness).
