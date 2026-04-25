# Encryption API bugs surfaced by TTI-O-MCP-Server M5 work

## Context

The downstream **TTI-O-MCP-Server** (github.com/DTW-Thalion/TTI-O-MCP-Server, currently at `v0.4.0.dev0`) is about to add keyring-backed encryption support in its M5 milestone. It pins `mpeg-o @ git+https://github.com/DTW-Thalion/TTI-O.git@v1.0.0#subdirectory=python`. A smoke test against the public `SpectralDataset.encrypt_with_key` / `decrypt_with_key` API on **v1.0.0** surfaced two blocking issues that need to be fixed in the TTI-O reference implementation (ObjC canonical) and mirrored in Java + Python per the project's 3-language parity rule.

The MCP server does not need new features — it needs the existing published surface to behave correctly and ergonomically across close/reopen.

## Issue A — `is_encrypted` / `encrypted_algorithm` lose state across reopen

After encrypting a file via a `writable=True` open, closing it, and reopening it read-only, `SpectralDataset.is_encrypted` reports `False` and `encrypted_algorithm` is the empty string. The underlying encryption clearly did persist (see Issue B — the `intensity` signal array is gone from the reopened file), but the metadata that would let a downstream catalog mark `encrypted=true` is missing.

### Reproducer (Python, against current v1.0.0)

```python
import os, tempfile, numpy as np
from ttio import SpectralDataset, AcquisitionMode, WrittenRun
from ttio.enums import EncryptionLevel

with tempfile.TemporaryDirectory() as td:
    p = os.path.join(td, 'enc.tio')
    n, m = 5, 4
    rng = np.random.default_rng(1)
    run = WrittenRun(
        spectrum_class='TTIOMassSpectrum',
        acquisition_mode=int(AcquisitionMode.MS1_DDA),
        channel_data={
            'mz': np.tile(np.linspace(100, 200, m), n).astype(np.float64),
            'intensity': rng.uniform(0, 1e6, n*m).astype(np.float64),
        },
        offsets=(np.arange(n, dtype=np.uint64) * m),
        lengths=np.full(n, m, dtype=np.uint32),
        retention_times=np.linspace(0, 1, n),
        ms_levels=np.ones(n, dtype=np.int32),
        polarities=np.ones(n, dtype=np.int32),
        precursor_mzs=np.zeros(n),
        precursor_charges=np.zeros(n, dtype=np.int32),
        base_peak_intensities=np.zeros(n),
    )
    SpectralDataset.write_minimal(p, title='t', isa_investigation_id='I', runs={'r1': run})

    ds = SpectralDataset.open(p, writable=True)
    ds.encrypt_with_key(b'0'*32, level=EncryptionLevel.DATASET_GROUP)
    assert ds.is_encrypted  # EXPECTED: True. ACTUAL: False.
    ds.close()

    ds2 = SpectralDataset.open(p)
    assert ds2.is_encrypted             # EXPECTED: True. ACTUAL: False.
    assert ds2.encrypted_algorithm       # EXPECTED: non-empty. ACTUAL: "".
```

### Expected behaviour
- `is_encrypted` must reflect the persisted encryption state on reopen.
- `encrypted_algorithm` must return a stable identifier (e.g. `"AES-256-GCM"` — whatever the impl uses) after reopen of an encrypted file.
- Writing the encryption metadata to the file must happen inside `encrypt_with_key` (or on `close` of a writable-encrypted dataset), not be forgotten.

## Issue B — `decrypt_with_key` return shape is unusable without private internals

```python
>>> decrypted = ds2.decrypt_with_key(b'0'*32)
>>> type(decrypted), list(decrypted.keys())
(<class 'dict'>, ['r1'])
>>> type(decrypted['r1'])
<class 'bytes'>
```

The API returns `dict[str, bytes]` — a flat byte buffer of the concatenated run-level intensity channel. To actually *read a decrypted spectrum*, a downstream caller has to:

1. Know the intensity channel's dtype (not returned).
2. Know each spectrum's offset and length inside the buffer (only available on the pre-write `WrittenRun`, not reliably reachable from a reopened read-only `SpectralDataset`).
3. Reshape the bytes back into a numpy array themselves.

That's effectively forcing downstream callers to re-implement TTI-O's own HDF5 layout knowledge. After encryption the dataset also *loses* the `intensity` signal array — `spec.intensity_array` raises `KeyError: "no such signal array 'intensity'; have ['mz']"` — so there's no fallback path through the normal spectrum read API.

### What downstream needs

Pick one of the following (in decreasing order of preference for MCP-Server):

1. **Preferred — rehydrate in-memory.** `decrypt_with_key(key)` should repopulate the in-memory `SpectralDataset` so subsequent `run.object_at_index(i).intensity_array` returns the decrypted values. The on-disk file stays encrypted; only the open handle sees plaintext.
2. **Acceptable — dedicated accessor.** Add `SpectralDataset.decrypted_signal_array(run_name: str, channel: str, key: bytes) -> SignalArray` that does the reshape internally, so callers never touch raw bytes or offsets.
3. **Minimum viable — publish the shape.** Keep the current `dict[str, bytes]` return but also expose `run.encrypted_channel_layout(channel) -> (dtype, offsets, lengths)` from a read-only reopen, and document that callers must reshape.

Option 1 is the most aligned with how the rest of TTI-O is used.

## 3-language parity

Per project rule ("Python/Java/ObjC must expose the same classes AND CLI tools; each stands alone") the fix for both issues must land in all three:

- **ObjC (canonical reference impl)** — start here. `TTIOSpectralDataset -encryptWithKey:level:` and `-decryptWithKey:` are the source of truth.
- **Java** — mirror the ObjC behaviour and return shape.
- **Python** — mirror the ObjC behaviour and return shape.

CLI tools (`mpeg-o encrypt`, `mpeg-o decrypt`, etc., if they exist) must round-trip `is_encrypted` and support reading decrypted spectra through the normal read path. If any language's CLI lacks the surface, that's also in scope.

## Acceptance criteria

- [ ] Issue A reproducer above reaches the end of the script without assertion failures.
- [ ] Issue B: either `spec.intensity_array` works on a `SpectralDataset` after `decrypt_with_key(key)`, OR a documented accessor exists that returns a reassembled `SignalArray` (not raw bytes).
- [ ] Parity tests in all three languages cover: encrypt → close → reopen → `is_encrypted == True` → `encrypted_algorithm` is a known non-empty value → read a decrypted spectrum.
- [ ] Cut a new tag (e.g. `v1.0.1` or `v1.1.0` depending on whether Option 2 adds a new public method) so `mpeg-o-mcp` can pin it.
- [ ] `CHANGELOG.md` entries in each language subdirectory documenting the fix.

## Workflow notes from the downstream repo

The MCP server is built from `//wsl.localhost/Ubuntu/home/toddw/TTI-O-MCP-Server` (WSL) and pushed via Windows git (WSL HTTPS auth hangs). Once the TTI-O tag lands, the downstream pin in `pyproject.toml` gets bumped and M5 resumes with encryption in scope.

## What is **not** needed from this work

- Any change to `EncryptionLevel` semantics. The existing five levels are fine.
- New encryption algorithms.
- Key management / keyring integration — that lives in MCP-Server.
- CLI changes for anything unrelated to encryption metadata round-trip.
