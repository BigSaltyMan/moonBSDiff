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
fn parse_manifest(
  data : Bytes,
  limits : @moonbsdiff.Limits,
) -> PreparedManifest raise ManifestFault {
  let text = @utf8.decode(data[:], ignore_bom=false) catch {
    _ => raise Rejected(InvalidEncoding)
  }
  let json = @json.parse(
    text[:],
    max_nesting_depth=8,
    reject_duplicate_keys=true,
    preserve_number_repr=true,
  ) catch {
    error => {
      let field = match error {
        @json.DuplicateKey(_, name) => Some(name)
        _ => None
      }
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
