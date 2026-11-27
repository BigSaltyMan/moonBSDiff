///|
#export_name("studio_version")
pub fn studio_version() -> String {
  j_obj({
    "studio": j_str("moonbsdiff-web-studio"),
    "studio_version": j_str(@manifest_support.PRODUCER_VERSION),
    "engine_version": j_str(@manifest_support.PRODUCER_VERSION),
    "target": j_str("js"),
    "capabilities": j_arr([
      j_str("update_graph"),
      j_str("patch_xray"),
      j_str("stream_oscilloscope"),
      j_str("dir_delta"),
    ]),
    "exports": j_arr([
      j_str("studio_version"),
      j_str("studio_run_graph_scenario"),
      j_str("studio_analyze_patch_preset"),
      j_str("studio_analyze_patch_hex"),
      j_str("studio_trace_stream_apply"),
      j_str("studio_run_dir_delta"),
    ]),
  }).stringify()
}

///|
#export_name("studio_run_graph_scenario")
pub fn studio_run_graph_scenario(request_json : String) -> String {
  run_graph_scenario_impl(request_json)
}

///|
#export_name("studio_analyze_patch_preset")
pub fn studio_analyze_patch_preset(
  preset_name : String,
  limit_preset : String,
) -> String {
  analyze_patch_preset_impl(preset_name, limit_preset)
}

///|
#export_name("studio_analyze_patch_hex")
pub fn studio_analyze_patch_hex(
  patch_hex : String,
  max_patch : Double,
  max_output : Double,
  max_decomp : Double,
  max_controls : Double,
) -> String {
  analyze_patch_hex_impl(
    patch_hex, max_patch, max_output, max_decomp, max_controls,
  )
}

///|
#export_name("studio_trace_stream_apply")
pub fn studio_trace_stream_apply(
  preset_name : String,
  abort_after_chunks : Double,
) -> String {
  trace_stream_apply_impl(preset_name, abort_after_chunks)
}

///|
#export_name("studio_run_dir_delta")
pub fn studio_run_dir_delta(request_json : String) -> String {
  run_dir_delta_impl(request_json)
}
