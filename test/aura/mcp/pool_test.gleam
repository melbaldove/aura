//// Tests for the MCP client pool supervisor.
////
//// The pool is a static_supervisor with one mcp_client worker per
//// configured server. Each client registers itself under
//// `aura_mcp_<server_name>` so `pool.get_client/1` can resolve the string
//// name to a subject at runtime — that's what Task 3 tests strengthen.
////
//// The suite exercises both the supervisor boundary (multiple servers in
//// one pool, failure isolation, empty config) and the registry surface
//// (handshake completion observable via lookup, unknown name returns
//// None, round-trip `call_tool` through a registered client).
////
//// ADR 026 retired the ambient-subscription path — this pool no longer
//// forwards notifications to event_ingest. Liveness-only assertions
//// (Task 1) have been replaced with registry-based assertions that
//// verify the client is both alive AND past the handshake (since
//// actor.named registers before the initialiser runs, we additionally
//// call_tool or observe behavior when we need proof of Ready).

import aura/config
import aura/db
import aura/event_ingest
import aura/mcp/client
import aura/mcp/pool
import fakes/fake_mcp_server as fake
import gleam/erlang/process
import gleam/json
import gleam/option.{None, Some}
import gleam/otp/static_supervisor
import gleeunit
import gleeunit/should

pub fn main() {
  gleeunit.main()
}

// ---------------------------------------------------------------------------
// Setup
// ---------------------------------------------------------------------------

type System {
  System(
    db_subject: process.Subject(db.DbMessage),
    ingest_subject: process.Subject(event_ingest.IngestMessage),
  )
}

fn fresh_system() -> System {
  let assert Ok(db_subject) = db.start(":memory:")
  let assert Ok(started) = event_ingest.start(db_subject)
  System(db_subject: db_subject, ingest_subject: started.data)
}

fn teardown(sys: System) -> Nil {
  case process.subject_owner(sys.ingest_subject) {
    Ok(pid) -> {
      process.unlink(pid)
      process.kill(pid)
    }
    Error(_) -> Nil
  }
  process.send(sys.db_subject, db.Shutdown)
  Nil
}

/// Start the pool's internal static_supervisor directly so the test can
/// hold onto the supervisor Pid (for liveness checks) and shut it down
/// cleanly at end of test. Production wiring goes through `pool.supervised`
/// mounted under the root supervisor.
fn start_pool(
  _sys: System,
  mcp_config: config.McpConfig,
) -> process.Pid {
  let b = pool.builder(mcp_config)
  let assert Ok(started) = static_supervisor.start(b)
  // Unlink so a supervisor restart storm doesn't kill the test process.
  process.unlink(started.pid)
  started.pid
}

fn stop_pool(pid: process.Pid) -> Nil {
  process.kill(pid)
  // Give the supervisor a tick to kill its children and their ports.
  process.sleep(20)
  Nil
}

fn server_config(
  name: String,
  steps: List(fake.Step),
) -> #(config.McpServerConfig, fake.FakeMcpServer) {
  let server = fake.start(steps)
  let cfg =
    config.McpServerConfig(
      name: name,
      transport: config.StdioTransport,
      command: fake.command(server),
      args: fake.args(server),
      env: [],
    )
  #(cfg, server)
}

fn healthy_script() -> List(fake.Step) {
  [
    fake.ExpectRequest("initialize"),
    fake.RespondResult(fake.initialize_result_json()),
    fake.ExpectNotification("notifications/initialized"),
    // Block forever so the subprocess stays alive until the test kills the
    // pool supervisor.
    fake.ExpectRequest("__never_sent__"),
  ]
}

/// A handshake-able script that also answers one scripted `tools/call` with
/// the given result JSON. Used by tests that need to assert "the handshake
/// completed" via a successful tool call, since registration alone is not
/// proof of Ready (actor.named registers before the initialiser runs).
fn healthy_script_with_tool(tool_result_json: String) -> List(fake.Step) {
  [
    fake.ExpectRequest("initialize"),
    fake.RespondResult(fake.initialize_result_json()),
    fake.ExpectNotification("notifications/initialized"),
    fake.ExpectRequest("tools/call"),
    fake.RespondResult(tool_result_json),
    fake.ExpectRequest("__never_sent__"),
  ]
}

