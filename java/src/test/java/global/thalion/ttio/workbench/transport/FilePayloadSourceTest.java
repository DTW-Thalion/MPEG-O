/*
 * TTI-O Java Implementation
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.workbench.transport;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.io.RandomAccessFile;
import java.nio.ByteBuffer;
import java.nio.channels.FileChannel;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardOpenOption;

import static org.junit.jupiter.api.Assertions.*;

/**
 * Pin the per-call read contract of {@link FilePayloadSource}, the
 * streaming-upload payload strategy added in #130. These tests live
 * in the {@code transport} package so they can reach the package-
 * private class directly without reflection.
 *
 * <p>The streaming-upload memory contract — peak heap = O(chunkSize),
 * independent of payload size — depends on three pinned properties:
 * <ol>
 *   <li>A single {@code read} call never returns more bytes than the
 *       caller's destination buffer has room for (no slurp).</li>
 *   <li>{@code read} at {@code offset >= size} returns -1 (EOF).</li>
 *   <li>Multiple {@code read} calls at successive offsets cover the
 *       whole file with no overlap and no skipped bytes.</li>
 * </ol>
 * </p>
 */
class FilePayloadSourceTest {

    @Test
    void readReturnsAtMostBufferRemainingBytes(@TempDir Path dir) throws Exception {
        Path file = dir.resolve("payload.bin");
        byte[] expected = new byte[64 * 1024 + 7];
        for (int i = 0; i < expected.length; i++) expected[i] = (byte) (i & 0xff);
        Files.write(file, expected);

        try (FileChannel ch = FileChannel.open(file, StandardOpenOption.READ)) {
            FilePayloadSource src = new FilePayloadSource(ch, expected.length);
            assertEquals(expected.length, src.size());

            // Stitch the file back together via 4 KB reads — proves
            // the source returns at most buffer-remaining bytes per
            // call and tracks offsets correctly.
            byte[] reassembled = new byte[expected.length];
            ByteBuffer buf = ByteBuffer.allocate(4096);
            long off = 0;
            int readCount = 0;
            while (off < expected.length) {
                buf.clear();
                int n = src.read(buf, off);
                assertTrue(n > 0, "read should be positive while bytes remain");
                assertTrue(n <= 4096, "read should respect buffer-remaining cap");
                buf.flip();
                buf.get(reassembled, (int) off, n);
                off += n;
                readCount++;
            }
            assertArrayEquals(expected, reassembled,
                "successive reads should cover the file with no gaps");
            assertTrue(readCount >= expected.length / 4096,
                "should have needed at least ceil(size/4096) reads");
        }
    }

    @Test
    void readAtOrPastSizeReturnsMinusOne(@TempDir Path dir) throws Exception {
        Path file = dir.resolve("small.bin");
        Files.write(file, new byte[]{0, 1, 2, 3});
        try (FileChannel ch = FileChannel.open(file, StandardOpenOption.READ)) {
            FilePayloadSource src = new FilePayloadSource(ch, 4);
            ByteBuffer buf = ByteBuffer.allocate(8);
            assertEquals(-1, src.read(buf, 4),  "EOF at offset == size");
            assertEquals(-1, src.read(buf, 99), "EOF beyond size");
        }
    }

    @Test
    void boundedHeapStreamingReadOf100MbSparseFile(@TempDir Path dir)
            throws Exception {
        // Sparse-on-disk: 100 MB allocated as file length but unwritten.
        // OS returns zero bytes on read.
        Path file = dir.resolve("sparse-100mb.bin");
        long sparseSize = 100L * 1024 * 1024;
        try (RandomAccessFile raf = new RandomAccessFile(file.toFile(), "rw")) {
            raf.setLength(sparseSize);
        }
        assertEquals(sparseSize, Files.size(file));

        int chunkSize = 64 * 1024;
        try (FileChannel ch = FileChannel.open(file, StandardOpenOption.READ)) {
            FilePayloadSource src = new FilePayloadSource(ch, sparseSize);
            ByteBuffer scratch = ByteBuffer.allocate(chunkSize);
            long off = 0;
            long totalRead = 0;
            while (off < sparseSize) {
                scratch.clear();
                int n = src.read(scratch, off);
                if (n < 0) break;
                // Strict ceiling: every read must respect the chunk
                // boundary. If FilePayloadSource ever regressed to
                // a one-shot slurp, n would equal sparseSize on the
                // first call and this would explode.
                assertTrue(n <= chunkSize,
                    "read returned " + n + " bytes; must be <= chunkSize="
                    + chunkSize);
                totalRead += n;
                off += n;
            }
            assertEquals(sparseSize, totalRead,
                "100 MB sparse file should drain in chunk-sized reads");

            // The instrumentation counters are the load-bearing proof:
            // many small reads, each <= chunkSize.
            long expectedReads = sparseSize / chunkSize;
            assertTrue(src.readCalls.get() >= expectedReads,
                "should have made >= " + expectedReads + " reads, got "
                + src.readCalls.get());
            assertTrue(src.maxReadBytes.get() <= chunkSize,
                "max bytes per read (" + src.maxReadBytes.get()
                + ") should be <= chunkSize (" + chunkSize + ")");
        }
    }

    @Test
    void closeReleasesChannelAndIsIdempotent(@TempDir Path dir) throws Exception {
        Path file = dir.resolve("close.bin");
        Files.write(file, new byte[]{0});
        FileChannel ch = FileChannel.open(file, StandardOpenOption.READ);
        FilePayloadSource src = new FilePayloadSource(ch, 1);
        src.close();
        assertFalse(ch.isOpen(), "channel should be closed after PayloadSource.close()");
        // Second close: no-op.
        src.close();
    }
}
