// MoonBSDiff adaptations; the copied decoder files retain their Apache-2.0 notices.

///|
#derive(Debug)
pub(all) suberror Fault {
  Truncated(at~ : Int32)
  Header(at~ : Int32, what~ : String)
  Code(at~ : Int32)
  Checksum(want~ : UInt32, got~ : UInt32)
  Limit(field~ : String, value~ : Int64, limit~ : Int64)
  Parameter
}

///|
pub extend Fault with @debug.Debug::{to_repr}

///|
// Internal package state shared by Control, Diff and Extra; failures do not refund work.
pub(all) struct Budget {
  mut remaining : Int64
  mut emitted : Int64
}

///|
priv struct Meter {
  budget : Budget
  cap : Int32
  mut produced : Int32
}

///|
fn Meter::reserve(self : Meter, count : Int32) -> Unit raise Fault {
  if count > self.cap - self.produced {
    raise Limit(
      field="block_output_bytes",
      value=self.produced.to_int64() + count.to_int64(),
      limit=self.cap.to_int64(),
    )
  }
  if count.to_int64() > self.budget.remaining {
    raise Limit(
      field="decompressed_remaining",
      value=count.to_int64(),
      limit=self.budget.remaining,
    )
  }
  // emitted <= original nonnegative Int64 budget; subtraction proves no overflow.
  self.budget.remaining -= count.to_int64()
  self.budget.emitted += count.to_int64()
  self.produced += count
}

///|
pub(all) struct Decoded {
  output : Bytes
  consumed_bits : Int64
  blocks : Int32
}

///|
pub fn decode(
  data : BytesView,
  cap : Int32,
  budget : Budget,
) -> Decoded raise Fault {
  if cap < 0 ||
    budget.remaining < 0L ||
    budget.emitted < 0L ||
    budget.emitted > 9223372036854775807L - budget.remaining {
    raise Parameter
  }
  let bits = Bits::new(data)
  for i in 0..<3 {
    if need(bits, 8) != [0x42, 0x5A, 0x68][i] {
      raise Header(at=i, what="invalid bzip2 header")
    }
  }
  let level_byte = need(bits, 8)
  if level_byte < 0x31 || level_byte > 0x39 {
    raise Header(at=3, what="invalid bzip2 level")
  }
  let meter = Meter::{ budget, cap, produced: 0, }
  let out : Array[Byte] = []
  let mut combined = 0U
  let mut blocks = 0
  while true {
    let kind = match marker(bits) {
      Some(k) => k
      None =>
        raise Header(
          at=((bits.at.to_int64() * 8L - bits.held.to_int64()) / 8L - 6L).to_int(),
          what="invalid bzip2 marker",
        )
    }
    if kind == 1 {
      let want = match bits.take_word() {
        Some(v) => v
        None => raise Truncated(at=bits.used())
      }
      if want != combined {
        raise Checksum(want~, got=combined)
      }
      let consumed_bits = bits.at.to_int64() * 8L - bits.held.to_int64()
      let consumed_bytes = (consumed_bits + 7L) / 8L
      // Ignore only the final byte's padding bits; do not accept another full byte.
      if consumed_bytes != data.length().to_int64() {
        raise Header(
          at=consumed_bytes.to_int(),
          what="trailing data after single bzip2 stream",
        )
      }
      return { output: Bytes::from_array(out), consumed_bits, blocks, }
    }
    let (block, stamp) = read_block(bits, level_byte - 0x30, meter)
    if block.length() > cap - out.length() {
      raise Limit(
        field="block_output_bytes",
        value=out.length().to_int64() + block.length().to_int64(),
        limit=cap.to_int64(),
      )
    }
    combined = ((combined << 1) | (combined >> 31)) ^ stamp
    for b in block {
      out.push(b)
    }
    blocks += 1
  } nobreak {
    abort("unreachable decoder state")
  }
}
