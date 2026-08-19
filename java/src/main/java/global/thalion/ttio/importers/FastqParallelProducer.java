// SPDX-License-Identifier: Apache-2.0
package global.thalion.ttio.importers;

import global.thalion.ttio.Enums.AcquisitionMode;
import global.thalion.ttio.Threads;
import global.thalion.ttio.genomics.WrittenGenomicRun;
import global.thalion.ttio.io.ProgressSink;

import java.io.IOException;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Path;
import java.util.ArrayDeque;
import java.util.ArrayList;
import java.util.Iterator;
import java.util.List;
import java.util.NoSuchElementException;
import java.util.concurrent.Future;

/**
 * The parallel FASTQ producer behind {@link FastqReader#stream}.
 * Pipeline mode: the calling thread reads or inflates bytes and slices
 * whole records by the newline scan; pool workers parse the slices;
 * the ArrayDeque of futures, submitted in order and taken from the
 * head, is the ordered assembler. The caller is submitter and
 * consumer, so submission never blocks and the window is bounded by
 * taking before submitting. The emitted record stream is identical to
 * the serial producer's.
 *
 * <p>Cross-language equivalent: ObjC {@code TTIOFastqParallelProducer}.</p>
 */
public final class FastqParallelProducer {
    private FastqParallelProducer() { }

    /** Parse a slice of whole 4-line records. {@code phred} 0 detects
     *  from this slice (first slice only). */
    static WrittenGenomicRun parseSlice(byte[] b, int len, int phredIn, int[] detectOut,
                                        String sampleName) {
        List<String> names = new ArrayList<>();
        List<Long> offsets = new ArrayList<>();
        List<Integer> lengths = new ArrayList<>();
        java.io.ByteArrayOutputStream seqBuf = new java.io.ByteArrayOutputStream(len / 2);
        java.io.ByteArrayOutputStream qualBuf = new java.io.ByteArrayOutputStream(len / 2);
        long running = 0L;
        int i = 0;
        while (i < len) {
            if (b[i] != '@') throw new IllegalStateException("slice does not start a record");
            int hs = i + 1, he = hs;
            while (he < len && b[he] != '\n') he++;
            if (he >= len) throw new IllegalStateException("truncated header in slice");
            int ne = hs;
            while (ne < he && b[ne] != ' ' && b[ne] != '\t') ne++;
            if (ne == hs) throw new IllegalStateException("FASTQ header missing a name token");
            names.add(new String(b, hs, ne - hs, StandardCharsets.UTF_8));
            int ss = he + 1, se = ss;
            while (se < len && b[se] != '\n') se++;
            if (se >= len) throw new IllegalStateException("truncated sequence in slice");
            int ps = se + 1;
            if (ps >= len || b[ps] != '+') throw new IllegalStateException("missing + separator");
            int pe = ps;
            while (pe < len && b[pe] != '\n') pe++;
            if (pe >= len) throw new IllegalStateException("truncated separator in slice");
            int qs = pe + 1, qe = qs;
            while (qe < len && b[qe] != '\n') qe++;
            if (qe >= len) throw new IllegalStateException("truncated qualities in slice");
            if (qe - qs != se - ss) {
                throw new IllegalStateException("SEQ/QUAL length mismatch for read '"
                    + names.get(names.size() - 1) + "'");
            }
            offsets.add(running);
            lengths.add(se - ss);
            seqBuf.write(b, ss, se - ss);
            qualBuf.write(b, qs, qe - qs);
            running += se - ss;
            i = qe + 1;
        }
        int phred = phredIn;
        byte[] quals = qualBuf.toByteArray();
        if (phred == 0) {
            phred = FastqReader.detectPhredOffset(quals);
            if (detectOut != null) detectOut[0] = phred;
        }
        if (phred == 64) {
            for (int j = 0; j < quals.length; j++) quals[j] = (byte) ((quals[j] & 0xFF) - 31);
        }
        return FastaReader.buildUnalignedRun(names, seqBuf.toByteArray(), quals,
            offsets, lengths, sampleName, "", "", AcquisitionMode.GENOMIC_WGS);
    }

