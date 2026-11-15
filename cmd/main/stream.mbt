///|
#borrow(old, patch)
extern "C" fn stream_open(
  old : Bytes,
  patch : Bytes,
  oldcap : Int64,
  patchcap : Int64,
) -> Int32 = "mbsd_stream_open"

///|
extern "C" fn stream_size(which : Int32) -> Int64 = "mbsd_stream_size"

///|
extern "C" fn stream_read(
  which : Int32,
  offset : Int64,
  count : Int32,
) -> Bytes = "mbsd_stream_read"

///|
#borrow(data)
extern "C" fn stream_write(data : Bytes) -> Int32 = "mbsd_stream_write"

///|
#borrow(path, body)
extern "C" fn stream_deliver(
  path : Bytes,
  call : FuncRef[(() -> Int32) -> Int32],
  body : () -> Int32,
) -> Int32 = "mbsd_stream_deliver"

///|
extern "C" fn stream_abort() -> Unit = "mbsd_stream_abort"

///|
suberror StreamError {
  StreamError(String)
}

///|
fn stream_require(ok : Bool, message : String) -> Unit raise StreamError {
  if !ok {
    raise StreamError(message)
  }
}

///|
fn stream_add(a : Int64, b : Int64) -> Int64 raise StreamError {
  stream_require(
    !(b > 0L && a > 9223372036854775807L - b) &&
    !(b < 0L && a < -9223372036854775808L - b),
    "Applying IntegerOverflow: old cursor",
  )
  a + b
}

///|
// The control codec is the format's eight-byte sign-magnitude integer, not
// a native-endian/complement load. Magnitude accumulation never exceeds Int64.max.
fn stream_integer(data : Bytes, at : Int32) -> Int64 {
  let mut value = (data[at + 7].to_int() & 127).to_int64()
  for j = 6; j >= 0; j = j - 1 {
    value = value * 256L + data[at + j].to_int().to_int64()
  }
  if (data[at + 7].to_int() & 128) == 0 {
    value
  } else {
    -value
  }
}

///|
fn stream_source(start : Int64, length : Int64) -> () -> Bytes {
  let mut at = 0L
  fn() {
    let n = Int64::min(4096L, length - at).to_int()
    let data = stream_read(1, start + at, n)
    at += data.length().to_int64()
    data
  }
}

///|
fn stream_exact(
  reader : @bzip2.StreamReader,
  count : Int32,
  block : String,
) -> Bytes raise {
  let out : Array[Byte] = []
  while out.length() < count {
    let data = reader.read(count - out.length())
    stream_require(data.length() != 0, "Applying TruncatedData: " + block)
    for b in data {
      out.push(b)
    }
  }
  Bytes::from_array(out)
}