fn ok_tool_result() -> String {
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
}

/// Poll `predicate` every 25ms until it returns True or the deadline
/// expires. Returns True on success, False on timeout. Used to observe
/// asynchronous handshake / registration progress without sprinkling
/// fragile fixed sleeps through the suite.
fn wait_until(predicate: fn() -> Bool, timeout_ms: Int) -> Bool {
  case predicate() {
    True -> True
    False ->
      case timeout_ms <= 0 {
        True -> False
        False -> {
          process.sleep(25)
          wait_until(predicate, timeout_ms - 25)
        }
      }
  }
}

/// Poll until `pool.get_client(name)` resolves, up to `timeout_ms`. Because
/// the actor registers its name *before* the initialiser runs (that's how
/// `actor.named` works), observing Some() here means the worker is alive
/// but not necessarily Ready. Tests that need proof of Ready drive a
/// `call_tool` through the returned subject — Handshaking clients return
/// `"mcp client not ready"` synchronously.
fn await_registered(name: String, timeout_ms: Int) -> Bool {
  wait_until(fn() { pool.get_client(name) != None }, timeout_ms)
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

/// Pool spawns one client per configured server. Both handshakes should
/// complete and each client is discoverable via `pool.get_client`. This
/// replaces the old liveness-only test — we prove the handshake via a
/// successful round-trip tool call on each worker (registration alone is
/// not proof of Ready, since `actor.named` registers the pid before the
/// initialiser runs).
pub fn pool_starts_one_client_per_server_and_handshakes_test() {
  let sys = fresh_system()

  let #(cfg_a, server_a) =
    server_config("inbox-a", healthy_script_with_tool(ok_tool_result()))
  let #(cfg_b, server_b) =
    server_config("inbox-b", healthy_script_with_tool(ok_tool_result()))

  let mcp_config = config.McpConfig(servers: [cfg_a, cfg_b])
  let pid = start_pool(sys, mcp_config)

  // Both clients register at start — observe that first.
  await_registered("inbox-a", 2000) |> should.be_true
  await_registered("inbox-b", 2000) |> should.be_true

  let assert Some(subj_a) = pool.get_client("inbox-a")
  let assert Some(subj_b) = pool.get_client("inbox-b")

  // Now prove each is past the handshake by driving a tool call through
  // the registered subject. A client still in Handshaking returns
  // `"mcp client not ready"` synchronously.
  wait_for_ready_call(
    fn() { client.call_tool(subj_a, "ping", json.object([]), 5000) },
    2000,
  )
  |> should.be_ok
  wait_for_ready_call(
    fn() { client.call_tool(subj_b, "ping", json.object([]), 5000) },
    2000,
  )
  |> should.be_ok

  // Supervisor still alive — no restart loop.
  process.is_alive(pid) |> should.be_true

  stop_pool(pid)
  fake.stop(server_a)
  fake.stop(server_b)
  teardown(sys)
}

/// Unknown names return None. Sanity check that `get_client` doesn't
/// resolve arbitrary strings to ghost pids — the atom for an unregistered
/// string must look unregistered.
pub fn pool_get_client_returns_none_for_unknown_test() {
  let sys = fresh_system()

  let #(cfg, server) = server_config("gmail", healthy_script())
  let pid = start_pool(sys, config.McpConfig(servers: [cfg]))

  await_registered("gmail", 2000) |> should.be_true

  pool.get_client("linear") |> should.equal(None)

  stop_pool(pid)
  fake.stop(server)
  teardown(sys)
}

/// One server handshake fails; the other stays discoverable. The pool
/// supervisor stays alive throughout — a sibling's crash does not kill
/// healthy children (OneForOne). Stronger than the Task 1 liveness check:
/// we assert the healthy client is registered, not just "the supervisor
/// pid responds".
pub fn pool_one_client_crash_does_not_kill_others_test() {
  let sys = fresh_system()

  // Bad server: emits malformed JSON while the client is still in
  // Handshaking. The client stops abnormally; the supervisor will try
  // to restart. Each restart repeats the same failure — but with
  // intensity 10 / 60s we have enough budget for the healthy server to
  // stay up.
  let #(bad_cfg, bad_server) =
    server_config("bad", [
      fake.ExpectRequest("initialize"),
      fake.EmitRaw("not-json"),
      fake.ExpectRequest("__unreachable__"),
    ])

  let #(good_cfg, good_server) = server_config("good", healthy_script())

  let sup_pid = start_pool(sys, config.McpConfig(servers: [bad_cfg, good_cfg]))

  await_registered("good", 2000) |> should.be_true

  // Pool supervisor itself is still alive — OneForOne isolated the failure.
  process.is_alive(sup_pid) |> should.be_true

  // The healthy sibling is still registered — the bad sibling's restart
  // storm hasn't taken it down.
  pool.get_client("good") |> should.not_equal(None)

  stop_pool(sup_pid)
  fake.stop(bad_server)
  fake.stop(good_server)
  teardown(sys)
}

/// Empty config is valid. The pool starts with zero children and nothing
/// is in the registry.
pub fn pool_empty_config_starts_cleanly_test() {
  let sys = fresh_system()

  let sup_pid = start_pool(sys, config.McpConfig(servers: []))

  process.is_alive(sup_pid) |> should.be_true
  pool.get_client("anything") |> should.equal(None)

  stop_pool(sup_pid)
  teardown(sys)
}

/// End-to-end smoke: look up a registered client via `pool.get_client`
/// and call a tool through the returned subject. Validates the full
/// registry → lookup → use flow that the brain will exercise to issue
/// actions.
pub fn pool_call_tool_roundtrips_through_registered_client_test() {
  let sys = fresh_system()

  let tool_result_json =
    json.object([
      #(
        "content",
        json.preprocessed_array([
          json.object([
            #("type", json.string("text")),
            #("text", json.string("pong")),
          ]),
        ]),
      ),
    ])
    |> json.to_string

  let #(cfg, server) =
    server_config("echo", healthy_script_with_tool(tool_result_json))

  let sup_pid = start_pool(sys, config.McpConfig(servers: [cfg]))

  // Registration is synchronous with actor start; handshake is not. Poll
  // for the named subject, then retry `call_tool` while it returns
  // "mcp client not ready" (Handshaking). A success proves both (a) the
  // client is registered under its configured string name AND (b) the
  // handshake has completed.
  let assert Some(subject) = wait_until_some(fn() { pool.get_client("echo") }, 2000)

  wait_for_ready_call(
    fn() { client.call_tool(subject, "ping", json.object([]), 5000) },
    2000,
  )
  |> should.be_ok

  stop_pool(sup_pid)
  fake.stop(server)
  teardown(sys)
}

/// Poll until `f()` returns `Some(x)`; panic if the deadline expires.
/// Parallel of `await_registered` but returns the value rather than a
/// boolean.
fn wait_until_some(
  f: fn() -> option.Option(a),
  timeout_ms: Int,
) -> option.Option(a) {
  case f() {
    Some(v) -> Some(v)
    None ->
      case timeout_ms <= 0 {
        True -> None
        False -> {
          process.sleep(25)
          wait_until_some(f, timeout_ms - 25)
        }
      }
  }
}

/// Retry `f()` while it returns `Error("mcp client not ready")`. Surfaces
/// the first Ok or terminal Error (other than "not ready"). Used to let
/// the handshake complete without a brittle fixed sleep.
fn wait_for_ready_call(
  f: fn() -> Result(a, String),
  timeout_ms: Int,
) -> Result(a, String) {
  case f() {
    Ok(v) -> Ok(v)
    Error("mcp client not ready") ->
      case timeout_ms <= 0 {
        True -> Error("mcp client not ready")
        False -> {
          process.sleep(25)
          wait_for_ready_call(f, timeout_ms - 25)
        }
      }
    Error(other) -> Error(other)
  }
}
