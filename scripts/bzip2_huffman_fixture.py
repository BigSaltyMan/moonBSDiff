"""Deterministic fixture and independent bzip2 Huffman table audit."""

def make_payload():
    B = 21
    # Spread skewed MTF frequencies among 50-symbol coding groups.
    w = [1, 1]
    for i in range(2, 24):
        val = sum(w[:-1]) + (500 if i >= 20 else 1)
        if i == 23:
            val += 20000
        w.append(val)
    counts = w[2:]
    num_groups = (sum(counts[2:]) + 49) // 50
    buckets = [[] for _ in range(num_groups)]
    for s in range(B, 1, -1):
        c = counts[s]
        if c < 10000:
            lo, span = 150, num_groups - 300
            off = (s * 113) % span
            for j in range(c):
                buckets[lo + ((j * span) // c + off) % span].append(s)
        else:
            for j in range(c):
                buckets[(j * num_groups) // c].append(s)
    zeros = [0] * counts[0] + [1] * counts[1]
    stream, zi, mid = [], 0, num_groups // 2
    for bi, b in enumerate(buckets):
        stream.extend(b)
        if zi < len(zeros) and bi >= mid and bi % 23 == 0:
            stream.append(zeros[zi]); zi += 1
    stream.extend(zeros[zi:])
    mtf, L = list(range(B)) + [B], []
    for b in range(B):
        mtf.pop(mtf.index(b)); mtf.insert(0, b); L.append(b)
    for s in stream:
        if s == 0: L.append(mtf[0])
        elif s == 1: L.extend([mtf[0], mtf[0]])
        else:
            v = mtf.pop(s - 1); mtf.insert(0, v); L.append(v)
    # Short unique keys preserve BWT ordering without long RLE runs.
    out, key = bytearray(), 0
    for bv in L:
        while True:
            t = key
            d3 = t % B; t //= B; d2 = t % B; t //= B
            d1 = t % B; t //= B; d0 = t % B; key += 1
            if not (d0 == d1 == d2 or d1 == d2 == d3):
                break
        out.extend((bv, B, d0, d1, d2, d3))
    return bytes(out)



def check_huffman_tables(stream):
    """Read every block, audit Kraft completeness, and return per-table max lengths."""
    assert len(stream) >= 4 and stream[:3] == b"BZh" and 0x31 <= stream[3] <= 0x39
    byte_pos = 4
    total_bytes = len(stream)
    bit_buf = 0
    bit_count = 0

    def read(length):
        nonlocal byte_pos, bit_buf, bit_count
        while bit_count < length:
            assert byte_pos < total_bytes, "truncated bzip2 stream"
            bit_buf = (bit_buf << 8) | stream[byte_pos]
            byte_pos += 1
            bit_count += 8
        bit_count -= length
        value = (bit_buf >> bit_count) & ((1 << length) - 1)
        bit_buf &= (1 << bit_count) - 1
        return value

    def read_symbol(codes):
        code = 0
        for length in range(1, 21):
            code = (code << 1) | read(1)
            if (length, code) in codes:
                return codes[length, code]
        raise AssertionError("invalid canonical Huffman symbol")

    block_table_max_lengths = []
    while (marker := read(48)) == 0x314159265359:
        read(32)  # block CRC, independently checked by bz2
        read(25)  # randomization flag and BWT origin
        groups_used = read(16).bit_count()
        alphabet = 2 + sum(read(16).bit_count() for _ in range(groups_used))
        table_count = read(3)
        assert 2 <= table_count <= 6
        table_order = list(range(table_count))
        selectors = []
        for _ in range(read(15)):
            index = 0
            while read(1):
                index += 1
                assert index < table_count
            selected = table_order.pop(index)
            selectors.append(selected)
            table_order.insert(0, selected)

        tables = []
        max_lengths = []
        for table in range(table_count):
            length = read(5)
            lengths = []
            for _ in range(alphabet):
                while read(1):
                    length += 1 if read(1) == 0 else -1
                assert 1 <= length <= 20
                lengths.append(length)
            kraft = sum(1 << (20 - length) for length in lengths)
            assert kraft == 1 << 20, (
                f"block {len(block_table_max_lengths)}, table {table}: Kraft {kraft}/{1 << 20}"
            )
            max_lengths.append(max(lengths))

            codes = {}
            code = previous_length = 0
            for symbol in sorted(range(alphabet), key=lengths.__getitem__):
                length = lengths[symbol]
                code <<= length - previous_length
                codes[length, code] = symbol
                previous_length = length
                code += 1
            tables.append(codes)

        # Follow the selectors to EOB so the next marker is read at its exact
        # position, even when marker-like bits occur inside the payload.
        at_end = False
        for selector in selectors:
            for _ in range(50):
                if read_symbol(tables[selector]) == alphabet - 1:
                    at_end = True
                    break
            if at_end:
                break
        assert at_end, "block did not reach EOB"
        block_table_max_lengths.append(max_lengths)
    assert marker == 0x177245385090, "missing bzip2 stream end"
    read(32)  # stream CRC, independently checked by bz2
    assert byte_pos == total_bytes and bit_count < 8 and bit_buf == 0
    return block_table_max_lengths
