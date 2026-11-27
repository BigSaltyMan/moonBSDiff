///|
priv suberror ManifestFault {
  Rejected(ManifestError)
}

///|
fn manifest_object(
  value : @json.Json,
  keys : Array[String],
  context : String,
) -> Map[String, @json.Json] raise ManifestFault {
  let fields = match value {
    @json.Object(fields) => fields
    _ =>
      raise Rejected(
        InvalidSchema(
          field=context,
          detail="manifest schema: " + context + " must be an object",
        ),
      )
  }
  for key in keys {
    if fields.get(key) is None {
      let field = if context == "root" { key } else { context + "." + key }
      raise Rejected(
        InvalidSchema(field~, detail="manifest schema: missing " + field),
      )
    }
  }
  for key, _ in fields {
    if !keys.contains(key) {
      let field = if context == "root" { key } else { context + "." + key }
      raise Rejected(
        InvalidSchema(
          field~,
          detail="manifest schema: unknown fields in " + context,
        ),
      )
    }
  }
  fields
}

///|
fn manifest_string(
  value : @json.Json,
  field : String,
) -> String raise ManifestFault {
  match value {
    @json.String(value) => value
    _ =>
      raise Rejected(
        InvalidSchema(
          field~,
          detail="manifest schema: " + field + " must be a string",
        ),
      )
  }
}

///|
fn content_identity(
  value : @json.Json,
  context : String,
) -> ContentIdentity raise ManifestFault {
  let fields = manifest_object(value, ["size_bytes", "sha256"], context)
  let size_field = context + ".size_bytes"
  let text = manifest_string(fields["size_bytes"], size_field)
  let raw = @utf8.encode(text[:])
  if raw.length() == 0 {
    raise Rejected(
      InvalidSchema(
        field=size_field,
        detail="manifest size: " + context + " is empty",
      ),
    )
  }
  let mut size = 0L
  for byte in raw {
    let digit = byte.to_int() - 48
    if digit < 0 || digit > 9 {
      raise Rejected(
        InvalidSchema(
          field=size_field,
          detail="manifest size: " +
            context +
            " requires nonnegative ASCII decimal digits",
        ),
      )
    }
    if size > (9223372036854775807L - digit.to_int64()) / 10L {
      raise Rejected(
        InvalidSchema(
          field=size_field,
          detail="manifest size: " + context + " overflows Int64",
        ),
      )
    }
    size = size * 10L + digit.to_int64()
  }
  let hash_field = context + ".sha256"
  let hash = manifest_string(fields["sha256"], hash_field)
  let encoded = @utf8.encode(hash[:])
  if encoded.length() != 64 {
    raise Rejected(
      InvalidSchema(
        field=hash_field,
        detail="manifest sha256: " +
          context +
          " requires 64 lowercase hex digits",
      ),
    )
  }
  for byte in encoded {
    let code = byte.to_int()
    if !((code >= 48 && code <= 57) || (code >= 97 && code <= 102)) {
      raise Rejected(
        InvalidSchema(
          field=hash_field,
          detail="manifest sha256: " +
            context +
            " requires lowercase hex digits",
        ),
      )
    }
  }
  { size, hash, }
}

///|
fn json_exceeds_max_depth(text : StringView, max_depth : Int32) -> Bool {
  let mut depth = 0
  let mut in_string = false
  let mut escaped = false
  for i = 0; i < text.length(); i = i + 1 {
    let ch = text.code_unit_at(i)
    if in_string {
      if escaped {
        escaped = false
      } else if ch == 0x5c {
        escaped = true
      } else if ch == 0x22 {
        in_string = false
      }
    } else if ch == 0x22 {
      in_string = true
    } else if ch == 0x7b || ch == 0x5b {
      depth = depth + 1
      if depth > max_depth {
        return true
      }
    } else if ch == 0x7d || ch == 0x5d {
      if depth > 0 {
        depth = depth - 1
      }
    }
  }
  false
}

