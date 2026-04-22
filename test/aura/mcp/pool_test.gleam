//// Tests for the MCP client pool supervisor.
////
//// The pool is a static_supervisor with one mcp_client worker per
//// configured server. Tests use the same scripted fake_mcp_server
//// escript as `client_test.gleam`, but exercise the supervisor
//// boundary: multiple servers in one pool, failure isolation, and
//// the empty-config case.

import aura/config
import aura/db
import aura/event_ingest
import aura/mcp/pool
import fakes/fake_mcp_server as fake
import gleam/erlang/process
import gleam/list
import gleam/option
import gleam/otp/static_supervisor
import gleeunit
import gleeunit/should
import poll

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
  sys: System,
  mcp_config: config.McpConfig,
) -> process.Pid {
  let b = pool.builder(mcp_config, sys.ingest_subject)
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
  subscribe: List(String),
) -> #(config.McpServerConfig, fake.FakeMcpServer) {
  let server = fake.start(steps)
  let cfg =
    config.McpServerConfig(
      name: name,
      transport: config.StdioTransport,
      command: fake.command(server),
      args: fake.args(server),
      env: [],
      subscribe: subscribe,
    )
  #(cfg, server)
}

fn healthy_script(uri: String) -> List(fake.Step) {
  [
    fake.ExpectRequest("initialize"),
    fake.RespondResult(fake.initialize_result_json()),
    fake.ExpectNotification("notifications/initialized"),
    fake.ExpectRequest("resources/subscribe"),
    fake.RespondResult(fake.subscribe_ok_json()),
    fake.EmitNotification(
      "notifications/resources/updated",
      "{\"uri\":\"" <> uri <> "\"}",
    ),
    // Block forever so the subprocess stays alive until the test kills the
    // pool supervisor.
    fake.ExpectRequest("__never_sent__"),
  ]
}

fn wait_for_event_source(sys: System, source: String) -> Bool {
  poll.poll_until(
    fn() {
      case
        db.search_events(
          sys.db_subject,
          "",
          option.None,
          option.Some(source),
          50,
        )
      {
        Ok(events) -> list.length(events) >= 1
        Error(_) -> False
      }
    },
    3000,
  )
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

/// Pool spawns one client per configured server. Both clients should
/// reach Ready and emit their scripted resource-updated notification,
/// which we observe via events landing in the DB.
pub fn pool_starts_one_client_per_server_test() {
  let sys = fresh_system()

  let #(cfg_a, server_a) =
    server_config("inbox-a", healthy_script("gmail://a/inbox"), [
      "gmail://a/inbox",
    ])
  let #(cfg_b, server_b) =
    server_config("inbox-b", healthy_script("gmail://b/inbox"), [
      "gmail://b/inbox",
    ])

  let mcp_config = config.McpConfig(servers: [cfg_a, cfg_b])
  let pid = start_pool(sys, mcp_config)

  wait_for_event_source(sys, "inbox-a") |> should.be_true
  wait_for_event_source(sys, "inbox-b") |> should.be_true

  stop_pool(pid)
  fake.stop(server_a)
  fake.stop(server_b)
  teardown(sys)
}

/// A server-emitted resource-updated notification should flow through
/// the pool's on_notification callback into event_ingest, land in the
/// DB as an AuraEvent with source = server name, and carry the URI as
/// the event subject + the full params as data.
pub fn pool_forwards_notifications_to_event_ingest_test() {
  let sys = fresh_system()

  let #(cfg, server) =
    server_config("gmail-work", healthy_script("gmail://work/inbox/42"), [
      "gmail://work/inbox",
    ])

  let pid = start_pool(sys, config.McpConfig(servers: [cfg]))

  wait_for_event_source(sys, "gmail-work") |> should.be_true

  let assert Ok(events) =
    db.search_events(
      sys.db_subject,
      "",
      option.None,
      option.Some("gmail-work"),
      50,
    )
  let assert [stored, ..] = events
  stored.source |> should.equal("gmail-work")
  stored.type_ |> should.equal("resource.updated")
  stored.subject |> should.equal("gmail://work/inbox/42")
  // Full params were serialised as data.
  { stored.data != "" } |> should.be_true

  stop_pool(pid)
  fake.stop(server)
  teardown(sys)
}

/// One server handshake fails; the other reaches Ready normally. The
/// healthy client's notification still lands in the DB. The pool
/// supervisor stays alive throughout — a sibling's crash does not kill
/// the healthy client.
pub fn pool_one_client_crash_does_not_kill_others_test() {
  let sys = fresh_system()

  // Bad server: emits malformed JSON while the client is still in
  // Handshaking. The client stops abnormally; the supervisor will try
  // to restart. Each restart repeats the same failure — but with
  // intensity 10 / 60s we have enough budget for the healthy server to
  // reach Ready and emit its notification before the bad server burns
  // through the budget.
  let #(bad_cfg, bad_server) =
    server_config(
      "bad",
      [
        fake.ExpectRequest("initialize"),
        fake.EmitRaw("not-json"),
        fake.ExpectRequest("__unreachable__"),
      ],
      ["gmail://bad"],
    )

  let #(good_cfg, good_server) =
    server_config("good", healthy_script("gmail://good/inbox"), [
      "gmail://good/inbox",
    ])

  let sup_pid = start_pool(sys, config.McpConfig(servers: [bad_cfg, good_cfg]))

  // Healthy sibling keeps working.
  wait_for_event_source(sys, "good") |> should.be_true

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
