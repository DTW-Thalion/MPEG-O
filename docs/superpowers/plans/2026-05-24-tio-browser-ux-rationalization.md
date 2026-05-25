# tio-browser UX Rationalization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Re-organise tio-browser around four task-oriented workspaces (Containers, Cohorts, Jobs & Sessions, Transfers) accessed via a left activity rail, with quantitative progress reporting on every long-running operation. See `docs/superpowers/specs/2026-05-24-tio-browser-ux-rationalization-design.md`.

**Architecture:** A new `AppShell` (`BorderPane` with header / rail / centre / transfer strip) hosts four `Workspace` implementations. Workspaces are built once and swapped in the centre region. Long-running operations emit `ProgressReport`s rendered by a shared `ProgressDisplay`.

**Tech Stack:** Java 22, JavaFX 21.0.5, JUnit 5.11, TestFx 4.0.18 + openjfx-monocle (headless), Maven 3.9+.

---

## Prerequisites

- WSL Ubuntu shell at `~/TTI-O`.
- `libhdf5-java` installed; `/usr/share/java/jarhdf5.jar` exists.
- Working branch already created: `feat/tio-browser-ux-rationalization` (the spec was committed here).
- Build commands used throughout:
  - **Install ttio lib to local M2 (run once, re-run if `java/` changes):**
    ```bash
    cd ~/TTI-O/java && mvn -B install -DskipTests -Djacoco.skip=true \
        -Dhdf5.jar=/usr/share/java/jarhdf5.jar
    ```
  - **Run all tio-browser tests:**
    ```bash
    cd ~/TTI-O/tio-browser && mvn -B test \
        -Dhdf5.jar=/usr/share/java/jarhdf5.jar
    ```
  - **Run a single test class:**
    ```bash
    cd ~/TTI-O/tio-browser && mvn -B test -Dtest=ClassName \
        -Dhdf5.jar=/usr/share/java/jarhdf5.jar
    ```
  - **Run a single test method:**
    ```bash
    cd ~/TTI-O/tio-browser && mvn -B test -Dtest=ClassName#methodName \
        -Dhdf5.jar=/usr/share/java/jarhdf5.jar
    ```

---

## File Structure

New package: `global.thalion.ttio.browser.progress` — progress contract and helpers.
New package: `global.thalion.ttio.browser.shell` — shell, rail, header, transfer strip, workspace interface.
New package: `global.thalion.ttio.browser.shell.workspaces` — the four `Workspace` implementations.
New package: `global.thalion.ttio.browser.shell.containers` — unified container tree + node hierarchy (stage 6).

Each new class lives in its own file. The existing `view.*`, `model.*`, `workbench.*`, `transport.*`, `importers.*`, `exporters.*`, `diag.*`, `util.*` packages keep their existing content; classes are deleted or modified per the spec §9.3.

---

# Stage 0 — Progress Infrastructure (additive)

Goal: ship `ProgressReport`, `ProgressTracker`, `Units`, `ProgressFormatter`, `ProgressDisplay`, `ProgressListener` with full unit coverage. No UI changes yet.

### Task 0.1: `ProgressReport` record + `ProgressListener` interface

**Files:**
- Create: `tio-browser/src/main/java/global/thalion/ttio/browser/progress/ProgressReport.java`
- Create: `tio-browser/src/main/java/global/thalion/ttio/browser/progress/ProgressListener.java`
- Create: `tio-browser/src/test/java/global/thalion/ttio/browser/progress/ProgressReportTest.java`

- [ ] **Step 1: Write the failing test**

`ProgressReportTest.java`:
```java
package global.thalion.ttio.browser.progress;

import org.junit.jupiter.api.Test;
import static org.junit.jupiter.api.Assertions.*;

class ProgressReportTest {

    @Test
    void determinateWhenBytesTotalKnown() {
        ProgressReport r = new ProgressReport("uploading",
            500, 1000, -1, -1, 100.0, Double.NaN, 5, 5, 0L);
        assertTrue(r.isDeterminate());
        assertEquals(0.5, r.percent(), 1e-9);
    }

    @Test
    void determinateWhenUnitsTotalKnownEvenWithoutBytes() {
        ProgressReport r = new ProgressReport("encoding",
            -1, -1, 250, 1000, Double.NaN, 50.0, 15, 5, 0L);
        assertTrue(r.isDeterminate());
        assertEquals(0.25, r.percent(), 1e-9);
    }

    @Test
    void indeterminateWhenNeitherTotalKnown() {
        ProgressReport r = new ProgressReport("streaming",
            500, -1, -1, -1, 100.0, Double.NaN, -1, 5, 0L);
        assertFalse(r.isDeterminate());
        assertTrue(Double.isNaN(r.percent()));
    }

    @Test
    void stalledWhenRateLowAndQuietForOverTenSeconds() {
        long now = 1_000_000L;
        ProgressReport r = new ProgressReport("uploading",
            500, 1000, -1, -1, 50.0, Double.NaN, -1, 60, now - 11_000L);
        assertTrue(r.isStalled(now));
    }

    @Test
    void notStalledWhenRateAdequate() {
        long now = 1_000_000L;
        ProgressReport r = new ProgressReport("uploading",
            500, 1000, -1, -1, 5000.0, Double.NaN, 5, 60, now - 11_000L);
        assertFalse(r.isStalled(now));
    }

    @Test
    void notStalledWhenRecentActivity() {
        long now = 1_000_000L;
        ProgressReport r = new ProgressReport("uploading",
            500, 1000, -1, -1, 0.0, Double.NaN, -1, 60, now - 5_000L);
        assertFalse(r.isStalled(now));
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd ~/TTI-O/tio-browser && mvn -B test \
    -Dtest=ProgressReportTest -Dhdf5.jar=/usr/share/java/jarhdf5.jar
```
Expected: **COMPILATION FAILURE** — `ProgressReport` does not exist.

- [ ] **Step 3: Write the implementation**

`ProgressListener.java`:
```java
package global.thalion.ttio.browser.progress;

@FunctionalInterface
public interface ProgressListener {
    void onProgress(ProgressReport report);
}
```

`ProgressReport.java`:
```java
package global.thalion.ttio.browser.progress;

/** Immutable snapshot of a long-running operation's progress. */
public record ProgressReport(
    String phase,
    long bytesDone,
    long bytesTotal,
    long unitsDone,
    long unitsTotal,
    double rateBytesPerSec,
    double rateUnitsPerSec,
    long etaSeconds,
    long elapsedSeconds,
    long lastActivityEpochMs
) {
    public boolean isDeterminate() {
        return bytesTotal > 0 || unitsTotal > 0;
    }

    public boolean isStalled(long nowEpochMs) {
        return rateBytesPerSec < 100.0
            && (nowEpochMs - lastActivityEpochMs) > 10_000L;
    }

    public double percent() {
        if (bytesTotal > 0) return (double) bytesDone / (double) bytesTotal;
        if (unitsTotal > 0) return (double) unitsDone / (double) unitsTotal;
        return Double.NaN;
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
cd ~/TTI-O/tio-browser && mvn -B test \
    -Dtest=ProgressReportTest -Dhdf5.jar=/usr/share/java/jarhdf5.jar
```
Expected: **BUILD SUCCESS** with all 6 tests passing.

- [ ] **Step 5: Commit**

```bash
cd ~/TTI-O
git add tio-browser/src/main/java/global/thalion/ttio/browser/progress/ProgressReport.java \
        tio-browser/src/main/java/global/thalion/ttio/browser/progress/ProgressListener.java \
        tio-browser/src/test/java/global/thalion/ttio/browser/progress/ProgressReportTest.java
git commit -m "feat(tio-browser/progress): ProgressReport record + ProgressListener interface"
```

### Task 0.2: `ProgressTracker` — 5-second EWMA sampler

**Files:**
- Create: `tio-browser/src/main/java/global/thalion/ttio/browser/progress/ProgressTracker.java`
- Create: `tio-browser/src/test/java/global/thalion/ttio/browser/progress/ProgressTrackerTest.java`

- [ ] **Step 1: Write the failing test**

`ProgressTrackerTest.java`:
```java
package global.thalion.ttio.browser.progress;

import org.junit.jupiter.api.Test;
import static org.junit.jupiter.api.Assertions.*;

class ProgressTrackerTest {

    @Test
    void firstSampleProducesReportWithoutRate() {
        ProgressTracker t = new ProgressTracker(
            "uploading", /*bytesTotal=*/1000L, /*unitsTotal=*/-1L, /*epochMs=*/0L);
        ProgressReport r = t.sample(/*bytesDone=*/100L, /*unitsDone=*/0L, /*epochMs=*/0L);
        assertEquals("uploading", r.phase());
        assertEquals(100L, r.bytesDone());
        assertTrue(Double.isNaN(r.rateBytesPerSec()),
            "rate is NaN until the EWMA window has ≥2 samples");
        assertEquals(-1L, r.etaSeconds(),
            "ETA hidden until rate is computable");
    }

    @Test
    void secondSampleAfterOneSecondProducesRateAndEta() {
        ProgressTracker t = new ProgressTracker(
            "uploading", /*bytesTotal=*/1000L, /*unitsTotal=*/-1L, /*epochMs=*/0L);
        t.sample(0L, 0L, 0L);
        ProgressReport r = t.sample(200L, 0L, 1000L);
        assertEquals(200.0, r.rateBytesPerSec(), 1e-6);
        // remaining = 800 bytes / 200 B/s = 4s
        assertEquals(4L, r.etaSeconds());
        assertEquals(1L, r.elapsedSeconds());
    }

    @Test
    void slidingWindowDropsSamplesOlderThanFiveSeconds() {
        ProgressTracker t = new ProgressTracker(
            "uploading", 10_000L, -1L, 0L);
        // sample at t=0, t=1s, t=6s, t=7s -> t=0 sample falls out
        t.sample(0L, 0L, 0L);
        t.sample(1000L, 0L, 1000L);
        t.sample(6000L, 0L, 6000L);
        ProgressReport r = t.sample(7000L, 0L, 7000L);
        // Within window: samples from t=2s..7s. Rate is computed over
        // the in-window span. Verify rate is positive and sensible.
        assertTrue(r.rateBytesPerSec() > 0.0,
            "rate should be positive after window slides");
    }

    @Test
    void lastActivityTimestampUpdatesOnEveryNonZeroDelta() {
        ProgressTracker t = new ProgressTracker(
            "uploading", 1000L, -1L, 0L);
        t.sample(0L, 0L, 0L);
        t.sample(100L, 0L, 500L);
        ProgressReport r = t.sample(100L, 0L, 2000L); // no delta
        assertEquals(500L, r.lastActivityEpochMs(),
            "lastActivity stays at last non-zero-delta sample time");
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd ~/TTI-O/tio-browser && mvn -B test \
    -Dtest=ProgressTrackerTest -Dhdf5.jar=/usr/share/java/jarhdf5.jar
```
Expected: **COMPILATION FAILURE** — `ProgressTracker` does not exist.

- [ ] **Step 3: Write the implementation**

`ProgressTracker.java`:
```java
package global.thalion.ttio.browser.progress;

import java.util.ArrayDeque;
import java.util.Deque;

/**
 * Aggregates raw (bytesDone, unitsDone, epochMs) samples into a
 * {@link ProgressReport}. Rate is a sliding 5-second window mean,
 * computed over samples whose timestamps lie within the window. ETA
 * is derived from rate and remaining bytes (or units). lastActivity
 * tracks the latest non-zero-delta sample.
 */
public final class ProgressTracker {
    private static final long WINDOW_MS = 5_000L;

    private final String phase;
    private final long bytesTotal;
    private final long unitsTotal;
    private final long startEpochMs;
    private final Deque<Sample> window = new ArrayDeque<>();
    private long lastActivityEpochMs;
    private long lastBytesDone = 0L;
    private long lastUnitsDone = 0L;

    private record Sample(long epochMs, long bytesDone, long unitsDone) {}

    public ProgressTracker(String phase, long bytesTotal,
                           long unitsTotal, long startEpochMs) {
        this.phase = phase;
        this.bytesTotal = bytesTotal;
        this.unitsTotal = unitsTotal;
        this.startEpochMs = startEpochMs;
        this.lastActivityEpochMs = startEpochMs;
    }

    public ProgressReport sample(long bytesDone, long unitsDone,
                                  long epochMs) {
        if (bytesDone != lastBytesDone || unitsDone != lastUnitsDone) {
            lastActivityEpochMs = epochMs;
            lastBytesDone = bytesDone;
            lastUnitsDone = unitsDone;
        }
        window.addLast(new Sample(epochMs, bytesDone, unitsDone));
        long cutoff = epochMs - WINDOW_MS;
        while (window.size() > 1 && window.peekFirst().epochMs() < cutoff) {
            window.removeFirst();
        }

        double rateBytes = Double.NaN;
        double rateUnits = Double.NaN;
        long eta = -1L;
        if (window.size() >= 2) {
            Sample first = window.peekFirst();
            Sample last = window.peekLast();
            double dtSec = (last.epochMs() - first.epochMs()) / 1000.0;
            if (dtSec > 0.0) {
                rateBytes = (last.bytesDone() - first.bytesDone()) / dtSec;
                rateUnits = (last.unitsDone() - first.unitsDone()) / dtSec;
                if (bytesTotal > 0 && rateBytes > 0) {
                    long remaining = bytesTotal - bytesDone;
                    eta = Math.max(0L, (long) (remaining / rateBytes));
                } else if (unitsTotal > 0 && rateUnits > 0) {
                    long remaining = unitsTotal - unitsDone;
                    eta = Math.max(0L, (long) (remaining / rateUnits));
                }
            }
        }
        long elapsedSec = (epochMs - startEpochMs) / 1000L;
        return new ProgressReport(phase, bytesDone, bytesTotal,
            unitsDone, unitsTotal, rateBytes, rateUnits, eta,
            elapsedSec, lastActivityEpochMs);
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
cd ~/TTI-O/tio-browser && mvn -B test \
    -Dtest=ProgressTrackerTest -Dhdf5.jar=/usr/share/java/jarhdf5.jar
```
Expected: **BUILD SUCCESS** with all 4 tests passing.

- [ ] **Step 5: Commit**

```bash
cd ~/TTI-O
git add tio-browser/src/main/java/global/thalion/ttio/browser/progress/ProgressTracker.java \
        tio-browser/src/test/java/global/thalion/ttio/browser/progress/ProgressTrackerTest.java
git commit -m "feat(tio-browser/progress): ProgressTracker with 5-sec EWMA rate"
```

### Task 0.3: `Units` formatter helpers

**Files:**
- Create: `tio-browser/src/main/java/global/thalion/ttio/browser/util/Units.java`
- Create: `tio-browser/src/test/java/global/thalion/ttio/browser/util/UnitsTest.java`

- [ ] **Step 1: Write the failing test**

`UnitsTest.java`:
```java
package global.thalion.ttio.browser.util;

import org.junit.jupiter.api.Test;
import static org.junit.jupiter.api.Assertions.*;

class UnitsTest {

    @Test
    void humanBytesScales() {
        assertEquals("0 B", Units.humanBytes(0L));
        assertEquals("512 B", Units.humanBytes(512L));
        assertEquals("1.0 KB", Units.humanBytes(1024L));
        assertEquals("1.5 KB", Units.humanBytes(1536L));
        assertEquals("1.2 MB", Units.humanBytes(1_258_291L));
        assertEquals("2.8 GB", Units.humanBytes(3_006_477_107L));
        assertEquals("1.0 TB", Units.humanBytes(1_099_511_627_776L));
    }

    @Test
    void humanRateAppendsPerSecond() {
        assertEquals("18.4 MB/s", Units.humanRate(19_293_798.4));
        assertEquals("312 B/s", Units.humanRate(312.0));
    }

    @Test
    void humanDurationHumanizesSeconds() {
        assertEquals("0s", Units.humanDuration(0L));
        assertEquals("23s", Units.humanDuration(23L));
        assertEquals("1m 27s", Units.humanDuration(87L));
        assertEquals("2h 5m", Units.humanDuration(7500L));
        assertEquals("1d 3h", Units.humanDuration(97_200L));
    }

    @Test
    void humanCountFormatsWithThousandsSeparator() {
        assertEquals("0", Units.humanCount(0L));
        assertEquals("1,247", Units.humanCount(1247L));
        assertEquals("8,420", Units.humanCount(8420L));
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd ~/TTI-O/tio-browser && mvn -B test \
    -Dtest=UnitsTest -Dhdf5.jar=/usr/share/java/jarhdf5.jar
```
Expected: **COMPILATION FAILURE**.

- [ ] **Step 3: Write the implementation**

`Units.java`:
```java
package global.thalion.ttio.browser.util;

import java.util.Locale;

public final class Units {
    private Units() {}

    private static final String[] BYTE_UNITS = {"B", "KB", "MB", "GB", "TB", "PB"};

    public static String humanBytes(long bytes) {
        if (bytes < 1024L) return bytes + " B";
        double v = bytes;
        int i = 0;
        while (v >= 1024.0 && i < BYTE_UNITS.length - 1) {
            v /= 1024.0;
            i++;
        }
        return String.format(Locale.ROOT, "%.1f %s", v, BYTE_UNITS[i]);
    }

    public static String humanRate(double bytesPerSec) {
        if (bytesPerSec < 1024.0) {
            return String.format(Locale.ROOT, "%.0f B/s", bytesPerSec);
        }
        double v = bytesPerSec;
        int i = 0;
        while (v >= 1024.0 && i < BYTE_UNITS.length - 1) {
            v /= 1024.0;
            i++;
        }
        return String.format(Locale.ROOT, "%.1f %s/s", v, BYTE_UNITS[i]);
    }

    public static String humanDuration(long seconds) {
        if (seconds < 60L) return seconds + "s";
        long m = seconds / 60L;
        long s = seconds % 60L;
        if (m < 60L) return m + "m " + s + "s";
        long h = m / 60L;
        m = m % 60L;
        if (h < 24L) return h + "h " + m + "m";
        long d = h / 24L;
        h = h % 24L;
        return d + "d " + h + "h";
    }

    public static String humanCount(long n) {
        return String.format(Locale.ROOT, "%,d", n);
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
cd ~/TTI-O/tio-browser && mvn -B test \
    -Dtest=UnitsTest -Dhdf5.jar=/usr/share/java/jarhdf5.jar
```
Expected: **BUILD SUCCESS**.

