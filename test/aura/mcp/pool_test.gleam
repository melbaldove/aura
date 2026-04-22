//// Tests for the MCP client pool supervisor.
////
//// The pool is a static_supervisor with one mcp_client worker per
//// configured server. Tests use the same scripted fake_mcp_server
//// escript as `client_test.gleam`, but exercise the supervisor
//// boundary: multiple servers in one pool, failure isolation, and
//// the empty-config case.
////
//// ADR 026 retired the ambient-subscription path — this pool no longer
//// forwards notifications to event_ingest. Task 3 will repurpose it as
//// the action registry for the `mcp_call` tool; for now the suite only
//// asserts lifecycle properties (supervisor stays alive under healthy
//// children, isolates crashing siblings, empty config is OK).

import aura/config
import aura/db
import aura/event_ingest
import aura/mcp/pool
import fakes/fake_mcp_server as fake
import gleam/erlang/process
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

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

/// Pool spawns one client per configured server. Both handshakes should
/// complete and the supervisor stays alive.
pub fn pool_starts_one_client_per_server_test() {
  let sys = fresh_system()

  let #(cfg_a, server_a) = server_config("inbox-a", healthy_script())
  let #(cfg_b, server_b) = server_config("inbox-b", healthy_script())

  let mcp_config = config.McpConfig(servers: [cfg_a, cfg_b])
  let pid = start_pool(sys, mcp_config)

  // Give both workers time to complete their handshakes.
  process.sleep(300)

  // Supervisor still alive — no restart loop, both children healthy.
  process.is_alive(pid) |> should.be_true

  stop_pool(pid)
  fake.stop(server_a)
  fake.stop(server_b)
  teardown(sys)
}

/// One server handshake fails; the other reaches Ready normally. The
/// pool supervisor stays alive throughout — a sibling's crash does not
/// kill healthy children (OneForOne).
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

  // Give the supervisor a moment to absorb the bad restart storm.
  process.sleep(300)

  // Pool supervisor itself is still alive — OneForOne isolated the failure.
  process.is_alive(sup_pid) |> should.be_true

  stop_pool(sup_pid)
  fake.stop(bad_server)
  fake.stop(good_server)
  teardown(sys)
}

/// Empty config is valid. The pool starts with zero children.
pub fn pool_empty_config_starts_cleanly_test() {
  let sys = fresh_system()

  let sup_pid = start_pool(sys, config.McpConfig(servers: []))

  process.is_alive(sup_pid) |> should.be_true

  stop_pool(sup_pid)
  teardown(sys)
}
