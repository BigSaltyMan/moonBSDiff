///|
extern "C" fn interrupt_commit(token : Int32) -> Int32 = "mbsd_interrupt_commit"

///|
extern "C" fn interrupt_begin() -> Int32 = "mbsd_interrupt_begin"

///|
extern "C" fn interrupt_poll(token : Int32, point : Int32) -> Int32 = "mbsd_interrupt_poll"

///|
extern "C" fn interrupt_end(token : Int32) -> Int32 = "mbsd_interrupt_end"

///|
extern "C" fn stream_published() -> Int32 = "mbsd_stream_published"

///|
suberror StreamCancelled {
  StreamCancelled
}

///|
priv struct StreamProgress {
  mode : String
  mut session : Int32
  mut stage : String
  mut restored : Int64
  mut total : Int64?
  mut reported : Int64
  mut cancelled : Bool
  mut committing : Bool
  mut detail : String
}

///|
fn StreamProgress::emit(
  self : StreamProgress,
  event : String,
  message : String,
) -> Unit {
  if self.mode == "none" {
    if event == "error" || event == "cancelled" {
      stderr(@utf8.encode(("moonbsdiff: " + message + "\n")[:]))
    }
    return
  }
  let total = match self.total {
    Some(v) => @json.Json::string("\{v}")
    None => @json.Json::null()
  }
  let line = if self.mode == "json" {
    @json.Json::object({
      "schema_version": @json.Json::number(1.0),
      "event": @json.Json::string(event),
      "stage": @json.Json::string(self.stage),
      "restored_bytes": @json.Json::string("\{self.restored}"),
      "total_bytes": total,
      "output_committed": @json.Json::boolean(stream_published() != 0),
      "message": @json.Json::string(message),
    }).stringify()
  } else {
    "moonbsdiff: \{event} stage=\{self.stage} restored_bytes=\{self.restored} total_bytes=\{total.stringify()} output_committed=\{stream_published() != 0} \{message}"
  }
  stderr(@utf8.encode((line + "\n")[:]))
}

///|
fn StreamProgress::checkpoint(
  self : StreamProgress,
  point : Int32,
) -> Unit raise StreamCancelled {
  if !self.committing &&
    self.session > 0 &&
    interrupt_poll(self.session, point) != 0 {
    self.cancelled = true
    raise StreamCancelled
  }
}

///|
fn StreamProgress::phase(self : StreamProgress, stage : String) -> Unit {
  self.stage = stage
  self.emit("phase", "")
}

///|
fn StreamProgress::recovered(
  self : StreamProgress,
  count : Int32,
) -> Unit raise StreamCancelled {
  self.restored += count.to_int64()
  if self.restored - self.reported >= 65536L ||
    self.total == Some(self.restored) {
    self.reported = self.restored
    self.emit(
      "progress", "Temporary bytes; final validation/delivery still pending",
    )
  }
  self.checkpoint(21)
}

///|
// An interrupted native operation/pull may raise before reaching the next
// ordinary checkpoint. Confirm a pending request on this error boundary too.
fn StreamProgress::record_failure(
  self : StreamProgress,
  message : String,
) -> Int32 {
  if !self.committing &&
    self.session > 0 &&
    interrupt_poll(self.session, 0) != 0 {
    self.cancelled = true
    self.detail = "Cancellation confirmed"
  } else {
    self.detail = message
  }
  0
}

///|
fn StreamProgress::attempt(
  self : StreamProgress,
  work : () -> Unit raise,
) -> Int32 {
  try {
    work()
    1
  } catch {
    StreamCancelled => {
      self.cancelled = true
      self.detail = "Cancellation confirmed"
      0
    }
    StreamError(message) => self.record_failure(message)
    e => self.record_failure("Decompression: " + @debug.to_string(e))
  }
}

///|
// One operation owns its session, counters, decision and result. No exit inside
// the operation lets private tests prove a cancelled call can be followed by one.
fn stream_operation(config : CliConfig) -> Int32 {
  let state = StreamProgress::{
    mode: config.progress,
    session: 0,
    stage: "opening",
    restored: 0L,
    total: None,
    reported: 0L,
    cancelled: false,
    committing: false,
    detail: "",
  }
  // Begin resets the native publication/notification identity before any event.
  state.session = interrupt_begin()
  state.emit("start", "Byte progress is not overall operation completion")
  let mut ok = 0
  if state.session > 0 {
    ok = state.attempt(() => {
      state.checkpoint(1)
      stream_run(config, state)
    })
  } else {
    state.detail = "Install interrupt notification failed"
  }
  stream_abort()
  if config.operation == "verify" && ok != 0 {
    ok = state.attempt(() => {
      state.checkpoint(0)
      stream_require(io_failed() == 0, "Closing verification inputs failed")
    })
  }
  if state.session > 0 && interrupt_end(state.session) == 0 {
    ok = 0
    state.detail += "; interrupt handler restoration failed"
  }
  let published = stream_published() != 0
  let mut code = if ok != 0 {
    0
  } else if state.cancelled && !published {
    130
  } else {
    1
  }
  // A cancellation request is never reclassified after the commit gate.
  if config.operation == "patch" && code == 0 && !published {
    code = 1
    state.detail = "Delivery returned without publication"
  }
  if code == 0 {
    state.stage = "complete"
    if config.operation == "patch" {
      state.emit("complete", "All checks and delivery completed")
    }
  } else {
    let native = if io_failed() != 0 {
      "; " + @utf8.decode_lossy(io_error()[:])
    } else {
      ""
    }
    state.emit(
      if code == 130 {
        "cancelled"
      } else {
        "error"
      },
      state.detail + native,
    )
  }
  code
}
