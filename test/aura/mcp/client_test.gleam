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
  client.ClientConfig(
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

pub fn client_handles_subprocess_exit_test() {
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
      // Script ends here — the escript exits 0 immediately after emitting,
      // which drives the client's McpExit path.
    ])
  let observer = process.new_subject()
  let subject =
    start_unlinked(make_config(server, "inbox", ["gmail://inbox"], observer))
  let monitor = monitor_subject(subject)
  await_down(monitor, 3000) |> should.be_true
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