    /** The pipeline iterator over {@code path} (plain or gzip FASTQ). */
    public static Iterator<WrittenGenomicRun> pipeline(Path path, String sampleName,
                                                       int batchReadsIn, long batchBytesIn,
                                                       int threads, ProgressSink progressIn) {
        final int batchReads = batchReadsIn > 0 ? batchReadsIn : FastqReader.DEFAULT_BATCH_READS;
        final long batchBytes = batchBytesIn > 0 ? batchBytesIn : FastqReader.DEFAULT_BATCH_BYTES;
        final String sample = sampleName == null ? "" : sampleName;
        final ProgressSink progress = progressIn == null ? ProgressSink.discard() : progressIn;
        return new Iterator<>() {
            final Threads.PoolScope scope = Threads.pool(threads);
            final ArrayDeque<Future<WrittenGenomicRun>> futures = new ArrayDeque<>();
            final int window = threads + 2;
            InputStream in;
            byte[] carry = new byte[2 << 20];
            int carryLen = 0, scanPos = 0, newlines = 0, lastRecordEnd = 0, recordsInCarry = 0;
            long totalRecords = 0;
            int phred = 0;
            boolean eof = false, closed = false;
            WrittenGenomicRun next;
            WrittenGenomicRun firstParsed;

            private void closeAll() {
                if (closed) return;
                closed = true;
                try { if (in != null) in.close(); } catch (IOException ignored) { }
                scope.close();
            }

            private void ensureOpen() {
                if (in != null || eof) return;
                try {
                    in = FastaReader.openMaybeGzip(path);
                } catch (IOException e) {
                    closeAll();
                    throw new java.io.UncheckedIOException(e);
                }
            }

            /** Read chunks and cut at most one slice; returns it raw or
             *  null at input end. */
            private byte[] nextSlice() {
                try {
                    while (true) {
                        if (recordsInCarry > 0
                            && (recordsInCarry >= batchReads
                                || (long) lastRecordEnd >= batchBytes
                                || eof)) {
                            byte[] slice = java.util.Arrays.copyOfRange(carry, 0, lastRecordEnd);
                            System.arraycopy(carry, lastRecordEnd, carry, 0, carryLen - lastRecordEnd);
                            carryLen -= lastRecordEnd;
                            scanPos -= lastRecordEnd;
                            lastRecordEnd = 0;
                            recordsInCarry = 0;
                            return slice;
                        }
                        if (eof) {
                            if (carryLen > 0) {
                                throw new IllegalStateException("truncated record at end of file");
                            }
                            return null;
                        }
                        if (carryLen == carry.length) {
                            carry = java.util.Arrays.copyOf(carry, carry.length * 2);
                        }
                        int got = in.read(carry, carryLen, carry.length - carryLen);
                        if (got < 0) { eof = true; continue; }
                        carryLen += got;
                        for (int i = scanPos; i < carryLen; i++) {
                            if (carry[i] != '\n') continue;
                            newlines++;
                            if ((newlines & 3) == 0) {
                                lastRecordEnd = i + 1;
                                recordsInCarry++;
                                totalRecords++;
                            }
                        }
                        scanPos = carryLen;
                    }
                } catch (IOException e) {
                    closeAll();
                    throw new java.io.UncheckedIOException(e);
                }
            }

            private void pump() {
                ensureOpen();
                while (!closed && futures.size() < window) {
                    byte[] slice = nextSlice();
                    if (slice == null) break;
                    if (phred == 0) {
                        // First slice on the caller: it detects the
                        // Phred offset every later slice applies.
                        int[] det = new int[1];
                        firstParsed = parseSlice(slice, slice.length, 0, det, sample);
                        phred = det[0];
                        progress.onProgress(totalRecords, -1);
                        return;
                    }
                    final byte[] cap = slice;
                    final int ph = phred;
                    futures.add(scope.executor().submit(() -> parseSlice(cap, cap.length, ph, null, sample)));
                    progress.onProgress(totalRecords, -1);
                }
            }

            @Override public boolean hasNext() {
                if (next != null) return true;
                if (closed) return false;
                try {
                    if (firstParsed != null) {
                        next = firstParsed;
                        firstParsed = null;
                        return true;
                    }
                    pump();
                    if (firstParsed != null) {
                        next = firstParsed;
                        firstParsed = null;
                        return true;
                    }
                    Future<WrittenGenomicRun> f = futures.pollFirst();
                    if (f == null) {
                        progress.onProgress(totalRecords, totalRecords);
                        closeAll();
                        return false;
                    }
                    next = f.get();
                    return true;
                } catch (InterruptedException e) {
                    Thread.currentThread().interrupt();
                    closeAll();
                    throw new IllegalStateException(e);
                } catch (java.util.concurrent.ExecutionException e) {
                    closeAll();
                    Throwable c = e.getCause();
                    throw c instanceof RuntimeException r ? r : new IllegalStateException(c);
                } catch (RuntimeException e) {
                    closeAll();
                    throw e;
                }
            }

            @Override public WrittenGenomicRun next() {
                if (!hasNext()) throw new NoSuchElementException();
                WrittenGenomicRun r = next;
                next = null;
                return r;
            }
        };
    }
}