- [ ] **Step 5: Commit**

```bash
cd ~/TTI-O
git add tio-browser/src/main/java/global/thalion/ttio/browser/util/Units.java \
        tio-browser/src/test/java/global/thalion/ttio/browser/util/UnitsTest.java
git commit -m "feat(tio-browser/util): Units helpers (humanBytes/Rate/Duration/Count)"
```

### Task 0.4: `ProgressFormatter.line(report)`

**Files:**
- Create: `tio-browser/src/main/java/global/thalion/ttio/browser/progress/ProgressFormatter.java`
- Create: `tio-browser/src/test/java/global/thalion/ttio/browser/progress/ProgressFormatterTest.java`

- [ ] **Step 1: Write the failing test**

`ProgressFormatterTest.java`:
```java
package global.thalion.ttio.browser.progress;

import org.junit.jupiter.api.Test;
import static org.junit.jupiter.api.Assertions.*;

class ProgressFormatterTest {

    private static final long NOW = 1_000_000L;

    @Test
    void bytesKnownUnitsNa() {
        ProgressReport r = new ProgressReport("uploading",
            1_258_291L, 3_006_477_107L, -1L, -1L,
            19_293_798.4, Double.NaN, 87L, 5L, NOW);
        assertEquals(
            "42.0% · 1.2 MB / 2.8 GB · 18.4 MB/s · ETA 1m 27s",
            ProgressFormatter.line(r, NOW));
    }

    @Test
    void unitsKnownBytesNa() {
        ProgressReport r = new ProgressReport("encoding",
            -1L, -1L, 1247L, 8420L,
            Double.NaN, 312.0, 23L, 4L, NOW);
        assertEquals(
            "1,247 / 8,420 AUs · 312 AU/s · ETA 23s",
            ProgressFormatter.line(r, NOW));
    }

    @Test
    void neitherTotalKnownShowsBytesProcessed() {
        ProgressReport r = new ProgressReport("streaming",
            1_258_291L, -1L, -1L, -1L,
            19_293_798.4, Double.NaN, -1L, 72L, NOW);
        assertEquals(
            "1.2 MB processed · 18.4 MB/s · elapsed 1m 12s",
            ProgressFormatter.line(r, NOW));
    }

    @Test
    void stalledHidesRateAndShowsLastActivity() {
        ProgressReport r = new ProgressReport("uploading",
            500L, 1000L, -1L, -1L,
            50.0, Double.NaN, -1L, 60L, NOW - 12_000L);
        assertEquals(
            "stalled — last activity 12s ago",
            ProgressFormatter.line(r, NOW));
    }

    @Test
    void rateNanShowsBareBytesProcessed() {
        ProgressReport r = new ProgressReport("uploading",
            500L, 1000L, -1L, -1L,
            Double.NaN, Double.NaN, -1L, 0L, NOW);
        assertEquals(
            "50.0% · 500 B / 1000 B · measuring rate…",
            ProgressFormatter.line(r, NOW));
    }
}
```

(Note: 0x00b7 is the middle-dot `·`; 0x2014 is em-dash `—`; 0x2026 is ellipsis `…`. Using the escape form keeps the source ASCII-clean.)

- [ ] **Step 2: Run test to verify it fails**

```bash
cd ~/TTI-O/tio-browser && mvn -B test \
    -Dtest=ProgressFormatterTest -Dhdf5.jar=/usr/share/java/jarhdf5.jar
```
Expected: **COMPILATION FAILURE**.

- [ ] **Step 3: Write the implementation**

`ProgressFormatter.java`:
```java
package global.thalion.ttio.browser.progress;

import global.thalion.ttio.browser.util.Units;

import java.util.Locale;

public final class ProgressFormatter {
    private ProgressFormatter() {}

    private static final String DOT  = "·";
    private static final String DASH = "—";
    private static final String ELL  = "…";

    public static String line(ProgressReport r, long nowEpochMs) {
        if (r.isStalled(nowEpochMs)) {
            long quietSec = (nowEpochMs - r.lastActivityEpochMs()) / 1000L;
            return "stalled " + DASH + " last activity "
                + Units.humanDuration(quietSec) + " ago";
        }

        boolean haveBytesTotal = r.bytesTotal() > 0L;
        boolean haveUnitsTotal = r.unitsTotal() > 0L;
        boolean haveAnyTotal   = haveBytesTotal || haveUnitsTotal;

        StringBuilder sb = new StringBuilder();
        if (haveAnyTotal) {
            sb.append(String.format(Locale.ROOT, "%.1f%%",
                r.percent() * 100.0));
            sb.append(' ').append(DOT).append(' ');
            if (haveBytesTotal && haveUnitsTotal) {
                sb.append(rawBytesPair(r)).append(' ').append(DOT).append(' ')
                  .append(Units.humanCount(r.unitsDone())).append(" AUs");
            } else if (haveBytesTotal) {
                sb.append(rawBytesPair(r));
            } else {
                sb.append(Units.humanCount(r.unitsDone()))
                  .append(" / ")
                  .append(Units.humanCount(r.unitsTotal()))
                  .append(" AUs");
            }
        } else {
            sb.append(Units.humanBytes(r.bytesDone())).append(" processed");
        }

        sb.append(' ').append(DOT).append(' ');
        if (Double.isNaN(r.rateBytesPerSec()) && Double.isNaN(r.rateUnitsPerSec())) {
            sb.append("measuring rate").append(ELL);
        } else if (haveUnitsTotal && !haveBytesTotal) {
            sb.append(String.format(Locale.ROOT, "%.0f AU/s",
                r.rateUnitsPerSec()));
        } else {
            sb.append(Units.humanRate(r.rateBytesPerSec()));
        }

        if (r.etaSeconds() >= 0L) {
            sb.append(' ').append(DOT).append(' ');
            sb.append("ETA ").append(Units.humanDuration(r.etaSeconds()));
        } else if (!haveAnyTotal) {
            sb.append(' ').append(DOT).append(' ');
            sb.append("elapsed ").append(Units.humanDuration(r.elapsedSeconds()));
        }

        return sb.toString();
    }

    private static String rawBytesPair(ProgressReport r) {
        // Format both numerator and denominator with the *same* unit
        // (the one of the denominator), so "1.2 MB / 2.8 GB" is not
        // produced — instead we match the spec example: numerator
        // and denominator may use different units when natural.
        return Units.humanBytes(r.bytesDone()) + " / "
             + Units.humanBytes(r.bytesTotal());
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
cd ~/TTI-O/tio-browser && mvn -B test \
    -Dtest=ProgressFormatterTest -Dhdf5.jar=/usr/share/java/jarhdf5.jar
```
Expected: **BUILD SUCCESS**.

- [ ] **Step 5: Commit**

```bash
cd ~/TTI-O
git add tio-browser/src/main/java/global/thalion/ttio/browser/progress/ProgressFormatter.java \
        tio-browser/src/test/java/global/thalion/ttio/browser/progress/ProgressFormatterTest.java
git commit -m "feat(tio-browser/progress): ProgressFormatter.line for numeric progress text"
```

### Task 0.5: `ProgressDisplay` JavaFX component

**Files:**
- Create: `tio-browser/src/main/java/global/thalion/ttio/browser/progress/ProgressDisplay.java`
- Create: `tio-browser/src/test/java/global/thalion/ttio/browser/progress/ProgressDisplayTest.java`

- [ ] **Step 1: Write the failing test**

`ProgressDisplayTest.java`:
```java
package global.thalion.ttio.browser.progress;

import javafx.scene.Scene;
import javafx.scene.layout.StackPane;
import javafx.stage.Stage;
import org.junit.jupiter.api.Test;
import org.testfx.framework.junit5.ApplicationTest;
import static org.junit.jupiter.api.Assertions.*;

class ProgressDisplayTest extends ApplicationTest {

    private ProgressDisplay display;
    private static final long NOW = 1_000_000L;

    @Override
    public void start(Stage stage) {
        display = new ProgressDisplay();
        stage.setScene(new Scene(new StackPane(display.node()), 400, 80));
        stage.show();
    }

    @Test
    void updateDeterminateSetsBarAndLabel() {
        interact(() -> display.update(new ProgressReport("uploading",
            500L, 1000L, -1L, -1L,
            100.0, Double.NaN, 5L, 5L, NOW), NOW));
        assertEquals(0.5, display.progressBar().getProgress(), 1e-9);
        assertEquals(
            "50.0% · 500 B / 1000 B · 100 B/s · ETA 5s",
            display.label().getText());
    }

    @Test
    void updateIndeterminateSetsBarToIndeterminateState() {
        interact(() -> display.update(new ProgressReport("streaming",
            500L, -1L, -1L, -1L,
            100.0, Double.NaN, -1L, 5L, NOW), NOW));
        assertEquals(-1.0, display.progressBar().getProgress(), 1e-9,
            "JavaFX uses -1 for indeterminate");
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd ~/TTI-O/tio-browser && mvn -B test \
    -Dtest=ProgressDisplayTest -Dhdf5.jar=/usr/share/java/jarhdf5.jar
```
Expected: **COMPILATION FAILURE**.

- [ ] **Step 3: Write the implementation**

`ProgressDisplay.java`:
```java
package global.thalion.ttio.browser.progress;

import javafx.scene.control.Label;
import javafx.scene.control.ProgressBar;
import javafx.scene.layout.VBox;

/**
 * Reusable progress bar + numeric line. Update by calling
 * {@link #update(ProgressReport, long)} on the JavaFX application
 * thread (callers running off-thread must wrap with
 * {@code Platform.runLater(...)}).
 */
public final class ProgressDisplay {

    private final ProgressBar bar = new ProgressBar(0.0);
    private final Label numericLine = new Label("");
    private final VBox root = new VBox(4, bar, numericLine);

    public ProgressDisplay() {
        bar.setMaxWidth(Double.MAX_VALUE);
        numericLine.getStyleClass().add("progress-numeric-line");
    }

    public VBox node() { return root; }

    public ProgressBar progressBar() { return bar; }

    public Label label() { return numericLine; }

    public void update(ProgressReport r, long nowEpochMs) {
        if (r.isDeterminate()) {
            bar.setProgress(r.percent());
        } else {
            bar.setProgress(-1.0); // indeterminate
        }
        numericLine.setText(ProgressFormatter.line(r, nowEpochMs));
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
cd ~/TTI-O/tio-browser && mvn -B test \
    -Dtest=ProgressDisplayTest -Dhdf5.jar=/usr/share/java/jarhdf5.jar
```
Expected: **BUILD SUCCESS**.

- [ ] **Step 5: Commit**

```bash
cd ~/TTI-O
git add tio-browser/src/main/java/global/thalion/ttio/browser/progress/ProgressDisplay.java \
        tio-browser/src/test/java/global/thalion/ttio/browser/progress/ProgressDisplayTest.java
git commit -m "feat(tio-browser/progress): ProgressDisplay reusable bar + label component"
```

### Task 0.6: Stage 0 regression gate

- [ ] **Step 1: Run the full tio-browser test suite**

```bash
cd ~/TTI-O/tio-browser && mvn -B test \
    -Dhdf5.jar=/usr/share/java/jarhdf5.jar
```
Expected: **BUILD SUCCESS**. No prior test regressed (Stage 0 is purely additive).

- [ ] **Step 2: Tag the stage boundary in git**

```bash
cd ~/TTI-O
git tag stage-0-progress-infrastructure
```

---

# Stage 1 — Wire `ProgressReport` Through Existing Producers

Goal: every long-running operation that previously called `Task.updateProgress(done, total)` now also feeds a `ProgressTracker` and exposes a `ProgressListener` setter. UI display sites are unchanged in this stage — we add the producer side first, then Stage 2+ consumes it.

For each producer, the pattern is:

1. Add a private `ProgressTracker tracker` field initialized in the worker constructor (when known) or lazily in `call()` (when the total is discovered then).
2. Add a `public void setProgressListener(ProgressListener l)` setter.
3. In the existing progress-emit point, also call `tracker.sample(...)` and pass the returned `ProgressReport` to the listener via `Platform.runLater(() -> listener.onProgress(r))` (or directly when already on the FX thread).
4. Test: instantiate the task, attach a recording listener, run it against a small in-memory fixture, assert that at least one `ProgressReport` with `bytesDone > 0` (or `unitsDone > 0`) was delivered.

### Task 1.1: `DatasetOpenTask`

**Files:**
- Modify: `tio-browser/src/main/java/global/thalion/ttio/browser/model/DatasetOpenTask.java`
- Modify: `tio-browser/src/test/java/global/thalion/ttio/browser/model/DatasetOpenTaskTest.java`

- [ ] **Step 1: Read the current task to find the I/O point**

```bash
cd ~/TTI-O && cat tio-browser/src/main/java/global/thalion/ttio/browser/model/DatasetOpenTask.java
```

Note where the HDF5 file is opened and read; this is the point to emit progress. If the open is a single blocking call, emit once at start (`unitsDone=0`, `unitsTotal=1`) and once at end (`unitsDone=1, unitsTotal=1`); this still gives the user a "starting / done" signal even without per-byte detail.

- [ ] **Step 2: Write the failing test**

Append to `DatasetOpenTaskTest.java`:
```java
@Test
void emitsProgressReportsToListener() throws Exception {
    // Existing fixture path used by other DatasetOpenTask tests.
    String fixture = TestFixtures.SMALL_MS_DATASET; // adjust to actual constant
    DatasetOpenTask task = new DatasetOpenTask(fixture, /*readOnly=*/true);
    java.util.List<global.thalion.ttio.browser.progress.ProgressReport> got =
        new java.util.concurrent.CopyOnWriteArrayList<>();
    task.setProgressListener(got::add);
    task.run();
    OpenDataset result = task.get();
    assertNotNull(result);
    result.close();
    assertFalse(got.isEmpty(),
        "task should emit at least one ProgressReport");
    assertTrue(got.stream().anyMatch(r -> r.unitsDone() >= 1),
        "should emit a terminal report with unitsDone >= 1");
}
```

If `TestFixtures.SMALL_MS_DATASET` does not exist, find any fixture path used elsewhere in the test (e.g. `DatasetTreeBuilderTest`) and reuse it.

- [ ] **Step 3: Run test to verify it fails**

```bash
cd ~/TTI-O/tio-browser && mvn -B test \
    -Dtest=DatasetOpenTaskTest#emitsProgressReportsToListener \
    -Dhdf5.jar=/usr/share/java/jarhdf5.jar
```
Expected: **COMPILATION FAILURE** — `setProgressListener` is undefined.

- [ ] **Step 4: Add the listener plumbing**

In `DatasetOpenTask.java`, add:
```java
private volatile global.thalion.ttio.browser.progress.ProgressListener progressListener;

public void setProgressListener(
        global.thalion.ttio.browser.progress.ProgressListener l) {
    this.progressListener = l;
}

private void emit(long done, long total) {
    var l = progressListener;
    if (l == null) return;
    if (tracker == null) {
        tracker = new global.thalion.ttio.browser.progress.ProgressTracker(
            "opening", -1L, total, System.currentTimeMillis());
    }
    var r = tracker.sample(0L, done, System.currentTimeMillis());
    l.onProgress(r);
}

private global.thalion.ttio.browser.progress.ProgressTracker tracker;
```

Inside the existing `call()` body, add `emit(0, 1)` at the very start (after any pre-flight) and `emit(1, 1)` immediately before `return result;` (or wherever the task succeeds).

- [ ] **Step 5: Run test to verify it passes**

```bash
cd ~/TTI-O/tio-browser && mvn -B test \
    -Dtest=DatasetOpenTaskTest \
    -Dhdf5.jar=/usr/share/java/jarhdf5.jar
```
Expected: **BUILD SUCCESS** with all tests in the class passing.

- [ ] **Step 6: Commit**

```bash
cd ~/TTI-O
git add tio-browser/src/main/java/global/thalion/ttio/browser/model/DatasetOpenTask.java \
        tio-browser/src/test/java/global/thalion/ttio/browser/model/DatasetOpenTaskTest.java
git commit -m "feat(tio-browser/model): DatasetOpenTask emits ProgressReport to optional listener"
```

### Task 1.2: `transport.UploadTask`

**Files:**
- Modify: `tio-browser/src/main/java/global/thalion/ttio/browser/transport/UploadTask.java`
- Modify: `tio-browser/src/test/java/global/thalion/ttio/browser/transport/UploadTaskTest.java`

- [ ] **Step 1: Locate the per-packet emit point**

```bash
cd ~/TTI-O && grep -n "updateProgress\|bytesSent\|bytesWritten" \
    tio-browser/src/main/java/global/thalion/ttio/browser/transport/UploadTask.java
```
The existing `updateProgress(bytesSent, totalBytes)` (or equivalent) call sites are where the new `tracker.sample()` call goes.

- [ ] **Step 2: Write the failing test**

In `UploadTaskTest.java`, add (using the same fixture style as the existing `verifies the upload succeeds against an in-memory sink` test):
```java
@Test
void emitsProgressReportsDuringUpload() throws Exception {
    // Reuse the existing in-memory sink fixture pattern.
    UploadTask task = newSmallUploadTask();   // existing helper in this test
    var got = new java.util.concurrent.CopyOnWriteArrayList<
        global.thalion.ttio.browser.progress.ProgressReport>();
    task.setProgressListener(got::add);
    task.run();
    assertTrue(got.size() >= 2,
        "should emit start + at least one mid-stream report");
    var last = got.get(got.size() - 1);
    assertTrue(last.bytesDone() > 0L);
    assertTrue(last.bytesTotal() > 0L,
        "byte total should be known for a file-source upload");
}
```

