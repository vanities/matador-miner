#!/usr/bin/env python3
# Ground truth for FromSeed/from_oracle, EXACTLY per src/matmul/field.cpp:140 and
# matrix.cpp:491 (FromSeed: out[r*n+c] = from_oracle(seed, r*n+c), row-major).
# hashlib = trusted SHA-256; we only have to match the exact input byte layout.
import hashlib, struct

MODULUS = 0x7FFFFFFF
N = 512

def from_oracle(seed_raw: bytes, index: int) -> int:
    # field.cpp: seed_bytes[i] = seed.data()[31 - i]  -> reverse the 32 raw seed bytes
    seed_bytes = seed_raw[::-1]
    for retry in range(256):
        h = hashlib.sha256()
        h.update(seed_bytes)                    # 32 bytes
        h.update(struct.pack('<I', index))      # WriteLE32(index)
        if retry > 0:
            h.update(struct.pack('<I', retry))  # WriteLE32(retry)
        d = h.digest()
        cand = struct.unpack('<I', d[:4])[0] & MODULUS   # ReadLE32(hash) & MODULUS
        if cand < MODULUS:
            return cand
    # deterministic fallback (field.cpp:173); astronomically rare, kept exact
    h = hashlib.sha256()
    h.update(seed_bytes)
    h.update(struct.pack('<I', index))
    h.update(b'oracle-fallback')                # 15 bytes (sizeof-1, no NUL)
    return struct.unpack('<I', h.digest()[:4])[0] % MODULUS

def main():
    total = N * N
    seed_raw = bytes(range(32))                 # bytes 0..31, identical to the CUDA side
    buf = bytearray(total * 4)
    for idx in range(total):
        struct.pack_into('<I', buf, idx * 4, from_oracle(seed_raw, idx))
    with open('truth.bin', 'wb') as f:
        f.write(buf)
    for idx in (0, 1, 2, 100, total - 1):
        print(f"truth from_oracle(seed=0..31, {idx}) = {from_oracle(seed_raw, idx)}")
    print(f"wrote truth.bin ({total} uint32, {total*4} bytes)")

if __name__ == '__main__':
    main()
