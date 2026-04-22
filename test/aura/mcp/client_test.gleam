import aura/mcp/client
import fakes/fake_mcp_server as fake
import gleam/erlang/process.{type Subject}
import gleam/json
import gleam/option.{None}
import gleam/string
import gleeunit
import gleeunit/should

pub fn main() {
  gleeunit.main()
}

// ---------------------------------------------------------------------------
// Test helpers
// ---------------------------------------------------------------------------

/// Build a default client config pointing at the given fake server.
fn make_config(
  server: fake.FakeMcpServer,
  name: String,
) -> client.ClientConfig {
  client.new_config(
    name: name,
    command: fake.command(server),
    args: fake.args(server),
    env: [],
  )
}

/// Same as `make_config` but with a custom handshake deadline — used by the
/// deadline test so we don't hold the suite for 30s.
fn make_config_with_deadline(
  server: fake.FakeMcpServer,
  name: String,
  deadline_ms: Int,
) -> client.ClientConfig {
  let base = make_config(server, name)
  client.ClientConfig(..base, handshake_timeout_ms: deadline_ms)
}

/// Start a client and unlink the actor from the test process. Required
/// whenever the test expects the actor to stop abnormally: `actor.start`
/// links to the caller, and an abnormal exit propagates EXIT, killing the
/// test. We unlink immediately so the test can observe death via a
/// monitor instead.
fn start_unlinked(config: client.ClientConfig) -> Subject(client.ClientMessage) {
  let assert Ok(started) = client.start(config, None)
  case process.subject_owner(started.data) {
    Ok(pid) -> process.unlink(pid)
    Error(_) -> Nil
  }
  started.data
}

fn monitor_subject(
  subject: Subject(client.ClientMessage),
) -> process.Monitor {
  let assert Ok(pid) = process.subject_owner(subject)
  process.monitor(pid)
}

fn await_down(monitor: process.Monitor, timeout_ms: Int) -> Bool {
  let result =
    process.selector_receive(
      process.new_selector()
        |> process.select_specific_monitor(monitor, fn(d) { d }),
      timeout_ms,
    )
  case result {
    Ok(_) -> True
    Error(_) -> False
  }
}

/// Wait for the monitored process to exit and classify the down reason.
/// Returns Ok(True) for a Normal exit, Ok(False) for an Abnormal/Killed
/// exit, Error(Nil) on timeout.
fn await_down_normal(
  monitor: process.Monitor,
  timeout_ms: Int,
) -> Result(Bool, Nil) {
  process.selector_receive(
    process.new_selector()
      |> process.select_specific_monitor(monitor, fn(down) {
        case down {
          process.ProcessDown(reason: process.Normal, ..) -> True
          process.PortDown(reason: process.Normal, ..) -> True
          _ -> False
        }
      }),
    timeout_ms,
  )
}

