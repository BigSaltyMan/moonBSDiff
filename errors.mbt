///|
#derive(Eq, Debug)
pub(all) enum ErrorStage {
  Configuration
  Header
  Control
  Diff
  Extra
  Output
  Sorting
  Matching
}

///|
#derive(Eq, Debug)
pub(all) enum ErrorKind {
  InvalidConfiguration
  UnsupportedFormat
  TruncatedData
  InvalidField
  IntegerOverflow
  DecompressionFailed
  OutputOutOfBounds
  ResourceLimitExceeded
}

///|
/// Structured failure. Missing location or limit details are None.
#derive(Eq, Debug)
pub(all) struct BsdiffError {
  kind : ErrorKind
  stage : ErrorStage
  block : String?
  offset : Int64?
  field : String?
  value : Int64?
  limit : Int64?
}

///|
pub extend ErrorStage with Eq::{equal, not_equal}

///|
pub extend ErrorStage with @debug.Debug::{to_repr}

///|
pub extend ErrorKind with Eq::{equal, not_equal}

///|
pub extend ErrorKind with @debug.Debug::{to_repr}

///|
pub extend BsdiffError with Eq::{equal, not_equal}

///|
pub extend BsdiffError with @debug.Debug::{to_repr}
