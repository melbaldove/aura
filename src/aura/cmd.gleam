/// Run an OS command with timeout, returning (exit_code, stdout, stderr)
pub fn run(
  program: String,
  args: List(String),
  timeout_ms: Int,
) -> Result(#(Int, String, String), String) {
  run_command_ffi(program, args, timeout_ms)
}

@external(erlang, "aura_skill_ffi", "run_command")
fn run_command_ffi(
  program: String,
  args: List(String),
  timeout_ms: Int,
) -> Result(#(Int, String, String), String)
