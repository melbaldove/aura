import aura/cognitive_delivery
import aura/db
import aura/external_asks
import aura/time
import gleam/erlang/process.{type Subject}
import gleam/option.{None, Some}
import gleam/json
import gleam/string
import gleeunit/should

/// PostFn / EditFn type aliases are public on the external_asks module; here
/// we only construct concrete functions.

type FakeNet {
  FakeNet(
    posts: Subject(#(String, String, json.Json)),
    edits: Subject(#(String, String, String)),
  )
}

fn fake_net(post_result: Result(String, String)) -> #(
  FakeNet,
  external_asks.PostFn,
  external_asks.EditFn,
) {
  let posts = process.new_subject()
  let edits = process.new_subject()
  let post_fn = fn(channel: String, text: String, buttons: json.Json) {
    process.send(posts, #(channel, text, buttons))
    post_result
  }
  let edit_fn = fn(channel: String, message_id: String, body: String) {
    process.send(edits, #(channel, message_id, body))
    Ok(Nil)
  }
  #(FakeNet(posts: posts, edits: edits), post_fn, edit_fn)
}

fn targets() -> List(cognitive_delivery.DeliveryTarget) {
  [
    cognitive_delivery.default_target("aura-channel"),
    cognitive_delivery.domain_target("cm2", "cm2-channel"),
  ]
}

fn start_asks(
  db_subject: Subject(db.DbMessage),
  post: external_asks.PostFn,
  edit: external_asks.EditFn,
) -> Subject(external_asks.Message) {
  let assert Ok(started) =
    external_asks.start(db_subject, None, targets(), post, edit)
  started.data
}

fn ask(id: String) -> db.StoredExternalAsk {
  db.StoredExternalAsk(
    id: id,
    source: "linkedin",
    channel_id: "default",
    message_id: "",
    text: "Adopt?",
    buttons_json: "[\"Resolved\",\"Abort\"]",
    status: "pending",
    decision: "",
    requested_at_ms: time.now_ms(),
    updated_at_ms: time.now_ms(),
  )
}

fn posted(net: FakeNet) -> #(String, String, json.Json) {
  let assert Ok(p) = process.receive(net.posts, 1000)
  p
}

fn edited(net: FakeNet) -> #(String, String, String) {
  let assert Ok(e) = process.receive(net.edits, 1000)
  e
}

fn no_second_post(net: FakeNet) -> Nil {
  let assert Error(_) = process.receive(net.posts, 100)
  Nil
}

fn stop_subject(subject) -> Nil {
  case process.subject_owner(subject) {
    Ok(pid) -> {
      process.unlink(pid)
      process.kill(pid)
    }
    Error(_) -> Nil
  }
}

pub fn submit_ask_posts_and_resolves_test() {
  let assert Ok(db_subject) = db.start(":memory:")
  let #(net, post, edit) = fake_net(Ok("msg-1"))
  let actor = start_asks(db_subject, post, edit)

  external_asks.get_decision(actor, "precheck") |> should.equal("UNKNOWN")

  let reply = process.new_subject()
  external_asks.submit_ask(actor, ask("c1"), 60_000, reply)

  let #(channel, text, _buttons) = posted(net)
  channel |> should.equal("aura-channel")
  text |> string.contains("Adopt?") |> should.be_true

  let assert Ok(Some(stored)) = db.get_external_ask(db_subject, "c1")
  stored.status |> should.equal("pending")

  external_asks.resolve_ask(actor, "c1", "Resolved")

  let assert Ok(line) = process.receive(reply, 1000)
  line |> should.equal("RESOLVED c1 Resolved")

  let #(_, _, edited_body) = edited(net)
  edited_body |> string.contains("Resolved") |> should.be_true

  let assert Ok(Some(done)) = db.get_external_ask(db_subject, "c1")
  done.status |> should.equal("resolved")
  done.decision |> should.equal("Resolved")

  stop_subject(actor)
  Nil
}

pub fn duplicate_ask_attaches_waiter_without_reposting_test() {
  let assert Ok(db_subject) = db.start(":memory:")
  let #(net, post, edit) = fake_net(Ok("msg1"))
  let actor = start_asks(db_subject, post, edit)

  let reply1 = process.new_subject()
  let reply2 = process.new_subject()
  external_asks.submit_ask(actor, ask("c2"), 60_000, reply1)
  external_asks.submit_ask(actor, ask("c2"), 60_000, reply2)

  let _ = posted(net)
  no_second_post(net)
  external_asks.resolve_ask(actor, "c2", "Resolved")

  let assert Ok(a) = process.receive(reply1, 1000)
  let assert Ok(b) = process.receive(reply2, 1000)
  a |> should.equal("RESOLVED c2 Resolved")
  b |> should.equal("RESOLVED c2 Resolved")

  stop_subject(actor)
  Nil
}

pub fn resolved_ask_replays_decision_immediately_test() {
  let assert Ok(db_subject) = db.start(":memory:")
  let #(net, post, edit) = fake_net(Ok("msg2"))
  let actor = start_asks(db_subject, post, edit)

  let reply1 = process.new_subject()
  external_asks.submit_ask(actor, ask("c3"), 60_000, reply1)
  let _ = posted(net)
  external_asks.resolve_ask(actor, "c3", "Yes")

  let reply2 = process.new_subject()
  external_asks.submit_ask(actor, ask("c3"), 60_000, reply2)

  let assert Ok(line2) = process.receive(reply2, 1000)
  line2 |> should.equal("RESOLVED c3 Yes")

  stop_subject(actor)
  Nil
}

pub fn expire_ask_test() {
  let assert Ok(db_subject) = db.start(":memory:")
  let #(net, post, edit) = fake_net(Ok("post-1"))
  let actor = start_asks(db_subject, post, edit)

  let reply = process.new_subject()
  external_asks.submit_ask(actor, ask("c4"), 1, reply)
  let _ = posted(net)

  let assert Ok(_expired) = process.receive(reply, 1000)

  let assert Ok(Some(stored)) = db.get_external_ask(db_subject, "c4")
  stored.status |> should.equal("expired")

  let #(_, _, edited_body) = edited(net)
  edited_body |> string.contains("Expired") |> should.be_true

  stop_subject(actor)
  Nil
}

pub fn resolve_after_expiry_is_ignored_test() {
  let assert Ok(db_subject) = db.start(":memory:")
  let #(net, post, edit) = fake_net(Ok("post-1"))
  let actor = start_asks(db_subject, post, edit)

  let reply = process.new_subject()
  external_asks.submit_ask(actor, ask("c5"), 1, reply)
  let _ = posted(net)
  let assert Ok(_expired) = process.receive(reply, 1000)

  external_asks.resolve_ask(actor, "c5", "Late")

  let assert Ok(Some(stored)) = db.get_external_ask(db_subject, "c5")
  stored.status |> should.equal("expired")
  stored.decision |> should.equal("")

  let assert Error(_) = process.receive(reply, 100)

  stop_subject(actor)
  Nil
}

pub fn get_decision_states_test() {
  let assert Ok(db_subject) = db.start(":memory:")
  let #(net, post, edit) = fake_net(Ok("post-1"))
  let actor = start_asks(db_subject, post, edit)

  external_asks.get_decision(actor, "nope") |> should.equal("UNKNOWN")

  let reply = process.new_subject()
  external_asks.submit_ask(actor, ask("c6"), 60_000, reply)
  let _ = posted(net)

  external_asks.get_decision(actor, "c6") |> should.equal("PENDING")

  external_asks.resolve_ask(actor, "c6", "Go")
  external_asks.get_decision(actor, "c6") |> should.equal("RESOLVED c6 Go")

  let reply2 = process.new_subject()
  external_asks.submit_ask(actor, ask("c6e"), 1, reply2)
  let _ = posted(net)
  let assert Ok(_expired_line) = process.receive(reply2, 1000)
  external_asks.get_decision(actor, "c6e") |> should.equal("EXPIRED c6e")

  stop_subject(actor)
  Nil
}

pub fn post_failure_marks_failed_and_replies_error_test() {
  let assert Ok(db_subject) = db.start(":memory:")
  let #(net, post, edit) = fake_net(Error("discord 400"))
  let actor = start_asks(db_subject, post, edit)

  let reply = process.new_subject()
  external_asks.submit_ask(actor, ask("c7"), 60_000, reply)

  let assert Ok(line) = process.receive(reply, 1000)
  line |> string.contains("ERROR:") |> should.be_true

  let assert Ok(Some(stored)) = db.get_external_ask(db_subject, "c7")
  stored.status |> should.equal("failed")

  stop_subject(actor)
  Nil
}