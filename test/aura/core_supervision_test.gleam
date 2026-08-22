import aura/core_supervision
import aura/db
import gleam/erlang/process
import gleam/list
import gleam/otp/actor
import gleam/otp/static_supervisor
import gleam/otp/supervision
import gleeunit
import gleeunit/should

pub fn main() {
  gleeunit.main()
}

fn probe_child(
  name: process.Name(Nil),
  label: String,
  started: process.Subject(String),
) -> supervision.ChildSpecification(Nil) {
  supervision.worker(fn() {
    actor.new_with_initialiser(1000, fn(subject) {
      process.send(started, label)
      Ok(actor.initialised(Nil) |> actor.returning(subject))
    })
    |> actor.named(name)
    |> actor.on_message(fn(state, _) { actor.continue(state) })
    |> actor.start
  })
  |> supervision.map_data(fn(_) { Nil })
}

fn receive_labels(started: process.Subject(String), count: Int) -> List(String) {
  case count {
    0 -> []
    _ -> {
      let assert Ok(label) = process.receive(started, 1000)
      [label, ..receive_labels(started, count - 1)]
    }
  }
}

fn start_probed_core(under_root: Bool) {
  let labels = [
    "database",
    "cognitive_delivery",
    "cognitive_worker",
    "event_ingest",
    "external_asks",
    "flare_manager",
    "channel_supervisor",
    "brain",
    "scheduler",
  ]
  let names = list.map(labels, fn(label) { process.new_name(label) })
  let started = process.new_subject()
  let specs =
    list.map2(names, labels, fn(name, label) {
      probe_child(name, label, started)
    })
  let assert [
    database,
    cognitive_delivery,
    cognitive_worker,
    event_ingest,
    external_asks,
    flare_manager,
    channel_supervisor,
    brain,
    scheduler,
  ] = specs

  let children =
    core_supervision.CoreChildren(
      database: database,
      cognitive_delivery: cognitive_delivery,
      cognitive_worker: cognitive_worker,
      event_ingest: event_ingest,
      external_asks: external_asks,
      flare_manager: flare_manager,
      channel_supervisor: channel_supervisor,
      brain: brain,
      scheduler: scheduler,
    )
  let result = case under_root {
    False -> core_supervision.start(children)
    True ->
      static_supervisor.new(static_supervisor.OneForOne)
      |> static_supervisor.auto_shutdown(static_supervisor.AnySignificant)
      |> static_supervisor.add(core_supervision.supervised(children))
      |> static_supervisor.start
  }
  let assert Ok(supervisor) = result
  process.unlink(supervisor.pid)

  receive_labels(started, 9) |> should.equal(labels)

  #(supervisor, names, labels, started)
}

fn verify_role_restart(crash_index: Int) -> Nil {
  let #(supervisor, names, labels, started) = start_probed_core(False)

  let assert [crash_name, ..] = list.drop(names, crash_index)
  let assert Ok(crash_pid) = process.named(crash_name)
  process.kill(crash_pid)

  let assert [expected, ..] = list.drop(labels, crash_index)
  receive_labels(started, 1) |> should.equal([expected])
  process.receive(started, 50) |> should.be_error
  let assert Ok(restarted_pid) = process.named(crash_name)
  let reused_pid = restarted_pid == crash_pid
  reused_pid |> should.be_false
  process.send(process.named_subject(crash_name), Nil)
  process.is_alive(supervisor.pid) |> should.be_true

  process.kill(supervisor.pid)
}

fn verify_explicit_service_failure(crash_index: Int) -> Nil {
  let #(supervisor, names, _, _) = start_probed_core(True)
  let monitor = process.monitor(supervisor.pid)
  let assert [crash_name, ..] = list.drop(names, crash_index)
  let assert Ok(crash_pid) = process.named(crash_name)
  process.kill(crash_pid)

  let assert Ok(_) =
    process.selector_receive(
      process.new_selector()
        |> process.select_specific_monitor(monitor, fn(down) { down }),
      1000,
    )
  Nil
}

pub fn real_named_database_recovers_after_forced_crash_test() {
  let db_name = process.new_name("real-database")
  let started = process.new_subject()
  let labels = [
    "cognitive_delivery",
    "cognitive_worker",
    "event_ingest",
    "external_asks",
    "flare_manager",
    "channel_supervisor",
    "brain",
    "scheduler",
  ]
  let names = list.map(labels, fn(label) { process.new_name(label) })
  let specs =
    list.map2(names, labels, fn(name, label) {
      probe_child(name, label, started)
    })
  let assert [
    cognitive_delivery,
    cognitive_worker,
    event_ingest,
    external_asks,
    flare_manager,
    channel_supervisor,
    brain,
    scheduler,
  ] = specs
  let database =
    supervision.worker(fn() { db.start_named(":memory:", db_name) })
    |> supervision.map_data(fn(_) { Nil })
  let children =
    core_supervision.CoreChildren(
      database: database,
      cognitive_delivery: cognitive_delivery,
      cognitive_worker: cognitive_worker,
      event_ingest: event_ingest,
      external_asks: external_asks,
      flare_manager: flare_manager,
      channel_supervisor: channel_supervisor,
      brain: brain,
      scheduler: scheduler,
    )
  let assert Ok(supervisor) = core_supervision.start(children)
  process.unlink(supervisor.pid)
  let _ = receive_labels(started, 8)
  let assert Ok(first_pid) = process.named(db_name)
  process.kill(first_pid)
  process.sleep(50)
  let assert Ok(second_pid) = process.named(db_name)
  let reused_pid = second_pid == first_pid
  reused_pid |> should.be_false
  db.has_messages(process.named_subject(db_name)) |> should.equal(Ok(False))
  process.kill(supervisor.pid)
}

pub fn database_crash_restarts_database_only_test() {
  verify_role_restart(0)
}

pub fn cognitive_delivery_crash_restarts_delivery_only_test() {
  verify_role_restart(1)
}

pub fn cognitive_worker_crash_restarts_worker_only_test() {
  verify_role_restart(2)
}

pub fn event_ingest_crash_restarts_ingest_only_test() {
  verify_role_restart(3)
}

pub fn external_asks_crash_causes_explicit_service_failure_test() {
  verify_explicit_service_failure(4)
}

pub fn flare_manager_crash_causes_explicit_service_failure_test() {
  verify_explicit_service_failure(5)
}

pub fn channel_supervisor_crash_causes_explicit_service_failure_test() {
  verify_explicit_service_failure(6)
}

pub fn brain_crash_restarts_brain_only_test() {
  verify_role_restart(7)
}

pub fn scheduler_crash_causes_explicit_service_failure_test() {
  verify_explicit_service_failure(8)
}
