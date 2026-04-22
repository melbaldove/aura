import aura/mcp/client
import fakes/fake_mcp_server as fake
import gleam/erlang/process.{type Subject}
import gleam/json
import gleam/string
import gleeunit
import gleeunit/should
import poll

pub fn main() {
  gleeunit.main()
}

// ---------------------------------------------------------------------------
// Test helpers
// ---------------------------------------------------------------------------

/// Message sent by a test callback so the test process can observe what
/// the client forwarded.
type Observation {
  NotifSeen(method: String, params_json: String)
}

/// Build a config and an observer subject. The `on_notification` callback
/// serialises the params back to a JSON string and sends `NotifSeen` to the
/// subject so the test can assert on the payload without juggling `json.Json`
/// directly.
fn make_config(
  server: fake.FakeMcpServer,
  name: String,
  subscribe: List(String),
  observer: Subject(Observation),
) -> client.ClientConfig {
  client.new_config(
    name: name,
    command: fake.command(server),
    args: fake.args(server),
    env: [],
    subscribe: subscribe,
    on_notification: fn(method, params) {
      process.send(
        observer,
        NotifSeen(method: method, params_json: json.to_string(params)),
      )
    },
  )
}

/// Same as `make_config` but with a custom handshake deadline — used by the
/// deadline test so we don't hold the suite for 30s.
fn make_config_with_deadline(
  server: fake.FakeMcpServer,
  name: String,
  subscribe: List(String),
  observer: Subject(Observation),
  deadline_ms: Int,
) -> client.ClientConfig {
  let base = make_config(server, name, subscribe, observer)
  client.ClientConfig(..base, handshake_timeout_ms: deadline_ms)
}

/// Start a client and unlink the actor from the test process. Required
/// whenever the test expects the actor to stop abnormally: `actor.start`
/// links to the caller, and an abnormal exit propagates EXIT, killing the
/// test. We unlink immediately so the test can observe death via a
/// monitor instead.
fn start_unlinked(config: client.ClientConfig) -> Subject(client.ClientMessage) {
  let assert Ok(started) = client.start(config)
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

pub fn client_handshakes_and_subscribes_test() {
  let server =
    fake.start([
      fake.ExpectRequest("initialize"),
      fake.RespondResult(fake.initialize_result_json()),
      fake.ExpectNotification("notifications/initialized"),
      fake.ExpectRequest("resources/subscribe"),
      fake.RespondResult(fake.subscribe_ok_json()),
      // Emit a notification so the test can observe we've reached Ready.
      fake.EmitNotification(
        "notifications/resources/updated",
        "{\"uri\":\"gmail://inbox\"}",
      ),
      fake.ExpectRequest("__never__"),
    ])
  let observer = process.new_subject()
  let subject =
    start_unlinked(make_config(server, "inbox", ["gmail://inbox"], observer))

  // Wait for the Ready transition — observable through the notification.
  let saw_it =
    poll.poll_until(
      fn() {
        case process.receive(observer, 10) {
          Ok(NotifSeen(method: "notifications/resources/updated", params_json: _)) ->
            True
          _ -> False
        }
      },
      3000,
    )
  saw_it |> should.be_true

  client.stop(subject)
  fake.stop(server)
}

pub fn client_forwards_resource_updated_notification_test() {
  let server =
    fake.start([
      fake.ExpectRequest("initialize"),
      fake.RespondResult(fake.initialize_result_json()),
      fake.ExpectNotification("notifications/initialized"),
      fake.ExpectRequest("resources/subscribe"),
      fake.RespondResult(fake.subscribe_ok_json()),
      fake.EmitNotification(
        "notifications/resources/updated",
        "{\"uri\":\"gmail://inbox\",\"title\":\"new message\"}",
      ),
      fake.ExpectRequest("__never__"),
    ])
  let observer = process.new_subject()
  let subject =
    start_unlinked(make_config(server, "inbox", ["gmail://inbox"], observer))

  let got =
    poll.poll_until(
      fn() {
        case process.receive(observer, 10) {
          Ok(NotifSeen(method: "notifications/resources/updated", params_json: p)) ->
            string.contains(p, "gmail://inbox")
            && string.contains(p, "new message")
          _ -> False
        }
      },
      3000,
    )
  got |> should.be_true

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
  let observer = process.new_subject()
  let subject =
    start_unlinked(make_config(server, "inbox", ["gmail://inbox"], observer))
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
      fake.ExpectRequest("resources/subscribe"),
      fake.RespondResult(fake.subscribe_ok_json()),
      fake.EmitNotification(
        "notifications/resources/updated",
        "{\"uri\":\"gmail://inbox\"}",
      ),
      // Script ends — escript exits 0. Clean exit from Ready ≠ crash.
    ])
  let observer = process.new_subject()
  let subject =
    start_unlinked(make_config(server, "inbox", ["gmail://inbox"], observer))
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
      fake.ExpectRequest("resources/subscribe"),
      fake.RespondResult(fake.subscribe_ok_json()),
      fake.EmitNotification(
        "notifications/resources/updated",
        "{\"uri\":\"gmail://inbox\"}",
      ),
      fake.ExitWithCode(42),
    ])
  let observer = process.new_subject()
  let subject =
    start_unlinked(make_config(server, "inbox", ["gmail://inbox"], observer))
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
  let observer = process.new_subject()
  let subject =
    start_unlinked(make_config(server, "inbox", ["gmail://inbox"], observer))
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
  let observer = process.new_subject()
  let subject =
    start_unlinked(make_config_with_deadline(
      server,
      "inbox",
      ["gmail://inbox"],
      observer,
      100,
    ))
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
