# Recovery & Resilience

What guarantees does TTI-O make when a `.tio` file is partially
written, truncated, or corrupted? This doc captures the current
behaviour, observed across the three reference implementations, so
operators can plan around it.

V8 of the verification workplan added test coverage that locks in
each behaviour — see `python/tests/test_v8_hdf5_corruption.py`,
`java/src/test/java/global/thalion/ttio/V8Hdf5CorruptionTest.java`,
and `objc/Tests/TestV8Hdf5Corruption.m` for the executable
specification.

## Summary

| Failure mode | Behaviour | Catchable? | Notes |
|---|---|---|---|
| Zero-byte file | Open raises | Yes | Python: `OSError`; Java: `HDF5LibraryException`; ObjC: `NSError`. |
| 1-byte file | Open raises | Yes | Same as zero-byte. |
| Truncated at superblock (first 4 KB) | Open raises | Yes | All three languages raise; no segfault. |
| Truncated mid-file (last quarter chopped) | Open succeeds, dataset read raises | Yes | h5py defers chunk loading; the failure surfaces on the first `ds[...]` access. |
| Truncated tail (last 1 KB chopped) | Either raises on read OR returns truncated array | Yes | Behaviour depends on whether the missing bytes contain the chunk index. **If h5py returns data, the array is always the declared length** — no silently-short arrays. |
| Corrupted superblock magic (first 8 bytes zeroed) | Open raises | Yes | All three languages catch this cleanly. |
| Random 16 KB of garbage | Open raises | Yes | No format auto-detection past the superblock. |
| Trailing junk past declared EOF | Tolerated | n/a | h5py reads up to the declared file extent and ignores trailing bytes. **If you need tamper-detection on appended bytes, sign the file via TTI-O M54 signatures (HMAC-SHA256 / ML-DSA-87) — HDF5 itself can't tell.** |

## What we DO NOT guarantee (today)

* **Specific exception type** — Python today raises bare `OSError`
  (or sometimes `ValueError` from h5py's deferred wrappers). We have
  not introduced a `TTIOHdf5ParseError` shim. V8 tests assert
  catchability against `(OSError, ValueError)` rather than a single
  type.
* **File-offset info in error messages** — h5py's messages cite the
  file path but rarely an offset. Future work could wrap h5py
  errors to include offset hints.
* **Partial-write recovery** — If a writer process crashes
  mid-flush, the partial file may be unreadable. TTI-O does not
  emit a journal or use atomic-rename. Operators should write to a
  scratch path and `os.replace()` on success.
* **Concurrent-writer protection** — HDF5 is not safe for
  concurrent writers without external locking. TTI-O does not add
  cross-process locks.
* **Network-mount safety** — `.tio` files on NFS / SMB / S3-fuse
  inherit the underlying filesystem's consistency guarantees.
  TTI-O does not paper over flaky mounts.

## Recommended operator practice

1. **Write to scratch + atomic rename** for any production write
   that must survive a crash:

   ```python
   tmp = path.with_suffix(".tio.tmp")
   dataset.write(tmp)
   os.replace(tmp, path)  # POSIX-atomic on the same filesystem
   ```

2. **Sign any file you'll later read back** if tamper-detection is
   important. M54 HMAC-SHA256 covers byte-level integrity; M49
   ML-DSA-87 covers post-quantum identity.

3. **Verify on first read** in long-lived pipelines:

   ```python
   if dataset.verify_signature() != "OK":
       raise IntegrityError(...)
   ```

4. **Don't trust trailing-junk-tolerance.** A `.tio` file's logical
   end is its declared HDF5 file extent, not its on-disk byte
   length. Use signatures if you need to know nobody appended
   to the file post-write.

## Future work

* `TTIOHdf5ParseError` wrapper (would let users catch one type
  rather than `(OSError, ValueError)`).
* File-offset hints in error messages (requires patching h5py
  upstream or wrapping the C API directly).
* Optional journal mode for crash recovery (significant
  complexity; not on the roadmap as of 2026-04-27).