If `newSmallUploadTask()` doesn't exist, extract whatever existing test fixture sets up an in-memory upload (search for `UploadTask(` constructions in the test).

- [ ] **Step 3: Run test to verify it fails**

```bash
cd ~/TTI-O/tio-browser && mvn -B test \
    -Dtest=UploadTaskTest#emitsProgressReportsDuringUpload \
    -Dhdf5.jar=/usr/share/java/jarhdf5.jar
```
Expected: **COMPILATION FAILURE**.

- [ ] **Step 4: Add the listener plumbing**

Same pattern as Task 1.1:
```java
private volatile global.thalion.ttio.browser.progress.ProgressListener progressListener;
private global.thalion.ttio.browser.progress.ProgressTracker tracker;

public void setProgressListener(
        global.thalion.ttio.browser.progress.ProgressListener l) {
    this.progressListener = l;
}

private void emitBytes(long done, long total) {
    var l = progressListener;
    if (l == null) return;
    if (tracker == null) {
        tracker = new global.thalion.ttio.browser.progress.ProgressTracker(
            "uploading", total, -1L, System.currentTimeMillis());
    }
    var r = tracker.sample(done, 0L, System.currentTimeMillis());
    l.onProgress(r);
}
```

Where the existing `updateProgress(done, total)` is called, add `emitBytes(done, total);` on the next line.

- [ ] **Step 5: Run test to verify it passes**

```bash
cd ~/TTI-O/tio-browser && mvn -B test \
    -Dtest=UploadTaskTest \
    -Dhdf5.jar=/usr/share/java/jarhdf5.jar
```
Expected: **BUILD SUCCESS**.

- [ ] **Step 6: Commit**

```bash
cd ~/TTI-O
git add tio-browser/src/main/java/global/thalion/ttio/browser/transport/UploadTask.java \
        tio-browser/src/test/java/global/thalion/ttio/browser/transport/UploadTaskTest.java
git commit -m "feat(tio-browser/transport): UploadTask emits ProgressReport to optional listener"
```

### Task 1.3: `transport.DownloadTask`

Apply the **same pattern as Task 1.2** to `DownloadTask`:
- phase = `"downloading"`.
- Modify: `tio-browser/src/main/java/global/thalion/ttio/browser/transport/DownloadTask.java`
- Modify: `tio-browser/src/test/java/global/thalion/ttio/browser/transport/DownloadTaskTest.java`
- New test name: `emitsProgressReportsDuringDownload`.
- Commit message: `feat(tio-browser/transport): DownloadTask emits ProgressReport to optional listener`.

Steps mirror Task 1.2 step-for-step.

### Task 1.4: `importers.ImportTask`

Apply the **same pattern**:
- phase = `"importing"`.
- Modify: `tio-browser/src/main/java/global/thalion/ttio/browser/importers/ImportTask.java`
- Modify: `tio-browser/src/test/java/global/thalion/ttio/browser/importers/ImportTaskTest.java`
- New test name: `emitsProgressReportsDuringImport`.
- For format-aware tasks where total bytes are unknown (e.g. streaming formats), pass `bytesTotal = -1` to the tracker; the report will be indeterminate but still carry `bytesDone`.
- Commit message: `feat(tio-browser/importers): ImportTask emits ProgressReport to optional listener`.

### Task 1.5: `exporters.ExportTask`

Apply the **same pattern**:
- phase = `"exporting"`.
- Modify: `tio-browser/src/main/java/global/thalion/ttio/browser/exporters/ExportTask.java`
- Modify: `tio-browser/src/test/java/global/thalion/ttio/browser/exporters/ExportTaskTest.java`
- New test name: `emitsProgressReportsDuringExport`.
- Commit message: `feat(tio-browser/exporters): ExportTask emits ProgressReport to optional listener`.

### Task 1.6: `workbench.EncodingPanel` encode worker

EncodingPanel has its own background-thread encode loop. Apply the listener plumbing pattern:
- Modify: `tio-browser/src/main/java/global/thalion/ttio/browser/workbench/EncodingPanel.java`
- Modify: `tio-browser/src/test/java/global/thalion/ttio/browser/workbench/EncodingPanelTest.java`
- phase = `"encoding"`.
- The current encode thread should hold a `ProgressTracker`. Expose `setProgressListener` on the panel; the panel uses it to update its own `ProgressDisplay` (introduced in step 7) **and** forward to any external listener.

- [ ] **Step a: Read current panel to find the worker entry point**

```bash
cd ~/TTI-O && cat tio-browser/src/main/java/global/thalion/ttio/browser/workbench/EncodingPanel.java
```

- [ ] **Step b: Write test asserting `setProgressListener` exists and is invoked**

In `EncodingPanelTest.java`, add:
```java
@Test
void encodeEmitsProgressReportsToExternalListener() throws Exception {
    EncodingPanel panel = new EncodingPanel(/*owner=*/null);
    var got = new java.util.concurrent.CopyOnWriteArrayList<
        global.thalion.ttio.browser.progress.ProgressReport>();
    panel.setProgressListener(got::add);
    panel.encodeForTest(testFixturePath());  // expose a test-only method
    assertTrue(got.size() >= 1,
        "encode should emit at least one ProgressReport");
}
```

- [ ] **Step c: Run, fail, implement, run, pass, commit**

Commit message: `feat(tio-browser/workbench): EncodingPanel emits ProgressReport via setProgressListener`.

### Task 1.7: `workbench.TransferManager` per-transfer emission

`TransferManager` already tracks `Transfer` objects. Add a single `ProgressListener` per transfer (settable via `Transfer.setProgressListener`) that the manager invokes whenever the underlying `UploadTask`/`DownloadTask` reports.

**Files:**
- Modify: `tio-browser/src/main/java/global/thalion/ttio/browser/workbench/Transfer.java`
- Modify: `tio-browser/src/main/java/global/thalion/ttio/browser/workbench/TransferManager.java`
- Modify: `tio-browser/src/test/java/global/thalion/ttio/browser/workbench/TransferTest.java`

- [ ] **Step 1: Add field + setter to `Transfer`**

```java
private volatile global.thalion.ttio.browser.progress.ProgressListener progressListener;
public void setProgressListener(
        global.thalion.ttio.browser.progress.ProgressListener l) {
    this.progressListener = l;
}
global.thalion.ttio.browser.progress.ProgressListener progressListener() {
    return progressListener;
}
```

- [ ] **Step 2: In `TransferManager.startTransfer(Transfer t)` (or whichever method launches the task), forward**

```java
var task = createTaskFor(t);
if (t.progressListener() != null) {
    task.setProgressListener(t.progressListener());
}
```

- [ ] **Step 3: Add test**

```java
@Test
void transferForwardsProgressReportsToItsListener() throws Exception {
    var manager = TransferManager.instance(); // or a fresh test instance
    var got = new java.util.concurrent.CopyOnWriteArrayList<
        global.thalion.ttio.browser.progress.ProgressReport>();
    Transfer t = manager.newUpload(testFixturePath(), "test-project", testUri());
    t.setProgressListener(got::add);
    manager.submit(t);
    manager.awaitCompletion(t, java.time.Duration.ofSeconds(10));
    assertTrue(got.size() >= 1);
}
```

(Adjust method names to whatever `TransferManager` actually exposes.)

- [ ] **Step 4: Run, fail, implement, run, pass, commit**

Commit message: `feat(tio-browser/workbench): TransferManager forwards ProgressReport per Transfer`.

### Task 1.8: Stage 1 regression gate

- [ ] **Step 1: Run the full tio-browser test suite**

```bash
cd ~/TTI-O/tio-browser && mvn -B test \
    -Dhdf5.jar=/usr/share/java/jarhdf5.jar
```
Expected: **BUILD SUCCESS**. No prior test regressed.

- [ ] **Step 2: Tag the stage boundary**

```bash
cd ~/TTI-O && git tag stage-1-progress-wired
```

---

# Stage 2 — Shell Skeleton

Goal: build the new `AppShell` (header, rail, centre, transfer strip) and host it from `MainWindow`. Workspaces are stubs that just wrap the current content so nothing user-facing breaks. The old `MainWindow.buildMenuBar()` / `buildToolBar()` content is deleted; the only menu is `File` + `Help`.

### Task 2.1: `Workspace` interface

**Files:**
- Create: `tio-browser/src/main/java/global/thalion/ttio/browser/shell/Workspace.java`

