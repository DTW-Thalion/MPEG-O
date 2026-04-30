"""Generate canonical DELTA_RANS_ORDER0 fixtures for cross-language parity."""
import struct
import os

from ttio.codecs.delta_rans import encode

here = os.path.dirname(os.path.abspath(__file__))

# Fixture A: 1000 sorted ascending int64 positions, deltas 100-500.
# Deterministic LCG matching the M94.Z perf test pattern.
s = 0xBEEF
mask64 = (1 << 64) - 1
positions = []
pos = 10000
for i in range(1000):
    s = (s * 6364136223846793005 + 1442695040888963407) & mask64
    delta = 100 + ((s >> 32) % 401)  # 100..500
    pos += delta
    positions.append(pos)
raw_a = struct.pack("<1000q", *positions)
with open(os.path.join(here, "delta_rans_a.bin"), "wb") as f:
    f.write(encode(raw_a, element_size=8))

# Fixture B: 100 uint32 flags (5 dominant values: 0, 16, 83, 99, 163).
s = 0xBEEF
flags_vals = [0, 16, 83, 99, 163]
flags = []
for i in range(100):
    s = (s * 6364136223846793005 + 1442695040888963407) & mask64
    flags.append(flags_vals[(s >> 32) % 5])
raw_b = struct.pack("<100I", *flags)
with open(os.path.join(here, "delta_rans_b.bin"), "wb") as f:
    f.write(encode(raw_b, element_size=4))

# Fixture C: empty input (0 elements).
with open(os.path.join(here, "delta_rans_c.bin"), "wb") as f:
    f.write(encode(b"", element_size=8))

# Fixture D: single int64 element.
raw_d = struct.pack("<q", 1234567890)
with open(os.path.join(here, "delta_rans_d.bin"), "wb") as f:
    f.write(encode(raw_d, element_size=8))

print("Generated delta_rans_{a,b,c,d}.bin")