///|
fn stream_execute(
  info : @moonbsdiff.PatchInfo,
  limits : @moonbsdiff.Limits,
) -> Unit raise {
  let budget = @bzip2.Budget::{
    remaining: limits.max_decompressed_bytes,
    emitted: 0L,
  }
  // Control byte cap saturates at Int.max without multiplying a large count.
  let control_cap = if limits.max_control_instructions > 2147483647L / 24L {
    2147483647
  } else {
    (limits.max_control_instructions * 24L).to_int()
  }
  let control = @bzip2.StreamReader::new(
    info.control_length.to_int(),
    stream_source(info.control_start, info.control_length),
    control_cap,
    budget,
  )
  let delta = @bzip2.StreamReader::new(
    info.diff_length.to_int(),
    stream_source(info.diff_start, info.diff_length),
    info.new_bytes.to_int(),
    budget,
  )
  let extra = @bzip2.StreamReader::new(
    info.extra_length.to_int(),
    stream_source(info.extra_start, info.extra_length),
    info.new_bytes.to_int(),
    budget,
  )
  let mut newpos = 0L
  let mut oldpos = 0L
  let mut instructions = 0L
  let oldsize = stream_size(0)
  while newpos < info.new_bytes {
    stream_require(
      instructions < limits.max_control_instructions,
      "Applying ResourceLimitExceeded: max_control_instructions",
    )
    let triple = stream_exact(control, 24, "control triple")
    instructions += 1L
    let x = stream_integer(triple, 0)
    let y = stream_integer(triple, 8)
    let z = stream_integer(triple, 16)
    stream_require(
      x >= 0L && y >= 0L,
      "Applying InvalidField: negative control x/y",
    )
    stream_require(
      x <= info.new_bytes - newpos,
      "Applying OutputOutOfBounds: diff length",
    )
    let oldend = stream_add(oldpos, x)
    let mut done = 0L
    while done < x {
      let count = Int64::min(4096L, x - done).to_int()
      let data = stream_exact(delta, count, "diff")
      let pos = stream_add(oldpos, done)
      // Never negate Int64.min. Only a negative position within this chunk can
      // overlap zero; it is then proven to fit an Int before negating.
      let prefix = if pos >= 0L {
        0
      } else if pos < -count.to_int64() {
        count
      } else {
        (-pos).to_int()
      }
      let oldat = if pos < 0L { 0L } else { pos }
      let available = if oldat >= oldsize {
        0
      } else {
        Int64::min((count - prefix).to_int64(), oldsize - oldat).to_int()
      }
      let old = stream_read(0, Int64::min(oldat, oldsize), available)
      stream_require(io_failed() == 0, "Applying: old file read")
      let out = Array::makei(count, i => {
        if i >= prefix && i - prefix < available {
          ((data[i].to_int() + old[i - prefix].to_int()) % 256).to_byte()
        } else {
          data[i]
        }
      })
      stream_require(
        stream_write(Bytes::from_array(out)) != 0,
        "Applying: write temporary",
      )
      done += count.to_int64()
    }
    newpos += x
    oldpos = oldend
    stream_require(
      y <= info.new_bytes - newpos,
      "Applying OutputOutOfBounds: extra length",
    )
    done = 0L
    while done < y {
      let count = Int64::min(4096L, y - done).to_int()
      let data = stream_exact(extra, count, "extra")
      stream_require(stream_write(data) != 0, "Applying: write temporary")
      done += count.to_int64()
    }
    newpos += y
    oldpos = stream_add(oldpos, z)
  }
  // EOF is not assumed at the declared output length: read once more to force
  // the final run/block CRC, real end marker, combined CRC and interval boundary.
  for
    (name, reader) in [("control", control), ("diff", delta), ("extra", extra)] {
    stream_require(
      reader.read(1).length() == 0,
      "Applying InvalidField: unconsumed " + name,
    )
  }
}

///|
fn stream_command(config : CliConfig) -> Unit {
  let limits = config.limits
  if stream_open(
      path_bytes(config.files[0]),
      path_bytes(config.files[1]),
      limits.max_old_bytes,
      limits.max_patch_bytes,
    ) ==
    0 {
    failure("stream open: " + @utf8.decode_lossy(io_error()[:]))
  }
  let header = stream_read(1, 0L, Int64::min(32L, stream_size(1)).to_int())
  if io_failed() != 0 {
    stream_abort()
    failure("stream read header: " + @utf8.decode_lossy(io_error()[:]))
    return
  }
  let info = match
    @moonbsdiff.inspect_header_prefix(
      header,
      stream_size(1),
      limits.max_patch_bytes,
    ) {
    Ok(v) => v
    Err(e) => {
      stream_abort()
      failure(@debug.to_string(e))
      return
    }
  }
  for
    (field, cap) in [
      ("max_new_bytes", limits.max_new_bytes),
      ("max_output_bytes", limits.max_output_bytes),
    ] {
    if info.new_bytes > cap {
      stream_abort()
      failure(
        "Header ResourceLimitExceeded: \{field} value=\{info.new_bytes} limit=\{cap}",
      )
      return
    }
  }
  let mut detail = ""
  let ok = stream_deliver(path_bytes(config.files[2]), fn(f) { f() }, fn() {
    try {
      stream_execute(info, limits)
      1
    } catch {
      StreamError(message) => {
        detail = message
        0
      }
      e => {
        detail = "Decompression: " + @debug.to_string(e)
        0
      }
    }
  })
  if ok == 0 {
    failure(
      "stream apply: " + detail + "; " + @utf8.decode_lossy(io_error()[:]),
    )
  }
}