///|
fn json_parse_error_loc(pos : @json.Json) -> String? {
  match pos {
    @json.Object(fields) =>
      match (fields.get("line"), fields.get("column")) {
        (Some(@json.Number(line, ..)), Some(@json.Number(col, ..))) =>
          Some("line \{line.to_int()}, column \{col.to_int()}")
        _ => None
      }
    _ => None
  }
}

///|
fn json_duplicate_key_field(error : @json.ParseError) -> String? {
  match @json.Json(error) {
    @json.Array([@json.String("DuplicateKey"), _, @json.String(name)]) =>
      Some(name)
    @json.Object(fields) =>
      match (fields.get("$tag"), fields.get("1")) {
        (Some(@json.String("DuplicateKey")), Some(@json.String(name))) =>
          Some(name)
        _ => None
      }
    _ => None
  }
}

///|
fn json_format_redacted_parse_error(error : @json.ParseError) -> String {
  let (tag, pos) : (String, @json.Json?) = match @json.Json(error) {
    @json.String(t) => (t, None)
    @json.Array([@json.String(t)]) => (t, None)
    @json.Array([@json.String(t), p, ..]) => (t, Some(p))
    @json.Object(fields) =>
      match fields.get("$tag") {
        Some(@json.String(t)) => (t, fields.get("0"))
        _ => ("", None)
      }
    _ => ("", None)
  }
  let loc_opt = match pos {
    Some(p) => json_parse_error_loc(p)
    None => None
  }
  match tag {
    "InvalidChar" =>
      match loc_opt {
        Some(loc) => "invalid character at \{loc}"
        None => "invalid character"
      }
    "InvalidNumber" =>
      match loc_opt {
        Some(loc) => "invalid number at \{loc}"
        None => "invalid number"
      }
    "InvalidIdentEscape" =>
      match loc_opt {
        Some(loc) => "invalid escape at \{loc}"
        None => "invalid escape"
      }
    "DuplicateKey" =>
      match loc_opt {
        Some(loc) => "duplicate key at \{loc}"
        None => "duplicate key"
      }
    "InvalidEof" => "unexpected end of input"
    "DepthLimitExceeded" => "nesting depth limit exceeded"
    _ => "invalid json"
  }
}

///|
fn parse_manifest(
  data : Bytes,
  limits : @moonbsdiff.Limits,
) -> PreparedManifest raise ManifestFault {
  if data is [0xef, 0xbb, 0xbf, ..] {
    raise Rejected(InvalidEncoding)
  }
  let text = @utf8.decode(data[:], ignore_bom=false) catch {
    _ => raise Rejected(InvalidEncoding)
  }
  if json_exceeds_max_depth(text[:], 8) {
    raise Rejected(InvalidJson(field=None, detail="DepthLimitExceeded"))
  }
  let json = @json.parse(
    text[:],
    reject_duplicate_keys=true,
    preserve_number_repr=true,
  ) catch {
    error => {
      let field = json_duplicate_key_field(error)
      raise Rejected(InvalidJson(field~, detail=@debug.to_string(error)))
    }
  }
  let fields = manifest_object(
    json,
    ["schema_version", "patch_format", "producer", "old", "new", "patch"],
    "root",
  )
  if !(fields["schema_version"] is @json.Number(_, repr=Some("1"))) {
    raise Rejected(
      InvalidSchema(
        field="schema_version",
        detail="manifest schema_version: expected integer 1",
      ),
    )
  }
  if manifest_string(fields["patch_format"], "patch_format") != "BSDIFF40" {
    raise Rejected(
      InvalidSchema(
        field="patch_format",
        detail="manifest patch_format: only BSDIFF40 is supported",
      ),
    )
  }
  let producer = manifest_object(
    fields["producer"],
    ["name", "version"],
    "producer",
  )
  manifest_string(producer["name"], "producer.name") |> ignore
  manifest_string(producer["version"], "producer.version") |> ignore
  {
    old: content_identity(fields["old"], "old"),
    new: content_identity(fields["new"], "new"),
    patch: content_identity(fields["patch"], "patch"),
    limits,
  }
}