/// Wait for the monitored process and return the abnormal reason as a
/// string (best-effort via `string.inspect`). Returns Error on timeout or
/// on a non-abnormal stop.
fn await_down_abnormal_reason(
  monitor: process.Monitor,
  timeout_ms: Int,
) -> Result(String, Nil) {
  let down =
    process.selector_receive(
      process.new_selector()
        |> process.select_specific_monitor(monitor, fn(d) { d }),
      timeout_ms,
    )
  case down {
    Ok(process.ProcessDown(reason: process.Abnormal(reason), ..)) ->
      Ok(string.inspect(reason))
    Ok(process.PortDown(reason: process.Abnormal(reason), ..)) ->
      Ok(string.inspect(reason))
    _ -> Error(Nil)
  }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

/// Scripted handshake: initialize → response → notifications/initialized.
/// Client must reach Ready without crashing on the simplified state machine
/// (no subscribe phase). We observe liveness at ~200ms.
pub fn client_reaches_ready_after_handshake_test() {
  let server =
    fake.start([
      fake.ExpectRequest("initialize"),
      fake.RespondResult(fake.initialize_result_json()),
      fake.ExpectNotification("notifications/initialized"),
      // Block forever so the subprocess stays alive while we check liveness.
      fake.ExpectRequest("__never__"),
    ])
  let subject =
    start_unlinked(
      client.ClientConfig(..make_config(server, "inbox"), handshake_timeout_ms: 1000),
    )

  // Give the handshake a moment to complete.
  process.sleep(200)

  let assert Ok(pid) = process.subject_owner(subject)
  process.is_alive(pid) |> should.be_true

  client.stop(subject)
  fake.stop(server)
}

pub fn client_fails_start_on_malformed_init_test() {
  let server =
    fake.start([
      fake.ExpectRequest("initialize"),
      fake.EmitRaw("this-is-not-json"),
      // Stay alive long enough for the malformed line to reach the client
      // and for the client to abort the handshake.
      fake.ExpectRequest("__unreachable__"),
    ])
  let subject = start_unlinked(make_config(server, "inbox"))
  let monitor = monitor_subject(subject)
  await_down(monitor, 3000) |> should.be_true
  fake.stop(server)
}

/// Server reaches Ready then exits 0 (script ends, escript halts 0).
/// Client should treat this as a normal stop — no supervisor restart.
pub fn client_handles_clean_exit_as_normal_stop_test() {
  let server =
    fake.start([
      fake.ExpectRequest("initialize"),
      fake.RespondResult(fake.initialize_result_json()),
      fake.ExpectNotification("notifications/initialized"),
      // Script ends — escript exits 0. Clean exit from Ready ≠ crash.
    ])
  let subject = start_unlinked(make_config(server, "inbox"))
  let monitor = monitor_subject(subject)

  let result = await_down_normal(monitor, 3000)
  result |> should.equal(Ok(True))
  fake.stop(server)
}

/// Server reaches Ready then exits with a non-zero code. Client should
/// stop abnormally so the supervisor restarts it.
pub fn client_handles_crash_exit_as_abnormal_test() {
  let server =
    fake.start([
      fake.ExpectRequest("initialize"),
      fake.RespondResult(fake.initialize_result_json()),
      fake.ExpectNotification("notifications/initialized"),
      fake.ExitWithCode(42),
    ])
  let subject = start_unlinked(make_config(server, "inbox"))
  let monitor = monitor_subject(subject)

  let reason = await_down_abnormal_reason(monitor, 3000)
  case reason {
    Ok(s) ->
      string.contains(s, "exit")
      |> should.be_true
    Error(_) -> should.fail()
  }
  fake.stop(server)
}

pub fn client_handles_initialize_error_response_test() {
  let server =
    fake.start([
      fake.ExpectRequest("initialize"),
      fake.RespondError(-32_603, "server boom"),
      fake.ExpectRequest("__unreachable__"),
    ])
  let subject = start_unlinked(make_config(server, "inbox"))
  let monitor = monitor_subject(subject)
  await_down(monitor, 3000) |> should.be_true
  fake.stop(server)
}

/// Server never responds to `initialize`. The client should trip its
/// handshake deadline and stop abnormally. A short (100ms) deadline keeps
/// the test fast.
pub fn client_handshake_deadline_stops_actor_test() {
  let server =
    fake.start([
      fake.ExpectRequest("initialize"),
      // No RESPOND_RESULT. The escript then blocks on the next expected
      // request, which will never come — the subprocess stays up but
      // silent, tripping the client's handshake deadline.
      fake.ExpectRequest("__never_sent__"),
    ])
  let subject =
    start_unlinked(make_config_with_deadline(server, "inbox", 100))
  let monitor = monitor_subject(subject)

  let reason = await_down_abnormal_reason(monitor, 3000)
  case reason {
    Ok(s) ->
      string.contains(s, "handshake deadline")
      |> should.be_true
    Error(_) -> should.fail()
  }
  fake.stop(server)
}

// ---------------------------------------------------------------------------
// call_tool tests
// ---------------------------------------------------------------------------

/// Happy path: after the handshake completes, `call_tool` sends a
/// `tools/call` request, the server replies with a `result`, and the caller
/// receives the parsed JSON back.
pub fn client_call_tool_returns_server_result_test() {
  let tool_result_json =
    json.object([
      #(
        "content",
        json.preprocessed_array([
          json.object([
            #("type", json.string("text")),
            #("text", json.string("hello from tool")),
          ]),
        ]),
      ),
    ])
    |> json.to_string
  let server =
    fake.start([
      fake.ExpectRequest("initialize"),
      fake.RespondResult(fake.initialize_result_json()),
      fake.ExpectNotification("notifications/initialized"),
      fake.ExpectRequest("tools/call"),
      fake.RespondResult(tool_result_json),
      // Keep the subprocess alive for the duration of the test.
      fake.ExpectRequest("__never__"),
    ])
  let subject = start_unlinked(make_config(server, "inbox"))

  // Give the handshake a moment to complete before calling the tool.
  process.sleep(500)

  let result =
    client.call_tool(
      subject,
      "echo",
      json.object([#("text", json.string("hello"))]),
      5000,
    )
  result |> should.be_ok

  client.stop(subject)
  fake.stop(server)
}

/// If the server returns a JSON-RPC error for `tools/call`, `call_tool`
/// surfaces it as `Error("mcp tool error: <code> <message>")`.
pub fn client_call_tool_surfaces_server_error_test() {
  let server =
    fake.start([
      fake.ExpectRequest("initialize"),
      fake.RespondResult(fake.initialize_result_json()),
      fake.ExpectNotification("notifications/initialized"),
      fake.ExpectRequest("tools/call"),
      fake.RespondError(-32_603, "tool not found"),
      fake.ExpectRequest("__never__"),
    ])
  let subject = start_unlinked(make_config(server, "inbox"))

  process.sleep(500)

  let result =
    client.call_tool(
      subject,
      "missing",
      json.object([]),
      5000,
    )
  case result {
    Error(msg) -> {
      string.contains(msg, "mcp tool error") |> should.be_true
      string.contains(msg, "tool not found") |> should.be_true
    }
    Ok(_) -> should.fail()
  }

  client.stop(subject)
  fake.stop(server)
}

/// If `call_tool` times out waiting for a response, the actor must drop
/// the stale pending entry so it doesn't leak if the server never
/// replies. We can't introspect the pending dict directly, so the
/// strongest available proxy is: after a timeout, does a follow-up
/// `call_tool` work end-to-end? If the actor were wedged by the
/// abandoned pending entry, the second call would never complete.
///
/// Script: handshake → first `tools/call` is observed but never
/// answered (the fake blocks on its next expected step) → second
/// `tools/call` is answered normally. The first call hits its 200ms
/// timeout (and the error surfaces the tool name per L2 of the quality
/// review); the second call returns the server's result.
pub fn client_call_tool_timeout_cleans_up_pending_test() {
  let tool_result_json =
    json.object([
      #(
        "content",
        json.preprocessed_array([
          json.object([
            #("type", json.string("text")),
            #("text", json.string("ok")),
          ]),
        ]),
      ),
    ])
    |> json.to_string
  let server =
    fake.start([
      fake.ExpectRequest("initialize"),
      fake.RespondResult(fake.initialize_result_json()),
      fake.ExpectNotification("notifications/initialized"),
      // First tools/call: observed, never answered. The fake then
      // advances to waiting for the second tools/call; until we send
      // it the subprocess sits silent, which is what triggers the
      // client's receive timeout.
      fake.ExpectRequest("tools/call"),
      // Second tools/call: answered successfully.
      fake.ExpectRequest("tools/call"),
      fake.RespondResult(tool_result_json),
      fake.ExpectRequest("__never__"),
    ])
  let subject = start_unlinked(make_config(server, "inbox"))

  process.sleep(500)

  // First call times out. Error message must name the tool.
  let first =
    client.call_tool(subject, "slow_tool", json.object([]), 200)
  case first {
    Error(msg) -> {
      string.contains(msg, "timed out") |> should.be_true
      string.contains(msg, "slow_tool") |> should.be_true
    }
    Ok(_) -> should.fail()
  }

  // Let the CancelPendingToolCall land before the second call.
  process.sleep(50)

  // Second call must succeed end-to-end — the actor isn't wedged and
  // the abandoned pending entry didn't swallow the new correlation id.
  let second =
    client.call_tool(subject, "fast_tool", json.object([]), 5000)
  second |> should.be_ok

  client.stop(subject)
  fake.stop(server)
}

/// If `call_tool` is invoked before the handshake completes, the actor
/// replies immediately with `"mcp client not ready"` rather than queuing
/// the request. The server stalls on `initialize` so the client stays in
/// `Handshaking` for the duration of the call.
pub fn client_call_tool_before_ready_returns_error_test() {
  let server =
    fake.start([
      fake.ExpectRequest("initialize"),
      // No RESPOND_RESULT — the subprocess waits for the next request
      // that will never come, so the client stays Handshaking.
      fake.ExpectRequest("__never_sent__"),
    ])
  // Long handshake deadline so the actor doesn't trip during the test.
  let subject =
    start_unlinked(make_config_with_deadline(server, "inbox", 10_000))

  let result =
    client.call_tool(
      subject,
      "echo",
      json.object([]),
      1000,
    )
  case result {
    Error(msg) -> msg |> should.equal("mcp client not ready")
    Ok(_) -> should.fail()
  }

  client.stop(subject)
  fake.stop(server)
}
