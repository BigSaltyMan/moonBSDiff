// MoonBSDiff bounded pull decoder. Reuses the pinned decoder's block transform.

///|
pub struct StreamReader {
  priv bits : Bits
  priv meter : Meter
  priv level : Int32
  priv total : Int32
  priv mut plain : Bytes
  priv mut at : Int32
  priv mut pending : Int32
  priv mut value : Byte
  priv mut crc : BlockCrc
  priv mut want : UInt32
  priv mut combined : UInt32
  priv mut in_block : Bool
  priv mut ended : Bool
}

///|
/// Source returns at most 4096 bytes within this interval. An empty source is EOF.
/// The shared budget reserves each final RLE run before any bytes are emitted.
pub fn StreamReader::new(
  total : Int32,
  source : () -> Bytes,
  cap : Int32,
  budget : Budget,
) -> StreamReader raise Fault {
  if total < 0 ||
    cap < 0 ||
    budget.remaining < 0L ||
    budget.emitted < 0L ||
    budget.emitted > 9223372036854775807L - budget.remaining {
    raise Parameter
  }
  let bits = Bits::source(total, source)
  for i in 0..<3 {
    if need(bits, 8) != [0x42, 0x5A, 0x68][i] {
      raise Header(at=i, what="invalid bzip2 header")
    }
  }
  let level = need(bits, 8) - 0x30
  if level < 1 || level > 9 {
    raise Header(at=3, what="invalid bzip2 level")
  }
  {
    bits,
    meter: Meter::{ budget, cap, produced: 0, },
    level,
    total,
    plain: b"",
    at: 0,
    pending: 0,
    value: 0,
    crc: BlockCrc::new(),
    want: 0U,
    combined: 0U,
    in_block: false,
    ended: false,
  }
}

///|
/// Output is bounded even when a run straddles calls. Empty means verified EOF.
/// After a Fault the reader must be discarded; no input prefix is replayed.
pub fn StreamReader::read(
  self : StreamReader,
  max : Int32,
) -> Bytes raise Fault {
  if max < 1 || max > 4096 {
    raise Parameter
  }
  let out : Array[Byte] = []
  while out.length() < max && !self.ended {
    if self.pending > 0 {
      let count = Int32::min(self.pending, max - out.length())
      for _ in 0..<count {
        self.crc.push_byte(self.value.to_int())
        out.push(self.value)
      }
      self.pending -= count
      continue
    }
    if self.at < self.plain.length() {
      self.value = self.plain[self.at]
      self.at += 1
      let mut run = 1
      while run < 4 &&
            self.at < self.plain.length() &&
            self.plain[self.at] == self.value {
        run += 1
        self.at += 1
      }
      if run == 4 {
        if self.at == self.plain.length() {
          raise Code(at=self.bits.used())
        }
        run += self.plain[self.at].to_int()
        self.at += 1
      }
      self.meter.reserve(run)
      self.pending = run
      continue
    }
    if self.in_block {
      let got = self.crc.finish()
      if got != self.want {
        raise Checksum(want=self.want, got~)
      }
      self.combined = ((self.combined << 1) | (self.combined >> 31)) ^ got
      self.in_block = false
      self.plain = b""
    }
    match marker(self.bits) {
      Some(0) => {
        let (plain, want) = read_rle_block(self.bits, self.level)
        self.plain = plain
        self.at = 0
        self.want = want
        self.crc = BlockCrc::new()
        self.in_block = true
      }
      Some(1) => {
        let want = match self.bits.take_word() {
          Some(v) => v
          None => raise Truncated(at=self.bits.used())
        }
        if want != self.combined {
          raise Checksum(want~, got=self.combined)
        }
        let used = (
            self.bits.used().to_int64() * 8L - self.bits.held.to_int64() + 7L
          ) /
          8L
        if used != self.total.to_int64() {
          raise Header(
            at=used.to_int(),
            what="trailing data after single bzip2 stream",
          )
        }
        self.ended = true
      }
      _ => raise Header(at=self.bits.used(), what="invalid bzip2 marker")
    }
  }
  Bytes::from_array(out)
}