- [ ] **Step 1: Write the interface (no test — it's an interface)**

```java
package global.thalion.ttio.browser.shell;

import javafx.scene.layout.Region;

public interface Workspace {
    /** Stable identifier, e.g. {@code "containers"}. */
    String key();
    /** Tooltip text shown on the rail icon. */
    String tooltip();
    /** Single-character glyph shown on the rail button. */
    String iconText();
    /** The workspace's root content, built once and reused. */
    Region node();
    /** Called when the workspace becomes the active one. */
    void onShow();
    /** Called when leaving the workspace. */
    void onHide();
}
```

- [ ] **Step 2: Commit**

```bash
cd ~/TTI-O
git add tio-browser/src/main/java/global/thalion/ttio/browser/shell/Workspace.java
git commit -m "feat(tio-browser/shell): Workspace interface"
```

### Task 2.2: `ActivityRail` control

**Files:**
- Create: `tio-browser/src/main/java/global/thalion/ttio/browser/shell/ActivityRail.java`
- Create: `tio-browser/src/test/java/global/thalion/ttio/browser/shell/ActivityRailTest.java`

- [ ] **Step 1: Write the failing test**

```java
package global.thalion.ttio.browser.shell;

import javafx.scene.Scene;
import javafx.scene.layout.Region;
import javafx.scene.layout.StackPane;
import javafx.stage.Stage;
import org.junit.jupiter.api.Test;
import org.testfx.framework.junit5.ApplicationTest;
import java.util.List;
import static org.junit.jupiter.api.Assertions.*;

class ActivityRailTest extends ApplicationTest {

    private ActivityRail rail;
    private java.util.concurrent.atomic.AtomicReference<String> last =
        new java.util.concurrent.atomic.AtomicReference<>();

    @Override
    public void start(Stage stage) {
        rail = new ActivityRail(List.of(
            stub("containers", "Containers", "📁"),
            stub("cohorts",    "Cohorts",    "🔬"),
            stub("jobs",       "Jobs & Sessions", "⚙"),
            stub("transfers",  "Transfers",  "⇅")
        ));
        rail.onSelect(last::set);
        stage.setScene(new Scene(new StackPane(rail.node()), 60, 400));
        stage.show();
    }

    @Test
    void initialSelectionIsTheFirstWorkspace() {
        assertEquals("containers", rail.selectedKey());
    }

    @Test
    void clickingButtonChangesSelectionAndFiresCallback() {
        interact(() -> rail.select("cohorts"));
        assertEquals("cohorts", rail.selectedKey());
        assertEquals("cohorts", last.get());
    }

    @Test
    void everyButtonHasTooltipMatchingWorkspace() {
        for (var btn : rail.buttonsForTest()) {
            assertNotNull(btn.getTooltip(),
                "button " + btn.getText() + " should have a tooltip");
        }
    }

    private static Workspace stub(String key, String tooltip, String icon) {
        return new Workspace() {
            public String key() { return key; }
            public String tooltip() { return tooltip; }
            public String iconText() { return icon; }
            public Region node() { return new StackPane(); }
            public void onShow() {}
            public void onHide() {}
        };
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd ~/TTI-O/tio-browser && mvn -B test \
    -Dtest=ActivityRailTest -Dhdf5.jar=/usr/share/java/jarhdf5.jar
```
Expected: **COMPILATION FAILURE**.

- [ ] **Step 3: Write the implementation**

```java
package global.thalion.ttio.browser.shell;

import javafx.scene.control.ToggleButton;
import javafx.scene.control.ToggleGroup;
import javafx.scene.control.Tooltip;
import javafx.scene.layout.VBox;
import javafx.util.Duration;

import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.function.Consumer;

public final class ActivityRail {

    private final VBox root = new VBox();
    private final ToggleGroup group = new ToggleGroup();
    private final Map<String, ToggleButton> buttons = new LinkedHashMap<>();
    private final List<Workspace> workspaces;
    private Consumer<String> onSelect = k -> {};
    private String selected;

    public ActivityRail(List<Workspace> workspaces) {
        this.workspaces = List.copyOf(workspaces);
        root.getStyleClass().add("activity-rail");
        root.setPrefWidth(48);
        root.setMinWidth(48);
        root.setMaxWidth(48);
        for (Workspace w : this.workspaces) {
            ToggleButton b = new ToggleButton(w.iconText());
            b.setToggleGroup(group);
            b.getStyleClass().add("activity-rail-button");
            b.setPrefSize(48, 48);
            Tooltip t = new Tooltip(w.tooltip());
            t.setShowDelay(Duration.millis(600));
            b.setTooltip(t);
            b.setOnAction(e -> {
                if (!b.isSelected()) {
                    // Prevent deselecting the only selected button.
                    b.setSelected(true);
                    return;
                }
                select(w.key());
            });
            buttons.put(w.key(), b);
            root.getChildren().add(b);
        }
        if (!this.workspaces.isEmpty()) {
            select(this.workspaces.get(0).key());
        }
    }

    public VBox node() { return root; }

    public String selectedKey() { return selected; }

    public void select(String key) {
        ToggleButton b = buttons.get(key);
        if (b == null) return;
        b.setSelected(true);
        if (!key.equals(selected)) {
            selected = key;
            onSelect.accept(key);
        }
    }

    public void onSelect(Consumer<String> handler) {
        this.onSelect = handler == null ? k -> {} : handler;
    }

    /** Test-only accessor. */
    java.util.Collection<ToggleButton> buttonsForTest() {
        return buttons.values();
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
cd ~/TTI-O/tio-browser && mvn -B test \
    -Dtest=ActivityRailTest -Dhdf5.jar=/usr/share/java/jarhdf5.jar
```
Expected: **BUILD SUCCESS**.

- [ ] **Step 5: Commit**

```bash
cd ~/TTI-O
git add tio-browser/src/main/java/global/thalion/ttio/browser/shell/ActivityRail.java \
        tio-browser/src/test/java/global/thalion/ttio/browser/shell/ActivityRailTest.java
git commit -m "feat(tio-browser/shell): ActivityRail icon-button column with tooltip + single-selection"
```

### Task 2.3: `ConnectionChip`

**Files:**
- Create: `tio-browser/src/main/java/global/thalion/ttio/browser/shell/ConnectionChip.java`
- Create: `tio-browser/src/test/java/global/thalion/ttio/browser/shell/ConnectionChipTest.java`

- [ ] **Step 1: Inspect existing `ConnectionManager` API**

```bash
cd ~/TTI-O && grep -nE "public.*ConnectionState|public.*isConnected|public.*session|public.*addListener|public.*removeListener" \
    tio-browser/src/main/java/global/thalion/ttio/browser/workbench/ConnectionManager.java \
    tio-browser/src/main/java/global/thalion/ttio/browser/workbench/ConnectionState.java \
    tio-browser/src/main/java/global/thalion/ttio/browser/workbench/ConnectionListener.java
```
Note the exact accessor names — use them verbatim below.

- [ ] **Step 2: Write the failing test**

```java
package global.thalion.ttio.browser.shell;

import global.thalion.ttio.browser.workbench.ConnectionManager;
import global.thalion.ttio.browser.workbench.ConnectionState;
import javafx.scene.Scene;
import javafx.scene.layout.StackPane;
import javafx.stage.Stage;
import org.junit.jupiter.api.Test;
import org.testfx.framework.junit5.ApplicationTest;
import static org.junit.jupiter.api.Assertions.*;

class ConnectionChipTest extends ApplicationTest {

    private ConnectionChip chip;
    private ConnectionManager mgr;

    @Override
    public void start(Stage stage) {
        mgr = ConnectionManager.instance();
        mgr.disconnect(); // start clean
        chip = new ConnectionChip(mgr);
        stage.setScene(new Scene(new StackPane(chip.node()), 400, 40));
        stage.show();
    }

    @Test
    void offlineStateShowsOfflineText() {
        assertTrue(chip.label().getText().toLowerCase().contains("offline"),
            "expected offline text, got: " + chip.label().getText());
    }

    @Test
    void connectedStateShowsHostAndUser() throws Exception {
        // simulate a connection via a test helper on ConnectionManager,
        // or via a mocked subclass — adjust to the actual API.
        interact(() -> mgr.injectTestSession("alice", "biobank.thalion.org"));
        assertTrue(chip.label().getText().contains("alice"));
        assertTrue(chip.label().getText().contains("biobank.thalion.org"));
    }
}
```

If `ConnectionManager.injectTestSession` doesn't exist, add a package-private test-only helper to `ConnectionManager`:
```java
/** Test-only. Sets the manager into a CONNECTED state with a stub session. */
void injectTestSession(String user, String host) { /* set fields, fire listeners */ }
```

- [ ] **Step 3: Run, fail, implement, run, pass**

`ConnectionChip.java`:
```java
package global.thalion.ttio.browser.shell;

import global.thalion.ttio.browser.workbench.ConnectionListener;
import global.thalion.ttio.browser.workbench.ConnectionManager;
import global.thalion.ttio.browser.workbench.ConnectionState;
import javafx.application.Platform;
import javafx.scene.control.Label;
import javafx.scene.layout.HBox;

public final class ConnectionChip {

    private final ConnectionManager manager;
    private final Label label = new Label();
    private final HBox root = new HBox(6, label);
    private final ConnectionListener listener;
    private Runnable onClick = () -> {};

    public ConnectionChip(ConnectionManager manager) {
        this.manager = manager;
        root.getStyleClass().add("connection-chip");
        root.setOnMouseClicked(e -> onClick.run());
        this.listener = state -> Platform.runLater(this::refresh);
        manager.addListener(listener);
        refresh();
    }

    public HBox node() { return root; }
    public Label label() { return label; }

    public void onClick(Runnable r) { this.onClick = r == null ? () -> {} : r; }

    public void dispose() { manager.removeListener(listener); }

    private void refresh() {
        if (manager.isConnected()) {
            var s = manager.session();
            var c = manager.client();
            label.setText("⚫ workbench: connected ("
                + s.username() + "@" + c.host() + ")");
        } else if (manager.state() == ConnectionState.CONNECTING) {
            label.setText("⟳ workbench: connecting…");
        } else {
            label.setText("○ workbench: offline");
        }
    }
}
```

(`⚫` is ⬫; use whatever solid-circle glyph reads well — the test only asserts text content, not glyph.)

- [ ] **Step 4: Commit**

```bash
cd ~/TTI-O
git add tio-browser/src/main/java/global/thalion/ttio/browser/shell/ConnectionChip.java \
        tio-browser/src/test/java/global/thalion/ttio/browser/shell/ConnectionChipTest.java \
        tio-browser/src/main/java/global/thalion/ttio/browser/workbench/ConnectionManager.java
git commit -m "feat(tio-browser/shell): ConnectionChip showing live workbench session state"
```

### Task 2.4: `TransferStrip`

**Files:**
- Create: `tio-browser/src/main/java/global/thalion/ttio/browser/shell/TransferStrip.java`
- Create: `tio-browser/src/test/java/global/thalion/ttio/browser/shell/TransferStripTest.java`

- [ ] **Step 1: Write the failing test**

```java
package global.thalion.ttio.browser.shell;

import global.thalion.ttio.browser.progress.ProgressReport;
import global.thalion.ttio.browser.workbench.Transfer;
import global.thalion.ttio.browser.workbench.TransferKind;
import global.thalion.ttio.browser.workbench.TransferManager;
import javafx.scene.Scene;
import javafx.scene.layout.StackPane;
import javafx.stage.Stage;
import org.junit.jupiter.api.Test;
import org.testfx.framework.junit5.ApplicationTest;
import static org.junit.jupiter.api.Assertions.*;

class TransferStripTest extends ApplicationTest {

    private TransferStrip strip;
    private TransferManager tm;
    private java.util.concurrent.atomic.AtomicBoolean clicked =
        new java.util.concurrent.atomic.AtomicBoolean(false);

    @Override
    public void start(Stage stage) {
        tm = TransferManager.instance();
        tm.clearAllForTest();
        strip = new TransferStrip(tm);
        strip.onViewAll(() -> clicked.set(true));
        stage.setScene(new Scene(new StackPane(strip.node()), 600, 40));
        stage.show();
    }

    @Test
    void hiddenWhenNoTransfers() {
        assertFalse(strip.node().isVisible(),
            "strip should be hidden when no transfers exist");
    }

    @Test
    void visibleAndShowsSummaryWhenTransferStarts() throws Exception {
        Transfer t = tm.newFakeUploadForTest(/*bytesTotal=*/1000L);
        interact(() -> tm.startForTest(t));
        interact(() -> tm.fakeProgress(t, new ProgressReport("uploading",
            500L, 1000L, -1L, -1L, 100.0, Double.NaN, 5L, 5L,
            System.currentTimeMillis())));
        assertTrue(strip.node().isVisible());
        String text = strip.label().getText();
        assertTrue(text.contains("50.0%") || text.contains("↑"),
            "label should describe the active transfer: " + text);
    }

    @Test
    void viewAllClickFiresCallback() {
        // ensure strip is visible first
        Transfer t = tm.newFakeUploadForTest(1000L);
        interact(() -> tm.startForTest(t));
        clickOn(strip.viewAllButtonForTest());
        assertTrue(clicked.get());
    }
}
```

If `TransferManager` lacks `clearAllForTest`, `newFakeUploadForTest`, `startForTest`, `fakeProgress`, add package-private test helpers there now.

- [ ] **Step 2: Run, fail, implement, run, pass**

`TransferStrip.java`:
```java
package global.thalion.ttio.browser.shell;

import global.thalion.ttio.browser.progress.ProgressFormatter;
import global.thalion.ttio.browser.progress.ProgressReport;
import global.thalion.ttio.browser.workbench.Transfer;
import global.thalion.ttio.browser.workbench.TransferManager;
import javafx.application.Platform;
import javafx.geometry.Pos;
import javafx.scene.control.Button;
import javafx.scene.control.Label;
import javafx.scene.layout.HBox;
import javafx.scene.layout.Region;

import java.util.List;

public final class TransferStrip {

    private final TransferManager manager;
    private final Label summary = new Label("");
    private final Button viewAll = new Button("view all");
    private final HBox root = new HBox(8, summary, spacer(), viewAll);
    private Runnable onViewAll = () -> {};

    public TransferStrip(TransferManager manager) {
        this.manager = manager;
        root.setAlignment(Pos.CENTER_LEFT);
        root.setPrefHeight(32);
        root.getStyleClass().add("transfer-strip");
        viewAll.setOnAction(e -> onViewAll.run());
        manager.addQueueListener(() -> Platform.runLater(this::refresh));
        // also subscribe to per-transfer progress on every active transfer
        manager.addProgressListener(r -> Platform.runLater(this::refresh));
        refresh();
    }

    public Region node() { return root; }
    public Label label() { return summary; }
    public Button viewAllButtonForTest() { return viewAll; }
    public void onViewAll(Runnable r) { this.onViewAll = r == null ? () -> {} : r; }

    private void refresh() {
        List<Transfer> active = manager.activeTransfers();
        if (active.isEmpty()) {
            root.setVisible(false);
            root.setManaged(false);
            return;
        }
        root.setVisible(true);
        root.setManaged(true);
        if (active.size() == 1) {
            Transfer t = active.get(0);
            ProgressReport r = t.lastReport();
            if (r == null) {
                summary.setText(arrow(t) + " " + t.label() + " — starting…");
            } else {
                summary.setText(arrow(t) + " " + t.label() + "  "
                    + ProgressFormatter.line(r, System.currentTimeMillis()));
            }
        } else {
            double up = 0, down = 0;
            int upN = 0, downN = 0;
            for (Transfer t : active) {
                ProgressReport r = t.lastReport();
                if (r == null) continue;
                if (t.kind().isUpload()) { up += r.rateBytesPerSec(); upN++; }
                else                     { down += r.rateBytesPerSec(); downN++; }
            }
            summary.setText(active.size() + " transfers active · ↑ "
                + global.thalion.ttio.browser.util.Units.humanRate(up)
                + " · ↓ "
                + global.thalion.ttio.browser.util.Units.humanRate(down));
        }
    }

    private static String arrow(Transfer t) {
        return t.kind().isUpload() ? "↑" : "↓";
    }

    private static Region spacer() {
        Region r = new Region();
        HBox.setHgrow(r, javafx.scene.layout.Priority.ALWAYS);
        return r;
    }
}
```

Add the required helpers to `TransferManager`:
```java
// queue/state listeners
public interface QueueListener { void onQueueChanged(); }
private final java.util.List<QueueListener> queueListeners
    = new java.util.concurrent.CopyOnWriteArrayList<>();
public void addQueueListener(QueueListener l) { queueListeners.add(l); }
private void fireQueueChanged() {
    for (var l : queueListeners) l.onQueueChanged();
}

// progress fan-out
private final java.util.List<
    global.thalion.ttio.browser.progress.ProgressListener> progressListeners
    = new java.util.concurrent.CopyOnWriteArrayList<>();
public void addProgressListener(
        global.thalion.ttio.browser.progress.ProgressListener l) {
    progressListeners.add(l);
}
private void fanOutProgress(global.thalion.ttio.browser.progress.ProgressReport r) {
    for (var l : progressListeners) l.onProgress(r);
}
```

And add `Transfer.lastReport()` storing the most recent `ProgressReport` via the listener path.

- [ ] **Step 3: Commit**

```bash
cd ~/TTI-O
git add tio-browser/src/main/java/global/thalion/ttio/browser/shell/TransferStrip.java \
        tio-browser/src/test/java/global/thalion/ttio/browser/shell/TransferStripTest.java \
        tio-browser/src/main/java/global/thalion/ttio/browser/workbench/TransferManager.java \
        tio-browser/src/main/java/global/thalion/ttio/browser/workbench/Transfer.java
git commit -m "feat(tio-browser/shell): TransferStrip auto-hides + shows quantitative summary"
```

### Task 2.5: `AppShell` composes header + rail + centre + strip

**Files:**
- Create: `tio-browser/src/main/java/global/thalion/ttio/browser/shell/AppShell.java`
- Create: `tio-browser/src/test/java/global/thalion/ttio/browser/shell/AppShellSmokeTest.java`

- [ ] **Step 1: Write the failing test**

```java
package global.thalion.ttio.browser.shell;

import javafx.scene.Scene;
import javafx.scene.layout.Region;
import javafx.scene.layout.StackPane;
import javafx.stage.Stage;
import org.junit.jupiter.api.Test;
import org.testfx.framework.junit5.ApplicationTest;
import java.util.List;
import static org.junit.jupiter.api.Assertions.*;

class AppShellSmokeTest extends ApplicationTest {

    private AppShell shell;

    @Override
    public void start(Stage stage) {
        shell = AppShell.create(
            List.of(stub("containers", "Containers", "📁"),
                    stub("cohorts",    "Cohorts",    "🔬"),
                    stub("jobs",       "Jobs & Sessions", "⚙"),
                    stub("transfers",  "Transfers",  "⇅")));
        stage.setScene(new Scene(shell.root(), 1280, 800));
        stage.show();
    }

    @Test
    void shellHasHeaderRailCenterAndStrip() {
        assertNotNull(shell.header());
        assertNotNull(shell.rail());
        assertNotNull(shell.transferStrip());
        assertEquals("containers", shell.rail().selectedKey(),
            "default selection is first workspace");
    }

    @Test
    void switchingRailReplacesCenter() {
        Region beforeCenter = (Region) shell.root().getCenter();
        interact(() -> shell.rail().select("cohorts"));
        Region afterCenter = (Region) shell.root().getCenter();
        assertNotSame(beforeCenter, afterCenter);
    }

    private static Workspace stub(String key, String tooltip, String icon) {
        return new Workspace() {
            private final Region n = new StackPane();
            public String key() { return key; }
            public String tooltip() { return tooltip; }
            public String iconText() { return icon; }
            public Region node() { return n; }
            public void onShow() {}
            public void onHide() {}
        };
    }
}
```

- [ ] **Step 2: Run, fail, implement, run, pass**

`AppShell.java`:
```java
package global.thalion.ttio.browser.shell;

import global.thalion.ttio.browser.workbench.ConnectionManager;
import global.thalion.ttio.browser.workbench.TransferManager;
import javafx.geometry.Pos;
import javafx.scene.control.Label;
import javafx.scene.layout.BorderPane;
import javafx.scene.layout.HBox;
import javafx.scene.layout.Priority;
import javafx.scene.layout.Region;
import javafx.scene.layout.VBox;

import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * The top-level shell: header bar + activity rail + active workspace
 * + bottom transfer strip. Construct once and add to a Scene's root.
 */
public final class AppShell {

    private final BorderPane root = new BorderPane();
    private final HBox header;
    private final ActivityRail rail;
    private final TransferStrip strip;
    private final ConnectionChip chip;
    private final Map<String, Workspace> workspaces;
    private String currentKey;

    private AppShell(List<Workspace> workspaces,
                     ConnectionManager cm,
                     TransferManager tm) {
        this.workspaces = new LinkedHashMap<>();
        for (Workspace w : workspaces) this.workspaces.put(w.key(), w);
        this.chip = new ConnectionChip(cm);
        this.header = buildHeader();
        this.rail = new ActivityRail(workspaces);
        this.strip = new TransferStrip(tm);
        this.strip.onViewAll(() -> rail.select("transfers"));

        VBox left = new VBox(rail.node());
        root.setTop(header);
        root.setLeft(rail.node());
        root.setBottom(strip.node());
        rail.onSelect(this::switchTo);
        switchTo(rail.selectedKey());
    }

    public static AppShell create(List<Workspace> workspaces) {
        return new AppShell(workspaces,
            ConnectionManager.instance(),
            TransferManager.instance());
    }

    /** Test-only constructor — inject mocks. */
    public static AppShell createForTest(List<Workspace> workspaces,
                                          ConnectionManager cm,
                                          TransferManager tm) {
        return new AppShell(workspaces, cm, tm);
    }

    public BorderPane root()   { return root; }
    public HBox header()       { return header; }
    public ActivityRail rail() { return rail; }
    public TransferStrip transferStrip() { return strip; }
    public ConnectionChip chip() { return chip; }
    public Workspace currentWorkspace() {
        return workspaces.get(currentKey);
    }

    private void switchTo(String key) {
        Workspace next = workspaces.get(key);
        if (next == null) return;
        if (currentKey != null && !currentKey.equals(key)) {
            workspaces.get(currentKey).onHide();
        }
        currentKey = key;
        root.setCenter(next.node());
        next.onShow();
    }

    private HBox buildHeader() {
        Label title = new Label("tio-browser");
        title.getStyleClass().add("app-title");
        Region spacer = new Region();
        HBox.setHgrow(spacer, Priority.ALWAYS);
        HBox h = new HBox(12, title, spacer, chip.node());
        h.setAlignment(Pos.CENTER_LEFT);
        h.setPrefHeight(36);
        h.getStyleClass().add("app-header");
        return h;
    }
}
```

- [ ] **Step 3: Commit**

```bash
cd ~/TTI-O
git add tio-browser/src/main/java/global/thalion/ttio/browser/shell/AppShell.java \
        tio-browser/src/test/java/global/thalion/ttio/browser/shell/AppShellSmokeTest.java
git commit -m "feat(tio-browser/shell): AppShell composes header + rail + workspaces + transfer strip"
```

### Task 2.6: Stub workspaces wrapping current content

**Files:**
- Create: `tio-browser/src/main/java/global/thalion/ttio/browser/shell/workspaces/ContainersWorkspace.java`
- Create: `tio-browser/src/main/java/global/thalion/ttio/browser/shell/workspaces/CohortsWorkspace.java`
- Create: `tio-browser/src/main/java/global/thalion/ttio/browser/shell/workspaces/JobsWorkspace.java`
- Create: `tio-browser/src/main/java/global/thalion/ttio/browser/shell/workspaces/TransfersWorkspace.java`

Each is a minimal `Workspace` that returns a placeholder `Region` for now. Real content is built in later stages.

- [ ] **Step 1: Write each stub**

Example `ContainersWorkspace.java`:
```java
package global.thalion.ttio.browser.shell.workspaces;

import global.thalion.ttio.browser.shell.Workspace;
import javafx.scene.control.Label;
import javafx.scene.layout.Region;
import javafx.scene.layout.StackPane;

public final class ContainersWorkspace implements Workspace {
    private final StackPane root = new StackPane(new Label(
        "Containers workspace (Stage 6 wires up the unified tree)"));
    public String key()      { return "containers"; }
    public String tooltip()  { return "Containers"; }
    public String iconText() { return "📁"; }
    public Region node()     { return root; }
    public void onShow()     {}
    public void onHide()     {}
}
```

Repeat for `CohortsWorkspace` (icon `🔬`, tooltip `"Cohorts"`), `JobsWorkspace` (icon `⚙`, tooltip `"Jobs & Sessions"`), `TransfersWorkspace` (icon `⇅`, tooltip `"Transfers"`). Each just shows a "Stage N wires this up" placeholder for now.

- [ ] **Step 2: No new tests** (the stubs are exercised via `AppShellSmokeTest`).

- [ ] **Step 3: Commit**

```bash
cd ~/TTI-O
git add tio-browser/src/main/java/global/thalion/ttio/browser/shell/workspaces/
git commit -m "feat(tio-browser/shell/workspaces): four placeholder workspaces"
```

### Task 2.7: Replace `MainWindow` body; migrate the two menu smoke tests

**Files:**
- Modify: `tio-browser/src/main/java/global/thalion/ttio/browser/MainWindow.java`
- Modify: `tio-browser/src/test/java/global/thalion/ttio/browser/AppSmokeTest.java` (no change expected, verify)
- Delete: `tio-browser/src/test/java/global/thalion/ttio/browser/WorkbenchMenuSmokeTest.java`
- Create: `tio-browser/src/test/java/global/thalion/ttio/browser/MainWindowShellSmokeTest.java`

- [ ] **Step 1: Write the new shell smoke test**

`MainWindowShellSmokeTest.java`:
```java
package global.thalion.ttio.browser;

import javafx.scene.control.Menu;
import javafx.scene.control.MenuBar;
import javafx.scene.control.MenuItem;
import javafx.scene.Parent;
import javafx.stage.Stage;
import org.junit.jupiter.api.Test;
import org.testfx.framework.junit5.ApplicationTest;

import java.util.List;

import static org.junit.jupiter.api.Assertions.*;

class MainWindowShellSmokeTest extends ApplicationTest {

    private MainWindow win;

    @Override
    public void start(Stage stage) {
        win = new MainWindow();
        win.show(stage);
    }

    @Test
    void menuBarHasOnlyFileAndHelp() {
        MenuBar bar = findMenuBar(win.root());
        assertNotNull(bar);
        List<String> menus = bar.getMenus().stream()
            .map(Menu::getText).toList();
        assertEquals(List.of("File", "Help"), menus,
            "menu bar should be exactly [File, Help]; got " + menus);
    }

    @Test
    void fileMenuHasExpectedItems() {
        Menu file = findMenu(win.root(), "File");
        List<String> labels = file.getItems().stream()
            .map(MenuItem::getText).filter(s -> s != null).toList();
        // Order matters per spec.
        assertTrue(labels.containsAll(List.of(
            "Open…", "Open Recent", "Encode…", "Import…",
            "Export…", "Save As…", "Close", "Exit")),
            "File menu missing items: " + labels);
    }

    @Test
    void helpMenuHasDiagnostics() {
        Menu help = findMenu(win.root(), "Help");
        List<String> labels = help.getItems().stream()
            .map(MenuItem::getText).filter(s -> s != null).toList();
        assertTrue(labels.contains("Diagnostics…"),
            "Help menu should contain Diagnostics: " + labels);
    }

    @Test
    void shellExposesAllFourWorkspaces() {
        assertNotNull(win.shell());
        assertEquals("containers", win.shell().rail().selectedKey());
        // switch through each workspace key
        interact(() -> win.shell().rail().select("cohorts"));
        assertEquals("cohorts", win.shell().rail().selectedKey());
        interact(() -> win.shell().rail().select("jobs"));
        assertEquals("jobs", win.shell().rail().selectedKey());
        interact(() -> win.shell().rail().select("transfers"));
        assertEquals("transfers", win.shell().rail().selectedKey());
    }

    private static MenuBar findMenuBar(Parent root) {
        for (var node : root.getChildrenUnmodifiable()) {
            if (node instanceof MenuBar mb) return mb;
            if (node instanceof Parent p) {
                MenuBar m = findMenuBar(p);
                if (m != null) return m;
            }
        }
        return null;
    }

    private static Menu findMenu(Parent root, String name) {
        return findMenuBar(root).getMenus().stream()
            .filter(m -> name.equals(m.getText()))
            .findFirst().orElseThrow();
    }
}
```

- [ ] **Step 2: Run new test to verify it fails**

```bash
cd ~/TTI-O/tio-browser && mvn -B test \
    -Dtest=MainWindowShellSmokeTest -Dhdf5.jar=/usr/share/java/jarhdf5.jar
```
Expected: **FAILURE** — current `MainWindow` has the old 7-menu surface.

- [ ] **Step 3: Rewrite `MainWindow.java`**

```java
package global.thalion.ttio.browser;

import global.thalion.ttio.browser.shell.AppShell;
import global.thalion.ttio.browser.shell.Workspace;
import global.thalion.ttio.browser.shell.workspaces.*;
import javafx.scene.Scene;
import javafx.scene.control.*;
import javafx.scene.layout.BorderPane;
import javafx.scene.layout.VBox;
import javafx.stage.Stage;

import java.util.List;

public class MainWindow {

    private Stage stage;
    private BorderPane root;
    private AppShell shell;
    private MenuBar menuBar;
    private MenuItem openItem, openRecentItem, encodeItem, importItem,
        exportItem, saveAsItem, closeItem, exitItem;
    private MenuItem aboutItem, userGuideItem, diagnosticsItem;

    public void show(Stage primaryStage) {
        this.stage = primaryStage;
        this.shell = AppShell.create(List.of(
            new ContainersWorkspace(),
            new CohortsWorkspace(),
            new JobsWorkspace(),
            new TransfersWorkspace()));
        this.menuBar = buildMenuBar();
        this.root = new BorderPane();
        root.setTop(new VBox(menuBar, shell.root().getTop()));
        // Move shell's centre/rail/strip into root; preserve shell's
        // BorderPane semantics by re-parenting:
        root.setLeft(shell.root().getLeft());
        root.setCenter(shell.root().getCenter());
        root.setBottom(shell.root().getBottom());
        Scene scene = new Scene(root, 1280, 800);
        scene.getStylesheets().add(
            getClass().getResource("/css/tio-browser.css").toExternalForm());
        primaryStage.setScene(scene);
        primaryStage.setTitle("tio-browser");
        primaryStage.show();
        wireMenuActions();
    }

    private MenuBar buildMenuBar() {
        Menu fileMenu = new Menu("File");
        openItem = new MenuItem("Open…");
        openRecentItem = new Menu("Open Recent"); // populated in Stage 7
        encodeItem = new MenuItem("Encode…");
        importItem = new MenuItem("Import…");
        exportItem = new MenuItem("Export…");
        saveAsItem = new MenuItem("Save As…");
        closeItem = new MenuItem("Close");
        exitItem = new MenuItem("Exit");
        fileMenu.getItems().addAll(openItem, openRecentItem, new SeparatorMenuItem(),
            encodeItem, importItem, exportItem, saveAsItem, new SeparatorMenuItem(),
            closeItem, exitItem);

        Menu helpMenu = new Menu("Help");
        aboutItem = new MenuItem("About");
        userGuideItem = new MenuItem("User guide");
        diagnosticsItem = new MenuItem("Diagnostics…");
        helpMenu.getItems().addAll(aboutItem, userGuideItem, diagnosticsItem);

        return new MenuBar(fileMenu, helpMenu);
    }

    private void wireMenuActions() {
        diagnosticsItem.setOnAction(e ->
            global.thalion.ttio.browser.diag.DiagnosticsDialog.show(stage));
        exitItem.setOnAction(e -> {
            javafx.application.Platform.exit();
        });
        // Other items wired in later stages.
    }

    public BorderPane root() { return root; }
    public AppShell shell()  { return shell; }
    public Stage stage()     { return stage; }
    // Test-only accessors preserved for older tests:
    MenuItem openMenuItem()        { return openItem; }
    MenuItem closeMenuItem()       { return closeItem; }
    MenuItem exitMenuItem()        { return exitItem; }
    MenuItem diagnosticsMenuItem() { return diagnosticsItem; }
}
```

(The current `loadDataset`, drag-drop, status-bar update etc. are temporarily commented out in this stage — they'll be re-wired inside the `ContainersWorkspace` in Stage 2.8 / Stage 6. Add `// TODO Stage 6: re-wire` comments at the call sites that have been removed, then delete them — no leftover `// TODO` strings in committed source.)

Actually: rather than leave the old methods, **delete** them entirely now (they're moving to the workspace). The Stage 2.8 task immediately follows and re-introduces dataset loading via the workspace.

- [ ] **Step 4: Delete the old menu smoke test**

```bash
cd ~/TTI-O
git rm tio-browser/src/test/java/global/thalion/ttio/browser/WorkbenchMenuSmokeTest.java
```

- [ ] **Step 5: Run all tests, fix compilation in any test that referenced deleted methods on `MainWindow`**

```bash
cd ~/TTI-O/tio-browser && mvn -B test \
    -Dhdf5.jar=/usr/share/java/jarhdf5.jar 2>&1 | tail -80
```

Expect a list of compilation errors in tests that referenced removed `MainWindow` methods like `openImportDialog`, `openExportDialog`, etc. For each:

- If the test is exercising old menu wiring (and the action moved to a workspace), **delete the test** (it's testing the old shell, not behaviour).
- If the test is exercising real behaviour (e.g. `MainWindowOpenTest`), update it to call the new path through `win.shell().currentWorkspace()`.

Specifically expected casualties:
- `MainWindowOpenTest` — keep, but route through workspace once Stage 2.8 lands. For now make it `@org.junit.jupiter.api.Disabled("re-enable in Stage 2.8")`.
- `SaveAsTest` — same: `@Disabled("re-enable in Stage 6")`.

- [ ] **Step 6: Run tests to verify new shell smoke test passes, others compile, disabled ones are explicit**

```bash
cd ~/TTI-O/tio-browser && mvn -B test \
    -Dhdf5.jar=/usr/share/java/jarhdf5.jar
```
Expected: **BUILD SUCCESS**. `MainWindowShellSmokeTest` is green. Disabled tests are skipped, not failing.

- [ ] **Step 7: Commit**

```bash
cd ~/TTI-O
git add tio-browser/src/main/java/global/thalion/ttio/browser/MainWindow.java \
        tio-browser/src/test/java/global/thalion/ttio/browser/MainWindowShellSmokeTest.java \
        tio-browser/src/test/java/global/thalion/ttio/browser/MainWindowOpenTest.java \
        tio-browser/src/test/java/global/thalion/ttio/browser/SaveAsTest.java
git commit -m "refactor(tio-browser): replace MainWindow with AppShell + File/Help menus

Deletes the 7-menu surface and the Workbench menu smoke test in favour
of the new shell. Disables MainWindowOpenTest + SaveAsTest pending
re-wire via ContainersWorkspace in Stage 2.8 / Stage 6."
```

### Task 2.8: Containers stub wraps current file tree + detail pane

Goal: re-introduce dataset loading via `ContainersWorkspace` so `MainWindowOpenTest` and `SaveAsTest` re-enable. This is a **temporary** wrapper — the real unified tree lands in Stage 6.

**Files:**
- Modify: `tio-browser/src/main/java/global/thalion/ttio/browser/shell/workspaces/ContainersWorkspace.java`
- Modify: `tio-browser/src/main/java/global/thalion/ttio/browser/MainWindow.java` (wire File-menu items to workspace actions)
- Modify: `tio-browser/src/test/java/global/thalion/ttio/browser/MainWindowOpenTest.java` (re-enable)
- Modify: `tio-browser/src/test/java/global/thalion/ttio/browser/SaveAsTest.java` (re-enable)

- [ ] **Step 1: Expand `ContainersWorkspace` to host the current tree + detail**

```java
package global.thalion.ttio.browser.shell.workspaces;

import global.thalion.ttio.browser.model.DatasetOpenTask;
import global.thalion.ttio.browser.model.DatasetTreeBuilder;
import global.thalion.ttio.browser.model.DatasetTreeNode;
import global.thalion.ttio.browser.model.OpenDataset;
import global.thalion.ttio.browser.shell.Workspace;
import global.thalion.ttio.browser.view.*;
import global.thalion.ttio.browser.view.headers.*;
import global.thalion.ttio.browser.view.overview.OverviewTab;
import global.thalion.ttio.browser.view.plot.*;
import javafx.geometry.Orientation;
import javafx.scene.control.*;
import javafx.scene.layout.*;
import javafx.stage.FileChooser;
import javafx.stage.Window;

import java.io.File;
import java.nio.file.Files;
import java.nio.file.Paths;
import java.nio.file.StandardCopyOption;

public final class ContainersWorkspace implements Workspace {

    private final SplitPane root = new SplitPane();
    private final DatasetTreeView treeView = new DatasetTreeView();
    private final DetailPane detailPane = new DetailPane();
    private final Label statusLabel = new Label("(no file)");
    private OpenDataset current;

    public ContainersWorkspace() {
        registerTabs();
        treeView.onSelected(detailPane::onSelection);

        BorderPane left = new BorderPane(treeView.control());
        left.setBottom(statusLabel);
        root.setOrientation(Orientation.HORIZONTAL);
        root.getItems().addAll(left, detailPane.control());
        root.setDividerPositions(0.30);
    }

    public String key()      { return "containers"; }
    public String tooltip()  { return "Containers"; }
    public String iconText() { return "📁"; }
    public Region node()     { return root; }
    public void onShow()     {}
    public void onHide()     {}

    public OpenDataset currentDataset() { return current; }
    public DatasetTreeView tree()       { return treeView; }
    public DetailPane detail()          { return detailPane; }
    public Label statusLabel()          { return statusLabel; }

    public void openFile(Window owner) {
        FileChooser chooser = new FileChooser();
        chooser.setTitle("Open .tio file");
        chooser.getExtensionFilters().add(
            new FileChooser.ExtensionFilter("TTI-O dataset", "*.tio"));
        File picked = chooser.showOpenDialog(owner);
        if (picked != null) loadDataset(picked.toString(), true);
    }

    public void loadDataset(String path, boolean readOnly) {
        DatasetOpenTask task = new DatasetOpenTask(path, readOnly);
        statusLabel.setText("Opening " + path + "…");
        task.setOnSucceeded(ev -> {
            current = task.getValue();
            statusLabel.setText(current.path());
            DatasetTreeNode treeRoot = DatasetTreeBuilder.build(current);
            treeView.setRoot(treeRoot);
            detailPane.setCurrentDataset(current);
        });
        task.setOnFailed(ev -> {
            statusLabel.setText("(open failed)");
            new Alert(Alert.AlertType.ERROR,
                "Could not open " + path + ":\n\n" + task.getException().getMessage(),
                ButtonType.OK).showAndWait();
        });
        Thread th = new Thread(task, "open-" + path);
        th.setDaemon(true);
        th.start();
    }

    public void closeDataset() {
        if (current != null) {
            current.close();
            current = null;
        }
        treeView.clear();
        detailPane.setCurrentDataset(null);
        statusLabel.setText("(no file)");
    }

    public void saveAs(Window owner) {
        if (current == null) return;
        FileChooser chooser = new FileChooser();
        chooser.setTitle("Save As");
        chooser.getExtensionFilters().add(
            new FileChooser.ExtensionFilter("TTI-O dataset", "*.tio"));
        File target = chooser.showSaveDialog(owner);
        if (target == null) return;
        try {
            Files.copy(Paths.get(current.path()), target.toPath(),
                StandardCopyOption.REPLACE_EXISTING);
            closeDataset();
            loadDataset(target.toString(), false);
        } catch (java.io.IOException ex) {
            new Alert(Alert.AlertType.ERROR,
                "Save As failed: " + ex.getMessage(), ButtonType.OK).showAndWait();
        }
    }

    private void registerTabs() {
        detailPane.register(new OverviewTab());
        MsHeadersTable msHeaders = new MsHeadersTable();
        NmrHeadersTable nmrHeaders = new NmrHeadersTable();
        RamanHeadersTable ramanHeaders = new RamanHeadersTable();
        SpectrumPlotTab plotTab = new SpectrumPlotTab();
        ChannelHexTab channelHexTab = new ChannelHexTab();
        msHeaders.onRowSelected(spec -> { plotTab.render(spec); channelHexTab.render(spec); });
        nmrHeaders.onRowSelected(spec -> { plotTab.render(spec); channelHexTab.render(spec); });
        ramanHeaders.onRowSelected(spec -> { plotTab.render(spec); channelHexTab.render(spec); });
        detailPane.register(msHeaders);
        detailPane.register(nmrHeaders);
        detailPane.register(ramanHeaders);
        GenomicHeadersTable genomicHeaders = new GenomicHeadersTable();
        ReadInspectorTab readInspectorTab = new ReadInspectorTab();
        genomicHeaders.onRowSelected(row -> readInspectorTab.render(row.full()));
        detailPane.register(genomicHeaders);
        detailPane.register(readInspectorTab);
        detailPane.register(new ChromDistributionView());
        detailPane.register(new ReferenceTab());
        detailPane.register(plotTab);
        detailPane.register(channelHexTab);
        detailPane.register(new ChromatogramPlotTab());
        detailPane.register(new IdentificationsTab());
        detailPane.register(new QuantificationsTab());
        detailPane.register(new ProvenanceTab());
        detailPane.register(new FeatureFlagsTab());
        detailPane.register(new EncryptionTab());
    }
}
```

- [ ] **Step 2: Wire `MainWindow` File-menu items to `ContainersWorkspace`**

In `MainWindow.wireMenuActions()`:
```java
ContainersWorkspace cw = (ContainersWorkspace) shell.currentWorkspaceByKey("containers");
openItem.setOnAction(e -> {
    shell.rail().select("containers");
    cw.openFile(stage);
});
closeItem.setOnAction(e -> cw.closeDataset());
saveAsItem.setOnAction(e -> cw.saveAs(stage));
// Encode / Import / Export wired in later tasks.
```

Add `Workspace currentWorkspaceByKey(String)` to `AppShell` if not present.

Also add scene-level drag-drop for `.tio` files (port the relevant block from the old `MainWindow.show()`).

- [ ] **Step 3: Re-enable disabled tests**

Remove `@Disabled` from `MainWindowOpenTest` and `SaveAsTest`. Update them to use `win.shell().currentWorkspaceByKey("containers")` cast to `ContainersWorkspace` for any accessor they used on the old `MainWindow`.

- [ ] **Step 4: Run all tests**

```bash
cd ~/TTI-O/tio-browser && mvn -B test \
    -Dhdf5.jar=/usr/share/java/jarhdf5.jar
```
Expected: **BUILD SUCCESS**.

- [ ] **Step 5: Commit**

```bash
cd ~/TTI-O
git add tio-browser/src/main/java/global/thalion/ttio/browser/shell/workspaces/ContainersWorkspace.java \
        tio-browser/src/main/java/global/thalion/ttio/browser/MainWindow.java \
        tio-browser/src/main/java/global/thalion/ttio/browser/shell/AppShell.java \
        tio-browser/src/test/java/global/thalion/ttio/browser/MainWindowOpenTest.java \
        tio-browser/src/test/java/global/thalion/ttio/browser/SaveAsTest.java
git commit -m "feat(tio-browser/shell): ContainersWorkspace hosts dataset tree + detail pane

Re-enables MainWindowOpenTest and SaveAsTest. Encode/Import/Export
wiring follows in Stage 3 (transfers) and Stage 6 (unified tree)."
```

### Task 2.9: Stage 2 regression gate

```bash
cd ~/TTI-O/tio-browser && mvn -B test \
    -Dhdf5.jar=/usr/share/java/jarhdf5.jar && \
cd ~/TTI-O && git tag stage-2-shell-skeleton
```

---

# Stage 3 — TransfersWorkspace + Unified `TransferStartDialog` + Legacy Deletions

Goal: ship a real `TransfersWorkspace` and the unified `TransferStartDialog`. Delete the four legacy dialog classes and the `TransferQueueView` `Stage` wrapper.

### Task 3.1: `TransferStartDialog` — direction radio + scope toggle skeleton

**Files:**
- Create: `tio-browser/src/main/java/global/thalion/ttio/browser/workbench/TransferStartDialog.java`
- Create: `tio-browser/src/test/java/global/thalion/ttio/browser/workbench/TransferStartDialogTest.java`

- [ ] **Step 1: Write the failing test**

```java
package global.thalion.ttio.browser.workbench;

import javafx.scene.Scene;
import javafx.scene.layout.StackPane;
import javafx.stage.Stage;
import org.junit.jupiter.api.Test;
import org.testfx.framework.junit5.ApplicationTest;
import static org.junit.jupiter.api.Assertions.*;

class TransferStartDialogTest extends ApplicationTest {

    private TransferStartDialog dlg;
    private Stage owner;

    @Override
    public void start(Stage stage) {
        owner = stage;
        stage.setScene(new Scene(new StackPane(), 100, 100));
        stage.show();
    }

    @Test
    void defaultDirectionIsUpload() {
        interact(() -> {
            dlg = new TransferStartDialog(owner,
                /*connected=*/false);
            dlg.showForTest();
        });
        assertEquals(TransferStartDialog.Direction.UPLOAD,
            dlg.direction());
    }

    @Test
    void switchingToDownloadShowsSelectiveAccessSection() {
        interact(() -> { dlg = new TransferStartDialog(owner, false); dlg.showForTest(); });
        assertFalse(dlg.selectiveAccessVisible(),
            "selective access hidden by default (upload selected)");
        interact(() -> dlg.setDirection(TransferStartDialog.Direction.DOWNLOAD));
        assertTrue(dlg.selectiveAccessVisible(),
            "selective access visible when direction = download");
    }

    @Test
    void scopeDefaultsToConnectedWhenSessionExists() {
        interact(() -> { dlg = new TransferStartDialog(owner, /*connected=*/true); dlg.showForTest(); });
        assertEquals(TransferStartDialog.Scope.CONNECTED, dlg.scope());
    }

    @Test
    void scopeDefaultsToAnonymousWhenOffline() {
        interact(() -> { dlg = new TransferStartDialog(owner, /*connected=*/false); dlg.showForTest(); });
        assertEquals(TransferStartDialog.Scope.ANONYMOUS_URL, dlg.scope());
    }

    @Test
    void submitDisabledWhenNoSourceSelected() {
        interact(() -> { dlg = new TransferStartDialog(owner, true); dlg.showForTest(); });
        assertTrue(dlg.submitButton().isDisabled());
    }
}
```

- [ ] **Step 2: Run, fail, implement, run, pass**

`TransferStartDialog.java`:
```java
package global.thalion.ttio.browser.workbench;

import javafx.geometry.Insets;
import javafx.scene.Scene;
import javafx.scene.control.*;
import javafx.scene.layout.*;
import javafx.stage.Modality;
import javafx.stage.Stage;
import javafx.stage.Window;

public final class TransferStartDialog {

    public enum Direction { UPLOAD, DOWNLOAD }
    public enum Scope { CONNECTED, ANONYMOUS_URL }

    private final Stage stage = new Stage();
    private final ToggleGroup dirGroup = new ToggleGroup();
    private final RadioButton uploadRadio = new RadioButton("Upload");
    private final RadioButton downloadRadio = new RadioButton("Download");
    private final ToggleGroup scopeGroup = new ToggleGroup();
    private final RadioButton connectedRadio = new RadioButton("Connected workbench");
    private final RadioButton anonymousRadio = new RadioButton("Anonymous URL");
    private final TextField sourceField = new TextField();
    private final Button browseBtn = new Button("Browse…");
    private final SelectiveAccessPanel selectiveAccess = new SelectiveAccessPanel();
    private final Button submitBtn = new Button("Submit");
    private final Button cancelBtn = new Button("Cancel");
    private final VBox body = new VBox(12);

    private Direction direction;
    private Scope scope;

    public TransferStartDialog(Window owner, boolean connected) {
        uploadRadio.setToggleGroup(dirGroup);
        downloadRadio.setToggleGroup(dirGroup);
        connectedRadio.setToggleGroup(scopeGroup);
        anonymousRadio.setToggleGroup(scopeGroup);

        uploadRadio.setSelected(true);
        direction = Direction.UPLOAD;
        if (connected) { connectedRadio.setSelected(true); scope = Scope.CONNECTED; }
        else          { anonymousRadio.setSelected(true); scope = Scope.ANONYMOUS_URL; }

        dirGroup.selectedToggleProperty().addListener((o, a, b) -> {
            direction = uploadRadio.isSelected() ? Direction.UPLOAD : Direction.DOWNLOAD;
            refreshSections();
        });
        scopeGroup.selectedToggleProperty().addListener((o, a, b) -> {
            scope = connectedRadio.isSelected() ? Scope.CONNECTED : Scope.ANONYMOUS_URL;
        });
        sourceField.textProperty().addListener((o, a, b) -> refreshSubmitEnabled());
        cancelBtn.setOnAction(e -> stage.close());

        HBox dirRow = new HBox(12, new Label("Direction:"), uploadRadio, downloadRadio);
        HBox scopeRow = new HBox(12, new Label("Server scope:"), connectedRadio, anonymousRadio);
        HBox sourceRow = new HBox(8, new Label("Source:"), sourceField, browseBtn);
        HBox actions = new HBox(8, submitBtn, cancelBtn);
        body.setPadding(new Insets(16));
        body.getChildren().addAll(dirRow, scopeRow, sourceRow, selectiveAccess.node(), actions);

        stage.initOwner(owner);
        stage.initModality(Modality.WINDOW_MODAL);
        stage.setScene(new Scene(body, 600, 480));
        stage.setTitle("Start new transfer");

        refreshSections();
        refreshSubmitEnabled();
    }

    public void show() { stage.showAndWait(); }
    public void showForTest() { stage.show(); }

    public Direction direction() { return direction; }
    public Scope scope() { return scope; }
    public boolean selectiveAccessVisible() { return selectiveAccess.node().isVisible(); }
    public Button submitButton() { return submitBtn; }

    public void setDirection(Direction d) {
        direction = d;
        (d == Direction.UPLOAD ? uploadRadio : downloadRadio).setSelected(true);
    }

    private void refreshSections() {
        boolean dl = direction == Direction.DOWNLOAD;
        selectiveAccess.node().setVisible(dl);
        selectiveAccess.node().setManaged(dl);
    }

    private void refreshSubmitEnabled() {
        submitBtn.setDisable(sourceField.getText().isBlank());
    }
}
```

Add a `node()` accessor to `SelectiveAccessPanel` if it doesn't already expose its root `Region`.

- [ ] **Step 3: Commit**

```bash
cd ~/TTI-O
git add tio-browser/src/main/java/global/thalion/ttio/browser/workbench/TransferStartDialog.java \
        tio-browser/src/test/java/global/thalion/ttio/browser/workbench/TransferStartDialogTest.java \
        tio-browser/src/main/java/global/thalion/ttio/browser/workbench/SelectiveAccessPanel.java
git commit -m "feat(tio-browser/workbench): TransferStartDialog skeleton (direction + scope + selective access)"
```

### Task 3.2: Wire `TransferStartDialog.submit()` → `TransferManager`

**Files:**
- Modify: `tio-browser/src/main/java/global/thalion/ttio/browser/workbench/TransferStartDialog.java`
- Modify: `tio-browser/src/test/java/global/thalion/ttio/browser/workbench/TransferStartDialogTest.java`

- [ ] **Step 1: Add the failing test**

```java
@Test
void submitEnqueuesTransferIntoManager() {
    TransferManager tm = TransferManager.instance();
    tm.clearAllForTest();
    interact(() -> { dlg = new TransferStartDialog(owner, true); dlg.showForTest(); });
    interact(() -> {
        dlg.setSourceForTest("/tmp/some.tio");
        dlg.setProjectForTest("ADNI");
        dlg.setUriForTest("uri:tio:adni/x");
    });
    interact(() -> dlg.submitButton().fire());
    assertEquals(1, tm.allTransfers().size());
}
```

- [ ] **Step 2: Add setters + submit handler**

```java
public void setSourceForTest(String s)  { sourceField.setText(s); }
public void setProjectForTest(String s) { projectField.setText(s); }
public void setUriForTest(String s)     { uriField.setText(s); }

// In constructor, attach:
submitBtn.setOnAction(e -> {
    Transfer t = (direction == Direction.UPLOAD)
        ? TransferManager.instance().newUpload(
              java.nio.file.Paths.get(sourceField.getText()),
              projectField.getText(), uriField.getText())
        : TransferManager.instance().newDownload(
              uriField.getText(), java.nio.file.Paths.get(sourceField.getText()),
              selectiveAccess.snapshot());
    if (scope == Scope.ANONYMOUS_URL) t.setAnonymousUrl(urlField.getText(), tokenField.getText());
    TransferManager.instance().submit(t);
    stage.close();
});
```

(Add `projectField`, `uriField`, `urlField`, `tokenField` to the dialog UI; show/hide URL+token rows when scope=ANONYMOUS_URL.)

- [ ] **Step 3: Run, pass, commit**

```bash
cd ~/TTI-O
git add tio-browser/src/main/java/global/thalion/ttio/browser/workbench/TransferStartDialog.java \
        tio-browser/src/test/java/global/thalion/ttio/browser/workbench/TransferStartDialogTest.java
git commit -m "feat(tio-browser/workbench): TransferStartDialog submit enqueues into TransferManager"
```

### Task 3.3: Build `TransfersWorkspace` content

**Files:**
- Modify: `tio-browser/src/main/java/global/thalion/ttio/browser/shell/workspaces/TransfersWorkspace.java`
- Create: `tio-browser/src/test/java/global/thalion/ttio/browser/shell/workspaces/TransfersWorkspaceTest.java`

- [ ] **Step 1: Write the failing test**

```java
package global.thalion.ttio.browser.shell.workspaces;

import global.thalion.ttio.browser.workbench.TransferManager;
import javafx.scene.Scene;
import javafx.stage.Stage;
import org.junit.jupiter.api.Test;
import org.testfx.framework.junit5.ApplicationTest;
import static org.junit.jupiter.api.Assertions.*;

class TransfersWorkspaceTest extends ApplicationTest {

    private TransfersWorkspace ws;

    @Override
    public void start(Stage stage) {
        TransferManager.instance().clearAllForTest();
        ws = new TransfersWorkspace();
        stage.setScene(new Scene(ws.node(), 1000, 600));
        stage.show();
    }

    @Test
    void emptyStateShowsCenteredStartNewTransferButton() {
        assertNotNull(ws.startNewButtonForTest());
        assertTrue(ws.startNewButtonForTest().isVisible());
        assertEquals(0, ws.tableForTest().getItems().size());
    }

    @Test
    void newTransferAppearsInTable() {
        var t = TransferManager.instance().newFakeUploadForTest(1000L);
        interact(() -> TransferManager.instance().startForTest(t));
        assertEquals(1, ws.tableForTest().getItems().size());
    }
}
```

- [ ] **Step 2: Implement**

Replace the placeholder body of `TransfersWorkspace` with a `BorderPane` containing:
- Top: an `HBox` with `Start new transfer…` button + filter `ChoiceBox` (All/Active/Completed/Failed) + `Clear completed` button.
- Centre: a `TableView<Transfer>` bound to `TransferManager.instance().observableList()`. Columns: direction, name, project/URL, progress (`ProgressDisplay` per row), state, started, finished.
- Right (slide-out on row selection): detail panel with the full `ProgressDisplay`, dialog parameters echo, and Pause/Resume/Cancel/Retry buttons.

(Add `observableList()` to `TransferManager` returning a `javafx.collections.ObservableList<Transfer>` if it doesn't already.)

`Start new transfer…` opens `TransferStartDialog` with `connected = ConnectionManager.instance().isConnected()`.

- [ ] **Step 3: Run, pass, commit**

```bash
cd ~/TTI-O
git add tio-browser/src/main/java/global/thalion/ttio/browser/shell/workspaces/TransfersWorkspace.java \
        tio-browser/src/test/java/global/thalion/ttio/browser/shell/workspaces/TransfersWorkspaceTest.java \
        tio-browser/src/main/java/global/thalion/ttio/browser/workbench/TransferManager.java
git commit -m "feat(tio-browser/shell): TransfersWorkspace content (table + start dialog + filters)"
```

### Task 3.4: Delete legacy `transport.UploadDialog` and `transport.DownloadDialog`

**Files:**
- Delete: `tio-browser/src/main/java/global/thalion/ttio/browser/transport/UploadDialog.java`
- Delete: `tio-browser/src/main/java/global/thalion/ttio/browser/transport/DownloadDialog.java`
- Delete: `tio-browser/src/test/java/global/thalion/ttio/browser/transport/UploadDialogTest.java`
- Delete: `tio-browser/src/test/java/global/thalion/ttio/browser/transport/DownloadDialogTest.java`
- Verify the underlying `transport.UploadTask` / `transport.DownloadTask` are still used by `TransferManager`.

- [ ] **Step 1: Search for usages**

```bash
cd ~/TTI-O && grep -rn "transport.UploadDialog\|transport.DownloadDialog" tio-browser/src/
```
Expected: only `MainWindow` (now using `TransferStartDialog`) and the dialog tests themselves.

- [ ] **Step 2: Delete the four files**

```bash
cd ~/TTI-O
git rm tio-browser/src/main/java/global/thalion/ttio/browser/transport/UploadDialog.java \
       tio-browser/src/main/java/global/thalion/ttio/browser/transport/DownloadDialog.java \
       tio-browser/src/test/java/global/thalion/ttio/browser/transport/UploadDialogTest.java \
       tio-browser/src/test/java/global/thalion/ttio/browser/transport/DownloadDialogTest.java
```

- [ ] **Step 3: Run all tests**

```bash
cd ~/TTI-O/tio-browser && mvn -B test \
    -Dhdf5.jar=/usr/share/java/jarhdf5.jar
```
Expected: **BUILD SUCCESS**.

- [ ] **Step 4: Commit**

```bash
git commit -m "refactor(tio-browser/transport): delete legacy UploadDialog + DownloadDialog

Replaced by unified TransferStartDialog in workbench package. Underlying
TisHttpUploader / TisWsUploader / UploadTask / DownloadTask retained."
```

### Task 3.5: Delete `workbench.UploadStartDialog` and `workbench.DownloadStartDialog`

Same pattern as 3.4 — delete the two files and their tests; verify nothing references them; commit.

```bash
cd ~/TTI-O
git rm tio-browser/src/main/java/global/thalion/ttio/browser/workbench/UploadStartDialog.java \
       tio-browser/src/main/java/global/thalion/ttio/browser/workbench/DownloadStartDialog.java \
       tio-browser/src/test/java/global/thalion/ttio/browser/workbench/UploadDownloadDialogTest.java
cd ~/TTI-O/tio-browser && mvn -B test -Dhdf5.jar=/usr/share/java/jarhdf5.jar
cd ~/TTI-O && git commit -m "refactor(tio-browser/workbench): delete legacy Upload/Download StartDialogs"
```

### Task 3.6: Reduce `workbench.TransferQueueView` to a content provider (no Stage)

**Files:**
- Modify: `tio-browser/src/main/java/global/thalion/ttio/browser/workbench/TransferQueueView.java`
- Modify: `tio-browser/src/test/java/global/thalion/ttio/browser/workbench/TransferQueueProgressTest.java`

Extract the inner content (table + filters) into the new `TransfersWorkspace`. If the existing class still has unique responsibilities (e.g. queue-state observers), keep them as a helper but remove the `Stage` field and `show()` method. Otherwise, delete the class entirely.

- [ ] **Step 1: Decide deletion vs reduction**

```bash
cd ~/TTI-O && grep -rn "TransferQueueView" tio-browser/src/
```
If the only references are the deleted `MainWindow` path and self-test, delete.

- [ ] **Step 2: If delete:**

```bash
git rm tio-browser/src/main/java/global/thalion/ttio/browser/workbench/TransferQueueView.java
# Keep TransferQueueProgressTest if it now asserts TransfersWorkspace behaviour; otherwise delete.
```

- [ ] **Step 3: Run tests, commit**

```bash
cd ~/TTI-O/tio-browser && mvn -B test -Dhdf5.jar=/usr/share/java/jarhdf5.jar
cd ~/TTI-O && git commit -m "refactor(tio-browser/workbench): drop TransferQueueView Stage in favour of TransfersWorkspace"
```

### Task 3.7: Stage 3 regression gate

```bash
cd ~/TTI-O/tio-browser && mvn -B test -Dhdf5.jar=/usr/share/java/jarhdf5.jar && \
cd ~/TTI-O && git tag stage-3-transfers
```

---

# Stage 4 — JobsWorkspace

Goal: move `JobMonitor`, `SessionList`, `JobEventsView` content into `JobsWorkspace`. `PipelineLauncher` and `SessionLauncher` stay as modals invoked from inside the workspace.

### Task 4.1: Extract `JobMonitor` content into a `Region`-returning method

**Files:**
- Modify: `tio-browser/src/main/java/global/thalion/ttio/browser/workbench/JobMonitor.java`

- [ ] **Step 1: Refactor**

Split the existing class so the inner content is constructed by a static factory:
```java
public static Region buildContent(ConnectionManager mgr, Window owner) {
    /* return what used to be inside the Stage's Scene */
}
```
Keep the existing `Stage`-based constructor for now (tests using it still pass).

- [ ] **Step 2: Run existing `JobMonitorTest` — should still pass**

```bash
cd ~/TTI-O/tio-browser && mvn -B test -Dtest=JobMonitorTest -Dhdf5.jar=/usr/share/java/jarhdf5.jar
```

- [ ] **Step 3: Commit**

```bash
cd ~/TTI-O
git add tio-browser/src/main/java/global/thalion/ttio/browser/workbench/JobMonitor.java
git commit -m "refactor(tio-browser/workbench): extract JobMonitor.buildContent for workspace embedding"
```

### Task 4.2: Same extraction for `SessionList` and `JobEventsView`

Apply the same `buildContent(...)` factory pattern. One commit each:
- `refactor(tio-browser/workbench): extract SessionList.buildContent`
- `refactor(tio-browser/workbench): extract JobEventsView.buildContent`

### Task 4.3: Build `JobsWorkspace`

**Files:**
- Modify: `tio-browser/src/main/java/global/thalion/ttio/browser/shell/workspaces/JobsWorkspace.java`
- Create: `tio-browser/src/test/java/global/thalion/ttio/browser/shell/workspaces/JobsWorkspaceTest.java`

- [ ] **Step 1: Write the failing test**

```java
package global.thalion.ttio.browser.shell.workspaces;

import javafx.scene.Scene;
import javafx.stage.Stage;
import org.junit.jupiter.api.Test;
import org.testfx.framework.junit5.ApplicationTest;
import static org.junit.jupiter.api.Assertions.*;

class JobsWorkspaceTest extends ApplicationTest {

    private JobsWorkspace ws;

    @Override
    public void start(Stage stage) {
        ws = new JobsWorkspace(stage);
        stage.setScene(new Scene(ws.node(), 1000, 700));
        stage.show();
    }

    @Test
    void hasJobsTableAndSessionsTableAndNewButtons() {
        assertNotNull(ws.jobsTableForTest());
        assertNotNull(ws.sessionsTableForTest());
        assertNotNull(ws.newJobButtonForTest());
        assertNotNull(ws.newSessionButtonForTest());
    }
}
```

- [ ] **Step 2: Implement `JobsWorkspace`**

```java
package global.thalion.ttio.browser.shell.workspaces;

import global.thalion.ttio.browser.shell.Workspace;
import global.thalion.ttio.browser.workbench.*;
import javafx.geometry.Orientation;
import javafx.scene.control.*;
import javafx.scene.layout.*;
import javafx.stage.Window;

public final class JobsWorkspace implements Workspace {

    private final SplitPane root = new SplitPane();
    private final Button newJob = new Button("New job…");
    private final Button newSession = new Button("New session…");
    private final Region jobsContent;
    private final Region sessionsContent;
    private final Window owner;

    public JobsWorkspace(Window owner) {
        this.owner = owner;
        jobsContent = JobMonitor.buildContent(ConnectionManager.instance(), owner);
        sessionsContent = SessionList.buildContent(ConnectionManager.instance(), owner);
        BorderPane jobsPane = new BorderPane(jobsContent);
        BorderPane jobsHeader = new BorderPane();
        jobsHeader.setLeft(new Label("Jobs"));
        jobsHeader.setRight(newJob);
        jobsPane.setTop(jobsHeader);

        BorderPane sessionsPane = new BorderPane(sessionsContent);
        BorderPane sessionsHeader = new BorderPane();
        sessionsHeader.setLeft(new Label("Interactive sessions"));
        sessionsHeader.setRight(newSession);
        sessionsPane.setTop(sessionsHeader);

        root.setOrientation(Orientation.VERTICAL);
        root.getItems().addAll(jobsPane, sessionsPane);
        root.setDividerPositions(0.60);

        newJob.setOnAction(e -> new PipelineLauncher(owner).show());
        newSession.setOnAction(e -> new SessionLauncher(owner).show());
    }

    public String key()      { return "jobs"; }
    public String tooltip()  { return "Jobs & Sessions"; }
    public String iconText() { return "⚙"; }
    public Region node()     { return root; }
    public void onShow()     {}
    public void onHide()     {}

    public Button newJobButtonForTest()     { return newJob; }
    public Button newSessionButtonForTest() { return newSession; }
    public Region jobsContentForTest()      { return jobsContent; }
    public Region sessionsContentForTest()  { return sessionsContent; }
    public TableView<?> jobsTableForTest()     { return findTable(jobsContent); }
    public TableView<?> sessionsTableForTest() { return findTable(sessionsContent); }

    private static TableView<?> findTable(javafx.scene.Node n) {
        if (n instanceof TableView<?> t) return t;
        if (n instanceof Parent p) {
            for (var c : p.getChildrenUnmodifiable()) {
                TableView<?> r = findTable(c);
                if (r != null) return r;
            }
        }
        return null;
    }
}
```

- [ ] **Step 3: Wire into `MainWindow`** — update `MainWindow` to use this in the constructor list passed to `AppShell.create(...)`:
```java
this.shell = AppShell.create(List.of(
    new ContainersWorkspace(),
    new CohortsWorkspace(),
    new JobsWorkspace(primaryStage),
    new TransfersWorkspace()));
```
(Pass the stage so the workspace can own modals.)

- [ ] **Step 4: Run, pass, commit**

```bash
cd ~/TTI-O
git add tio-browser/src/main/java/global/thalion/ttio/browser/shell/workspaces/JobsWorkspace.java \
        tio-browser/src/test/java/global/thalion/ttio/browser/shell/workspaces/JobsWorkspaceTest.java \
        tio-browser/src/main/java/global/thalion/ttio/browser/MainWindow.java
git commit -m "feat(tio-browser/shell): JobsWorkspace embeds JobMonitor + SessionList"
```

### Task 4.4: Delete the three Stage wrappers

```bash
cd ~/TTI-O
git rm tio-browser/src/main/java/global/thalion/ttio/browser/workbench/JobMonitor.java \
       tio-browser/src/main/java/global/thalion/ttio/browser/workbench/SessionList.java \
       tio-browser/src/main/java/global/thalion/ttio/browser/workbench/JobEventsView.java
```

Wait — these are needed for `buildContent`. Restructure: move the `buildContent` methods to small helper classes (`JobMonitorContent`, `SessionListContent`, `JobEventsViewContent`) in `workbench/`, then delete the `Stage`-bearing originals. Update workspace to call the helpers.

Adjust tests (`JobMonitorTest`, `SessionListTest`, `JobEventsViewTest`) to assert content-helper behaviour instead of opening a `Stage`. Commit.

```bash
git commit -m "refactor(tio-browser/workbench): drop JobMonitor/SessionList/JobEventsView Stage wrappers"
```

### Task 4.5: Stage 4 regression gate

```bash
cd ~/TTI-O/tio-browser && mvn -B test -Dhdf5.jar=/usr/share/java/jarhdf5.jar && \
cd ~/TTI-O && git tag stage-4-jobs
```

---

# Stage 5 — CohortsWorkspace

Goal: extract `CohortQueryBuilder` content into `CohortsWorkspace`. `LoginDialog` stays modal.

### Task 5.1: Extract `CohortQueryBuilder.buildContent(...)`

Same refactor pattern as Task 4.1. Commit:
`refactor(tio-browser/workbench): extract CohortQueryBuilder.buildContent`.

### Task 5.2: Build `CohortsWorkspace`

**Files:**
- Modify: `tio-browser/src/main/java/global/thalion/ttio/browser/shell/workspaces/CohortsWorkspace.java`
- Create: `tio-browser/src/test/java/global/thalion/ttio/browser/shell/workspaces/CohortsWorkspaceTest.java`

- [ ] **Step 1: Write the failing test**

```java
package global.thalion.ttio.browser.shell.workspaces;

import global.thalion.ttio.browser.workbench.ConnectionManager;
import javafx.scene.Scene;
import javafx.stage.Stage;
import org.junit.jupiter.api.Test;
import org.testfx.framework.junit5.ApplicationTest;
import static org.junit.jupiter.api.Assertions.*;

class CohortsWorkspaceTest extends ApplicationTest {

    private CohortsWorkspace ws;

    @Override
    public void start(Stage stage) {
        ConnectionManager.instance().disconnect();
        ws = new CohortsWorkspace(stage);
        stage.setScene(new Scene(ws.node(), 1000, 700));
        stage.show();
    }

    @Test
    void offlineStateShowsConnectCta() {
        assertTrue(ws.connectCtaForTest().isVisible(),
            "offline -> Connect CTA visible");
    }

    @Test
    void onlineStateShowsBuilder() {
        interact(() -> ConnectionManager.instance().injectTestSession(
            "alice", "biobank.thalion.org"));
        assertFalse(ws.connectCtaForTest().isVisible());
        assertTrue(ws.builderRegionForTest().isVisible());
    }
}
```

- [ ] **Step 2: Implement**

```java
package global.thalion.ttio.browser.shell.workspaces;

import global.thalion.ttio.browser.shell.Workspace;
import global.thalion.ttio.browser.workbench.*;
import javafx.scene.control.*;
import javafx.scene.layout.*;
import javafx.stage.Window;

public final class CohortsWorkspace implements Workspace {

    private final StackPane root = new StackPane();
    private final BorderPane connected = new BorderPane();
    private final VBox offlineCta = new VBox(12);
    private final Button connectBtn = new Button("Connect…");
    private final Region savedList;
    private final Region builder;
    private final Region resultPreview;

    public CohortsWorkspace(Window owner) {
        offlineCta.setAlignment(javafx.geometry.Pos.CENTER);
        offlineCta.getChildren().addAll(
            new Label("Connect to a workbench server to build cohort queries."),
            connectBtn);
        connectBtn.setOnAction(e -> new LoginDialog(owner).showAndConnect(s -> {}));

        savedList = SavedCohortsList.buildContent(ConnectionManager.instance());
        builder = CohortQueryBuilder.buildContent(ConnectionManager.instance(), owner);
        resultPreview = CohortQueryBuilder.buildResultPreview();
        BorderPane center = new BorderPane(builder);
        center.setBottom(resultPreview);
        connected.setLeft(savedList);
        connected.setCenter(center);

        root.getChildren().addAll(connected, offlineCta);
        refresh();
        ConnectionManager.instance().addListener(s -> javafx.application.Platform.runLater(this::refresh));
    }

    public String key()      { return "cohorts"; }
    public String tooltip()  { return "Cohorts"; }
    public String iconText() { return "🔬"; }
    public Region node()     { return root; }
    public void onShow()     {}
    public void onHide()     {}

    public VBox connectCtaForTest() { return offlineCta; }
    public BorderPane builderRegionForTest() { return connected; }

    private void refresh() {
        boolean online = ConnectionManager.instance().isConnected();
        offlineCta.setVisible(!online);  offlineCta.setManaged(!online);
        connected.setVisible(online);    connected.setManaged(online);
    }
}
```

(`SavedCohortsList` is a new tiny class in `workbench/` — table bound to `GET /v1/cohorts`. `CohortQueryBuilder.buildResultPreview()` is extracted from the existing builder's bottom panel.)

- [ ] **Step 3: Run, pass, commit**

```bash
git commit -m "feat(tio-browser/shell): CohortsWorkspace with offline CTA + builder + result preview"
```

### Task 5.3: Delete `CohortQueryBuilder` Stage wrapper

Same pattern — move the `buildContent` body to a new `CohortQueryBuilderContent` helper, delete the `Stage`-bearing class. Update tests. Commit.

### Task 5.4: Stage 5 regression gate

```bash
cd ~/TTI-O/tio-browser && mvn -B test -Dhdf5.jar=/usr/share/java/jarhdf5.jar && \
cd ~/TTI-O && git tag stage-5-cohorts
```

---

# Stage 6 — Unified Container Tree

Goal: replace the `ContainersWorkspace` stub content with the real unified tree (Local + Servers branches) plus three new detail tabs. Delete `ContainerBrowser` Stage.

### Task 6.1: `UnifiedContainerNode` sealed hierarchy

**Files:**
- Create: `tio-browser/src/main/java/global/thalion/ttio/browser/shell/containers/UnifiedContainerNode.java`
- Create: `tio-browser/src/test/java/global/thalion/ttio/browser/shell/containers/UnifiedContainerNodeTest.java`

- [ ] **Step 1: Write the failing test**

```java
package global.thalion.ttio.browser.shell.containers;

import org.junit.jupiter.api.Test;
import static org.junit.jupiter.api.Assertions.*;

class UnifiedContainerNodeTest {

    @Test
    void localRootIsAGroup() {
        var n = new UnifiedContainerNode.LocalRoot();
        assertEquals("Local", n.displayName());
        assertEquals(UnifiedContainerNode.Kind.GROUP, n.kind());
    }

    @Test
    void serverContainerCarriesUri() {
        var n = new UnifiedContainerNode.ServerContainer(
            "uri:tio:adni/x", "X-001", 134_217_728L);
        assertEquals("uri:tio:adni/x", n.uri());
        assertEquals(UnifiedContainerNode.Kind.CONTAINER, n.kind());
    }

    @Test
    void actionNodeMarksItselfAsAction() {
        var n = new UnifiedContainerNode.OpenLocalAction();
        assertEquals(UnifiedContainerNode.Kind.ACTION, n.kind());
    }
}
```

- [ ] **Step 2: Implement**

```java
package global.thalion.ttio.browser.shell.containers;

public sealed interface UnifiedContainerNode {

    enum Kind { GROUP, ACTION, CONTAINER, PROJECT, SERVER, LOCAL_FILE, RECENT }

    String displayName();
    Kind kind();

    final record LocalRoot() implements UnifiedContainerNode {
        public String displayName() { return "Local"; }
        public Kind kind() { return Kind.GROUP; }
    }
    final record LocalOpenFile(String path) implements UnifiedContainerNode {
        public String displayName() { return java.nio.file.Paths.get(path).getFileName().toString(); }
        public Kind kind() { return Kind.LOCAL_FILE; }
    }
    final record LocalRecentGroup() implements UnifiedContainerNode {
        public String displayName() { return "Recent"; }
        public Kind kind() { return Kind.GROUP; }
    }
    final record LocalRecentEntry(String path) implements UnifiedContainerNode {
        public String displayName() { return java.nio.file.Paths.get(path).getFileName().toString(); }
        public Kind kind() { return Kind.RECENT; }
    }
    final record OpenLocalAction() implements UnifiedContainerNode {
        public String displayName() { return "+ Open file…"; }
        public Kind kind() { return Kind.ACTION; }
    }
    final record EncodeLocalAction() implements UnifiedContainerNode {
        public String displayName() { return "+ Encode…"; }
        public Kind kind() { return Kind.ACTION; }
    }
    final record ImportLocalAction() implements UnifiedContainerNode {
        public String displayName() { return "+ Import…"; }
        public Kind kind() { return Kind.ACTION; }
    }
    final record ServersRoot() implements UnifiedContainerNode {
        public String displayName() { return "Servers"; }
        public Kind kind() { return Kind.GROUP; }
    }
    final record ServerRoot(String userAtHost) implements UnifiedContainerNode {
        public String displayName() { return userAtHost; }
        public Kind kind() { return Kind.SERVER; }
    }
    final record ServerProject(String name, int containerCount) implements UnifiedContainerNode {
        public String displayName() { return "Project: " + name + " (" + containerCount + ")"; }
        public Kind kind() { return Kind.PROJECT; }
    }
    final record ServerContainer(String uri, String displayName, long sizeBytes)
            implements UnifiedContainerNode {
        public Kind kind() { return Kind.CONTAINER; }
    }
    final record ServerConnectAction() implements UnifiedContainerNode {
        public String displayName() { return "+ Connect another server…"; }
        public Kind kind() { return Kind.ACTION; }
    }
}
```

- [ ] **Step 3: Run, pass, commit**

```bash
cd ~/TTI-O
git add tio-browser/src/main/java/global/thalion/ttio/browser/shell/containers/UnifiedContainerNode.java \
        tio-browser/src/test/java/global/thalion/ttio/browser/shell/containers/UnifiedContainerNodeTest.java
git commit -m "feat(tio-browser/shell/containers): UnifiedContainerNode sealed hierarchy"
```

### Task 6.2: `UnifiedContainerTreeView`

**Files:**
- Create: `tio-browser/src/main/java/global/thalion/ttio/browser/shell/containers/UnifiedContainerTreeView.java`
- Create: `tio-browser/src/test/java/global/thalion/ttio/browser/shell/containers/UnifiedContainerTreeViewTest.java`

- [ ] **Step 1: Write the failing test**

```java
package global.thalion.ttio.browser.shell.containers;

import global.thalion.ttio.browser.workbench.ConnectionManager;
import javafx.scene.Scene;
import javafx.scene.control.TreeItem;
import javafx.stage.Stage;
import org.junit.jupiter.api.Test;
import org.testfx.framework.junit5.ApplicationTest;
import static org.junit.jupiter.api.Assertions.*;

class UnifiedContainerTreeViewTest extends ApplicationTest {

    private UnifiedContainerTreeView view;

    @Override
    public void start(Stage stage) {
        ConnectionManager.instance().disconnect();
        view = new UnifiedContainerTreeView();
        stage.setScene(new Scene(view.control(), 320, 600));
        stage.show();
    }

    @Test
    void rootHasLocalAndServersBranches() {
        TreeItem<UnifiedContainerNode> root = view.control().getRoot();
        assertEquals(2, root.getChildren().size());
        assertInstanceOf(UnifiedContainerNode.LocalRoot.class,
            root.getChildren().get(0).getValue());
        assertInstanceOf(UnifiedContainerNode.ServersRoot.class,
            root.getChildren().get(1).getValue());
    }

    @Test
    void localBranchHasOpenAndEncodeAndImportActionNodes() {
        TreeItem<UnifiedContainerNode> local = view.control().getRoot().getChildren().get(0);
        boolean hasOpen = local.getChildren().stream()
            .anyMatch(i -> i.getValue() instanceof UnifiedContainerNode.OpenLocalAction);
        boolean hasEncode = local.getChildren().stream()
            .anyMatch(i -> i.getValue() instanceof UnifiedContainerNode.EncodeLocalAction);
        boolean hasImport = local.getChildren().stream()
            .anyMatch(i -> i.getValue() instanceof UnifiedContainerNode.ImportLocalAction);
        assertTrue(hasOpen && hasEncode && hasImport);
    }

    @Test
    void serversBranchOfflineShowsConnectAction() {
        TreeItem<UnifiedContainerNode> servers = view.control().getRoot().getChildren().get(1);
        assertEquals(1, servers.getChildren().size());
        assertInstanceOf(UnifiedContainerNode.ServerConnectAction.class,
            servers.getChildren().get(0).getValue());
    }
}
```

- [ ] **Step 2: Implement**

```java
package global.thalion.ttio.browser.shell.containers;

import global.thalion.ttio.browser.workbench.ConnectionListener;
import global.thalion.ttio.browser.workbench.ConnectionManager;
import javafx.application.Platform;
import javafx.scene.control.TreeCell;
import javafx.scene.control.TreeItem;
import javafx.scene.control.TreeView;

public final class UnifiedContainerTreeView {

    private final TreeView<UnifiedContainerNode> tree = new TreeView<>();
    private final ConnectionManager manager;
    private final ConnectionListener listener;
    private TreeItem<UnifiedContainerNode> localRoot;
    private TreeItem<UnifiedContainerNode> serversRoot;

    public UnifiedContainerTreeView() {
        this(ConnectionManager.instance());
    }

    public UnifiedContainerTreeView(ConnectionManager manager) {
        this.manager = manager;
        TreeItem<UnifiedContainerNode> hiddenRoot = new TreeItem<>(null);
        localRoot   = new TreeItem<>(new UnifiedContainerNode.LocalRoot());
        serversRoot = new TreeItem<>(new UnifiedContainerNode.ServersRoot());
        hiddenRoot.getChildren().addAll(localRoot, serversRoot);
        tree.setRoot(hiddenRoot);
        tree.setShowRoot(false);
        tree.setCellFactory(t -> new ActionStyledCell());

        seedLocalBranch();
        seedServersBranch();

        this.listener = s -> Platform.runLater(this::seedServersBranch);
        manager.addListener(listener);
    }

    public TreeView<UnifiedContainerNode> control() { return tree; }

    public void dispose() { manager.removeListener(listener); }

    public void setOpenFile(String path) {
        // Replace any existing LocalOpenFile child with this one
        localRoot.getChildren().removeIf(i ->
            i.getValue() instanceof UnifiedContainerNode.LocalOpenFile);
        if (path != null) {
            localRoot.getChildren().add(0,
                new TreeItem<>(new UnifiedContainerNode.LocalOpenFile(path)));
        }
    }

    private void seedLocalBranch() {
        localRoot.setExpanded(true);
        localRoot.getChildren().clear();
        TreeItem<UnifiedContainerNode> recent =
            new TreeItem<>(new UnifiedContainerNode.LocalRecentGroup());
        localRoot.getChildren().addAll(
            recent,
            new TreeItem<>(new UnifiedContainerNode.OpenLocalAction()),
            new TreeItem<>(new UnifiedContainerNode.EncodeLocalAction()),
            new TreeItem<>(new UnifiedContainerNode.ImportLocalAction()));
    }

    private void seedServersBranch() {
        serversRoot.setExpanded(true);
        serversRoot.getChildren().clear();
        if (manager.isConnected()) {
            String userAtHost = manager.session().username()
                + "@" + manager.client().host();
            TreeItem<UnifiedContainerNode> server =
                new TreeItem<>(new UnifiedContainerNode.ServerRoot(userAtHost));
            server.setExpanded(true);
            // Lazy: projects are fetched async; for now show a single Loading row
            server.getChildren().add(new TreeItem<>(new UnifiedContainerNode.ServerProject(
                "(loading…)", 0)));
            serversRoot.getChildren().add(server);
            // Kick off the actual fetch — populates when it completes
            loadProjects(server);
        }
        serversRoot.getChildren().add(
            new TreeItem<>(new UnifiedContainerNode.ServerConnectAction()));
    }

    private void loadProjects(TreeItem<UnifiedContainerNode> serverItem) {
        // Fire async, swap children when results arrive.
        // Implementation reuses ConnectionManager.client() REST helpers.
    }

    private static final class ActionStyledCell extends TreeCell<UnifiedContainerNode> {
        @Override protected void updateItem(UnifiedContainerNode item, boolean empty) {
            super.updateItem(item, empty);
            if (empty || item == null) {
                setText(null);
                setStyle("");
            } else {
                setText(item.displayName());
                if (item.kind() == UnifiedContainerNode.Kind.ACTION) {
                    setStyle("-fx-font-style: italic; -fx-text-fill: -fx-accent;");
                } else {
                    setStyle("");
                }
            }
        }
    }
}
```

- [ ] **Step 3: Run, pass, commit**

```bash
cd ~/TTI-O
git add tio-browser/src/main/java/global/thalion/ttio/browser/shell/containers/UnifiedContainerTreeView.java \
        tio-browser/src/test/java/global/thalion/ttio/browser/shell/containers/UnifiedContainerTreeViewTest.java
git commit -m "feat(tio-browser/shell/containers): UnifiedContainerTreeView with Local/Servers branches"
```

### Task 6.3: `LocalRootInfoTab` detail tab

**Files:**
- Create: `tio-browser/src/main/java/global/thalion/ttio/browser/view/LocalRootInfoTab.java`
- Create: `tio-browser/src/test/java/global/thalion/ttio/browser/view/LocalRootInfoTabTest.java`

Implement as an `AbstractDetailTab` that applies only when `selection.value() instanceof UnifiedContainerNode.LocalRoot`. Body: a centred `VBox` with a `Label` "Recent files:" + the recent-files list + three large buttons (`Open file…`, `Encode…`, `Import…`).

Test: assert tab applies for `LocalRoot` and renders three buttons.

Commit: `feat(tio-browser/view): LocalRootInfoTab — empty-state CTA for Local branch`.

### Task 6.4: `ProjectListingTab` (paged table)

**Files:**
- Create: `tio-browser/src/main/java/global/thalion/ttio/browser/view/ProjectListingTab.java`
- Create: `tio-browser/src/test/java/global/thalion/ttio/browser/view/ProjectListingTabTest.java`

Applies when `selection.value() instanceof UnifiedContainerNode.ServerProject`. Body: a `TableView<ContainerSummary>` columns `URI`, `Name`, `Size`, `Layers`, `Modified`; a `Load more…` button at the bottom that fetches the next page via `ConnectionManager.client().listContainers(project, cursor)`.

Selecting a row fires an event handler (set via `setOnContainerSelected(Consumer<ServerContainer>)`) that the workspace uses to set the detail-pane selection to `ServerContainerOverviewTab`.

Commit: `feat(tio-browser/view): ProjectListingTab — paged container table per project`.

### Task 6.5: `ServerContainerOverviewTab`

**Files:**
- Create: `tio-browser/src/main/java/global/thalion/ttio/browser/view/ServerContainerOverviewTab.java`
- Create: `tio-browser/src/test/java/global/thalion/ttio/browser/view/ServerContainerOverviewTabTest.java`

Applies when `selection.value() instanceof UnifiedContainerNode.ServerContainer`. Body: a `VBox` with metadata fields (URI, size, layer list, encryption status, provenance summary) and an action row of four buttons: `Download…`, `Selective download…`, `Export… (server-side)`, `Run pipeline…`. Each opens the corresponding dialog (`TransferStartDialog` pre-configured, `ExportPanel`, `PipelineLauncher`).

Commit: `feat(tio-browser/view): ServerContainerOverviewTab — server container detail + actions`.

### Task 6.6: Context menus on tree nodes

Modify `UnifiedContainerTreeView`'s cell factory to attach `ContextMenu`s per node kind, with the actions from spec §5.1's right-click table.

Add a `Consumer<UnifiedContainerNode>` action callback on the tree view so the workspace can implement the actions without the tree knowing about modals.

Test: select a `LocalOpenFile` node, right-click, assert context-menu items include `Save As…`, `Close`, `Export…`.

Commit: `feat(tio-browser/shell/containers): per-node context menus on UnifiedContainerTreeView`.

### Task 6.7: Replace `ContainersWorkspace` stub with the real tree

**Files:**
- Modify: `tio-browser/src/main/java/global/thalion/ttio/browser/shell/workspaces/ContainersWorkspace.java`

Replace the `DatasetTreeView` field with a `UnifiedContainerTreeView`. The detail pane gains the three new tabs (`LocalRootInfoTab`, `ProjectListingTab`, `ServerContainerOverviewTab`) alongside the existing ones.

When a `LocalOpenFile` node is selected, the existing `DatasetTreeBuilder.build(dataset)` is invoked to produce the local subtree, which is mounted as a sub-`TreeItem` under the `LocalOpenFile` node. Wait — actually the design says the local-file's internal structure is shown via the **detail pane's** existing tabs, not as tree descendants. Keep the unified tree shallow: `LocalOpenFile` is a leaf; opening it sets the workspace's `currentDataset` and the right-pane shows the existing `OverviewTab`, `MsHeadersTable`, etc.

(This means the existing `DatasetTreeNode` model continues to drive the detail pane via a per-leaf adapter — the unified tree replaces the **navigation** tree, not the **content** model.)

Wire all the action callbacks:
- `OpenLocalAction` → file chooser → `loadDataset`
- `EncodeLocalAction` → `new EncodingPanel(stage).show()`
- `ImportLocalAction` → `new ImportDialog(stage).showAndImport(...)`
- `ServerConnectAction` → `new LoginDialog(stage).showAndConnect(...)`
- `ServerProject` selection → shows `ProjectListingTab` with that project's containers
- `ServerContainer` selection (via row click in the table) → shows `ServerContainerOverviewTab`

Update `MainWindowOpenTest` and `SaveAsTest` if their accessor paths changed.

Commit: `feat(tio-browser/shell): ContainersWorkspace adopts UnifiedContainerTreeView + new detail tabs`.

### Task 6.8: Delete `workbench.ContainerBrowser` Stage

Same pattern as Stage 4. Move any reusable inner content into a helper or directly into `ProjectListingTab`, delete the `Stage`-bearing class and its test (or rewrite the test as a `ProjectListingTab` test).

```bash
cd ~/TTI-O
git rm tio-browser/src/main/java/global/thalion/ttio/browser/workbench/ContainerBrowser.java \
       tio-browser/src/test/java/global/thalion/ttio/browser/workbench/ContainerBrowserTest.java
cd ~/TTI-O/tio-browser && mvn -B test -Dhdf5.jar=/usr/share/java/jarhdf5.jar
cd ~/TTI-O && git commit -m "refactor(tio-browser/workbench): drop ContainerBrowser Stage"
```

### Task 6.9: Wire drag-drop and File-menu items to workspace actions

In `MainWindow`, add scene-level drag-drop handling that delegates to `ContainersWorkspace.handleDrop(File)`:
- `.tio` extension → `loadDataset(path, true)`.
- Other formats → open Import wizard with format pre-selected via `FormatSniffer`.

Wire `File → Encode…` → `containersWorkspace.startEncode(stage)` and `File → Import…` → `containersWorkspace.startImport(stage)`.

Commit: `feat(tio-browser/shell): drag-drop + File-menu Encode/Import wired through ContainersWorkspace`.

### Task 6.10: Stage 6 regression gate

```bash
cd ~/TTI-O/tio-browser && mvn -B test -Dhdf5.jar=/usr/share/java/jarhdf5.jar && \
cd ~/TTI-O && git tag stage-6-unified-tree
```

---

# Stage 7 — Polish

### Task 7.1: `RecentFiles` helper

**Files:**
- Create: `tio-browser/src/main/java/global/thalion/ttio/browser/util/RecentFiles.java`
- Create: `tio-browser/src/test/java/global/thalion/ttio/browser/util/RecentFilesTest.java`

- [ ] **Step 1: Write the failing test**

```java
package global.thalion.ttio.browser.util;

import org.junit.jupiter.api.Test;
import java.util.List;
import static org.junit.jupiter.api.Assertions.*;

class RecentFilesTest {

    @Test
    void recordsAndReturnsMostRecentFirstUpToCap() {
        RecentFiles r = new RecentFiles("test-cap-8", 8);
        r.clearForTest();
        r.record("/a.tio");
        r.record("/b.tio");
        r.record("/c.tio");
        assertEquals(List.of("/c.tio", "/b.tio", "/a.tio"), r.recent());
    }

    @Test
    void dedupesAndPromotesToFront() {
        RecentFiles r = new RecentFiles("test-dedup", 8);
        r.clearForTest();
        r.record("/a.tio");
        r.record("/b.tio");
        r.record("/a.tio");
        assertEquals(List.of("/a.tio", "/b.tio"), r.recent());
    }

    @Test
    void evictsOldestPastCap() {
        RecentFiles r = new RecentFiles("test-cap-3", 3);
        r.clearForTest();
        r.record("/1"); r.record("/2"); r.record("/3"); r.record("/4");
        assertEquals(List.of("/4", "/3", "/2"), r.recent());
    }
}
```

- [ ] **Step 2: Implement** using `java.util.prefs.Preferences.userNodeForPackage(RecentFiles.class).node(key)`. Store as a comma-separated list (paths don't legally contain commas in the relevant OSes' typical layouts; for safety, base64-encode each path).

- [ ] **Step 3: Run, pass, commit**

```bash
git commit -m "feat(tio-browser/util): RecentFiles persisted via java.util.prefs"
```

### Task 7.2: Wire `RecentFiles` into `LocalRootInfoTab` + `Open Recent` menu

`Open Recent ▸` becomes a dynamically-populated submenu: on menu-show, clear and rebuild from `RecentFiles.recent()`.

`LocalRootInfoTab` shows the same list as click-to-open items.

Both call `containersWorkspace.loadDataset(path, true)` then `RecentFiles.record(path)`.

Test: open two files, assert `Open Recent` submenu has both paths.

Commit: `feat(tio-browser): Open Recent submenu + Local recent list populated from RecentFiles`.

### Task 7.3: Keyboard shortcuts

Wire `File → Open…` to `Ctrl+O` (`KeyCombination.keyCombination("Shortcut+O")`), `File → Encode…` to `Shortcut+E`, `File → Close` to `Shortcut+W`, `File → Exit` to `Shortcut+Q`.

Test: programmatically fire the accelerator on the scene; assert the corresponding action ran.

Commit: `feat(tio-browser): keyboard shortcuts for File menu items`.

### Task 7.4: Empty/disconnected/error state verification pass

Walk through every row of the design spec §8 state catalogue. For any state not already covered by an existing test, add a focused test. No new functionality — just lock down current behaviour.

Commit per workspace: `test(tio-browser/shell): state catalogue coverage for <workspace>`.

### Task 7.5: Update `tio-browser/README.md` and `docs/tio-browser.md`

Rewrite both docs to reflect:
- The four-workspace shell (replace the menu-driven walkthrough).
- The `ProgressReport` numeric line on every long-running operation.
- The unified `TransferStartDialog`.

Commit: `docs(tio-browser): rewrite README + user guide for activity-rail shell`.

### Task 7.6: Final regression gate + release notes

```bash
cd ~/TTI-O/tio-browser && mvn -B test -Dhdf5.jar=/usr/share/java/jarhdf5.jar
cd ~/TTI-O && git tag stage-7-polish
```

Append a `[Unreleased]` entry to `tio-browser/CHANGELOG.md` (or `TTI-O/CHANGELOG.md` if shared) summarising the UX rationalization. Commit: `docs(tio-browser): changelog entry for UX rationalization`.

---

## Self-Review

(Performed after writing the plan, before handoff.)

1. **Spec coverage check.** Walked each section of the design spec:
   - §4 Shell — Tasks 2.2 (rail), 2.3 (chip), 2.4 (strip), 2.5 (AppShell), 2.7 (menu reduction). ✓
   - §5 Four activities — Tasks 2.8 (containers stub), 3.3 (transfers), 4.3 (jobs), 5.2 (cohorts), 6.7 (real containers). ✓
   - §6 Progress contract — Tasks 0.1–0.5 (infrastructure), 1.1–1.7 (wiring). ✓
   - §7 Action consolidation — covered by the workspace tasks; explicit deletions in 3.4, 3.5, 3.6, 4.4, 5.3, 6.8. ✓
   - §8 State catalogue — locked down in Task 7.4 with a verification pass. ✓
   - §9 Class-level changes — covered by file lists in each task. ✓
   - §10 Migration order — the plan stages 0–7 mirror the spec's stages 0–7 1:1. ✓
   - §11 Testing strategy — every new class has its own test; every deletion either deletes its test or rewrites it for the replacement. ✓

2. **Placeholder scan.** Looked for "TBD", "TODO", "add appropriate", etc. Two places in early drafts referenced a `// TODO Stage 6: re-wire` comment in `MainWindow`; replaced by an explicit instruction that the temporary methods are **deleted** in Stage 2.7 and re-introduced via the workspace in Stage 2.8.

3. **Type consistency.** Cross-checked method names referenced across stages: `ContainersWorkspace.loadDataset(path, readOnly)` is consistent in Stages 2.8 and 6.7; `TransferManager.observableList()`, `clearAllForTest()`, `newFakeUploadForTest()`, `startForTest()`, `fakeProgress()`, `addProgressListener()`, `addQueueListener()` are introduced in Task 2.4/2.7 and reused without rename in 3.3 and 5.2; `ProgressFormatter.line(report, nowEpochMs)` signature is consistent across 0.4, 0.5, and TransferStrip in 2.4.

4. **Ambiguity check.** One real ambiguity: the design spec puts `ProjectListingTab` under "detail tabs" but also implies project-level navigation lives in the tree. The plan resolves it consistently — project tree nodes are leaves, container navigation is by table-row selection inside the detail tab.

---

## Execution Handoff

**Plan complete and saved to `docs/superpowers/plans/2026-05-24-tio-browser-ux-rationalization.md`. Two execution options:**

**1. Subagent-Driven (recommended)** — I dispatch a fresh subagent per task, review between tasks, fast iteration.

**2. Inline Execution** — Execute tasks in this session using executing-plans, batch execution with checkpoints.

**Which approach?**
