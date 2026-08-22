//// Persisted connector activation and read-worker runtime.
////
//// The runtime starts no worker unless SQLite returns an effective activation
//// that exactly matches local configuration. Each activation has at most one
//// worker. Provider credentials stay inside the connector-specific runner.

import aura/config
import aura/db
import aura/event_ingest
import aura/google_calendar_runtime
import aura/google_gmail_runtime
import aura/operating_contracts
import aura/time
import aura/xdg
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Down, type Monitor}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/otp/supervision
import gleam/result
import gleam/string
import logging

const reconciliation_interval_ms = 60_000

type RunActivation =
  fn(String, String, String, String, String) -> Result(RunReceipt, String)

/// One compact connector-neutral read receipt.
pub type RunReceipt {
  RunReceipt(connector_id: String, attempt_id: String, evidence_count: Int)
}

type RunningRead {
  RunningRead(monitor: Monitor)
}

/// Messages accepted by the connector runtime.
pub type Message {
  Tick
  RunOnce(
    authorization_id: String,
    activation_id: String,
    reply_to: process.Subject(Result(RunReceipt, String)),
  )
  ReadFinished(
    activation_id: String,
    result: Result(RunReceipt, String),
    reply_to: Option(process.Subject(Result(RunReceipt, String))),
  )
  ReadWorkerDown(Down)
}

type State {
  State(
    db_subject: process.Subject(db.DbMessage),
    configurations: List(config.ConnectorConfiguration),
    self_subject: process.Subject(Message),
    runner: Option(RunActivation),
    running: Dict(String, RunningRead),
  )
}

/// The accepted persisted activation set for one local runtime start.
pub opaque type Runtime {
  Runtime(activations: List(operating_contracts.ConnectorActivationV1))
}

/// Load enabled, non-expired persisted activations that exactly match config.
///
/// No configuration can start a connector without a database activation.
pub fn load(
  db_subject: process.Subject(db.DbMessage),
  configurations: List(config.ConnectorConfiguration),
) -> Result(Runtime, String) {
  use _ <- result.try(db.recover_expired_connector_reads(db_subject))
  use activations <- result.try(db.list_effective_connector_activations(
    db_subject,
  ))
  use _ <- result.try(
    list.try_each(activations, fn(activation) {
      use configuration <- result.try(
        list.find(configurations, fn(configuration) {
          configuration.configuration_ref == activation.configuration_ref
        })
        |> result.map_error(fn(_) { "activation_configuration_not_found" }),
      )
      case
        configuration.connector_id == activation.connector_id
        && configuration.oauth_scope == activation.oauth_scope
      {
        True -> Ok(Nil)
        False -> Error("activation_configuration_mismatch")
      }
    }),
  )
  Ok(Runtime(activations:))
}

/// Return loaded activation IDs. An empty list means no provider worker starts.
pub fn activation_ids(runtime: Runtime) -> List(String) {
  let Runtime(activations:) = runtime
  activations |> list.map(fn(activation) { activation.activation_id })
}

/// Start the reconciliation-only runtime used by local activation tests.
pub fn start_named(
  name: process.Name(Message),
  db_subject: process.Subject(db.DbMessage),
  configurations: List(config.ConnectorConfiguration),
) -> Result(actor.Started(process.Subject(Message)), actor.StartError) {
  start_named_with_runner(name, db_subject, configurations, None)
}

/// Start the production runtime with credential-hidden Google readers.
pub fn start_named_with_google(
  name: process.Name(Message),
  db_subject: process.Subject(db.DbMessage),
  ingest_subject: process.Subject(event_ingest.IngestMessage),
  paths: xdg.Paths,
  configurations: List(config.ConnectorConfiguration),
) -> Result(actor.Started(process.Subject(Message)), actor.StartError) {
  let runner = fn(
    connector_id,
    authorization_id,
    activation_id,
    attempt_id,
    worker_id,
  ) {
    case connector_id {
      "gmail" ->
        google_gmail_runtime.run_once(
          db_subject,
          ingest_subject,
          paths,
          configurations,
          authorization_id,
          activation_id,
          attempt_id,
          worker_id,
        )
        |> result.map(fn(receipt) {
          RunReceipt("gmail", receipt.attempt_id, receipt.evidence_count)
        })
      "calendar" ->
        google_calendar_runtime.run_once(
          db_subject,
          ingest_subject,
          paths,
          configurations,
          authorization_id,
          activation_id,
          attempt_id,
          worker_id,
        )
        |> result.map(fn(receipt) {
          RunReceipt("calendar", receipt.attempt_id, receipt.evidence_count)
        })
      _ -> Error("connector_runner_unavailable")
    }
  }
  start_named_with_runner(name, db_subject, configurations, Some(runner))
}

/// Start a credential-free runtime runner for actor tests.
pub fn start_named_with_runner_for_test(
  name: process.Name(Message),
  db_subject: process.Subject(db.DbMessage),
  configurations: List(config.ConnectorConfiguration),
  runner: fn(String, String, String, String, String) ->
    Result(RunReceipt, String),
) -> Result(actor.Started(process.Subject(Message)), actor.StartError) {
  start_named_with_runner(name, db_subject, configurations, Some(runner))
}

fn start_named_with_runner(
  name: process.Name(Message),
  db_subject: process.Subject(db.DbMessage),
  configurations: List(config.ConnectorConfiguration),
  runner: Option(RunActivation),
) -> Result(actor.Started(process.Subject(Message)), actor.StartError) {
  actor.new_with_initialiser(5000, fn(self_subject) {
    reconcile(db_subject, configurations)
    process.send(self_subject, Tick)
    let selector =
      process.new_selector()
      |> process.select(self_subject)
      |> process.select_monitors(ReadWorkerDown)
    Ok(
      actor.initialised(State(
        db_subject:,
        configurations:,
        self_subject:,
        runner:,
        running: dict.new(),
      ))
      |> actor.selecting(selector)
      |> actor.returning(self_subject),
    )
  })
  |> actor.on_message(handle_message)
  |> actor.named(name)
  |> actor.start
}

/// Ask the runtime to run one exact activation through its configured runner.
pub fn run_once(
  subject: process.Subject(Message),
  authorization_id: String,
  activation_id: String,
) -> Result(RunReceipt, String) {
  process.call(subject, 310_000, fn(reply_to) {
    RunOnce(authorization_id:, activation_id:, reply_to:)
  })
}

/// Build the reconciliation-only supervised runtime child.
pub fn supervised(
  name: process.Name(Message),
  db_subject: process.Subject(db.DbMessage),
  configurations: List(config.ConnectorConfiguration),
) -> supervision.ChildSpecification(Nil) {
  supervision.worker(fn() { start_named(name, db_subject, configurations) })
  |> supervision.map_data(fn(_) { Nil })
}

/// Build the production supervised runtime child.
pub fn supervised_with_google(
  name: process.Name(Message),
  db_subject: process.Subject(db.DbMessage),
  ingest_subject: process.Subject(event_ingest.IngestMessage),
  paths: xdg.Paths,
  configurations: List(config.ConnectorConfiguration),
) -> supervision.ChildSpecification(Nil) {
  supervision.worker(fn() {
    start_named_with_google(
      name,
      db_subject,
      ingest_subject,
      paths,
      configurations,
    )
  })
  |> supervision.map_data(fn(_) { Nil })
}

fn handle_message(state: State, message: Message) -> actor.Next(State, Message) {
  case message {
    Tick -> {
      let next = start_due_reads(state)
      process.send_after(state.self_subject, reconciliation_interval_ms, Tick)
      actor.continue(next)
    }
    RunOnce(authorization_id:, activation_id:, reply_to:) ->
      case effective_activation(state, authorization_id, activation_id) {
        Error(error) -> {
          process.send(reply_to, Error(error))
          actor.continue(state)
        }
        Ok(activation) ->
          actor.continue(start_read(
            state,
            activation.connector_id,
            authorization_id,
            activation_id,
            Some(reply_to),
          ))
      }
    ReadFinished(activation_id:, result:, reply_to:) -> {
      let next = clear_running(state, activation_id)
      case reply_to {
        Some(reply) -> process.send(reply, result)
        None -> log_result(activation_id, result)
      }
      actor.continue(next)
    }
    ReadWorkerDown(down) -> actor.continue(clear_down_worker(state, down))
  }
}

fn start_due_reads(state: State) -> State {
  case load(state.db_subject, state.configurations) {
    Error(error) -> {
      logging.log(
        logging.Error,
        "[connector_runtime] Disabled connector execution: " <> error,
      )
      state
    }
    Ok(Runtime(activations:)) ->
      list.fold(activations, state, fn(next, activation) {
        case
          list.contains(["gmail", "calendar"], activation.connector_id)
          && !dict.has_key(next.running, activation.activation_id)
          && activation_due(next.db_subject, activation)
        {
          True ->
            start_read(
              next,
              activation.connector_id,
              activation.authorization_id,
              activation.activation_id,
              None,
            )
          False -> next
        }
      })
  }
}

fn activation_due(
  db_subject: process.Subject(db.DbMessage),
  activation: operating_contracts.ConnectorActivationV1,
) -> Bool {
  case
    db.get_connector_checkpoint(
      db_subject,
      activation.configuration_ref,
      activation.activation_id,
    )
  {
    Ok(None) -> True
    Ok(Some(checkpoint)) ->
      checkpoint.gap_code == "" && checkpoint.next_due_at_ms <= time.now_ms()
    Error(error) -> {
      logging.log(
        logging.Error,
        "[connector_runtime] Failed to inspect checkpoint: " <> error,
      )
      False
    }
  }
}

fn start_read(
  state: State,
  connector_id: String,
  authorization_id: String,
  activation_id: String,
  reply_to: Option(process.Subject(Result(RunReceipt, String))),
) -> State {
  case state.runner {
    None -> {
      case reply_to {
        Some(reply) ->
          process.send(reply, Error("connector_runner_unavailable"))
        None -> Nil
      }
      state
    }
    Some(runner) ->
      case dict.has_key(state.running, activation_id) {
        True -> {
          case reply_to {
            Some(reply) ->
              process.send(reply, Error("connector_read_in_progress"))
            None -> Nil
          }
          state
        }
        False -> {
          let now_ms = time.now_ms()
          let attempt_id =
            "attempt:"
            <> connector_id
            <> ":"
            <> activation_id
            <> ":"
            <> int.to_string(now_ms)
          let worker_id =
            "worker:connector-runtime:" <> connector_id <> ":" <> activation_id
          let owner = state.self_subject
          let pid =
            process.spawn_unlinked(fn() {
              let result =
                runner(
                  connector_id,
                  authorization_id,
                  activation_id,
                  attempt_id,
                  worker_id,
                )
              process.send(
                owner,
                ReadFinished(activation_id:, result:, reply_to:),
              )
            })
          let monitor = process.monitor(pid)
          State(
            ..state,
            running: dict.insert(
              state.running,
              activation_id,
              RunningRead(monitor:),
            ),
          )
        }
      }
  }
}

fn effective_activation(
  state: State,
  authorization_id: String,
  activation_id: String,
) -> Result(operating_contracts.ConnectorActivationV1, String) {
  use runtime <- result.try(load(state.db_subject, state.configurations))
  let Runtime(activations:) = runtime
  activations
  |> list.find(fn(value) {
    value.activation_id == activation_id
    && value.authorization_id == authorization_id
    && list.contains(["gmail", "calendar"], value.connector_id)
  })
  |> result.map_error(fn(_) { "connector_activation_not_effective" })
}

fn clear_running(state: State, activation_id: String) -> State {
  case dict.get(state.running, activation_id) {
    Ok(RunningRead(monitor:)) -> {
      process.demonitor_process(monitor)
      State(..state, running: dict.delete(state.running, activation_id))
    }
    Error(Nil) -> state
  }
}

fn clear_down_worker(state: State, down: Down) -> State {
  case down {
    process.ProcessDown(monitor:, reason:, ..) ->
      case
        dict.to_list(state.running)
        |> list.find(fn(entry) {
          let #(_, RunningRead(monitor: candidate)) = entry
          candidate == monitor
        })
      {
        Ok(#(activation_id, _)) -> {
          logging.log(
            logging.Error,
            "[connector_runtime] Connector worker stopped for "
              <> activation_id
              <> ": "
              <> string.inspect(reason),
          )
          State(..state, running: dict.delete(state.running, activation_id))
        }
        Error(Nil) -> state
      }
    process.PortDown(..) -> state
  }
}

fn log_result(activation_id: String, result: Result(RunReceipt, String)) -> Nil {
  case result {
    Ok(_) -> Nil
    Error(error) ->
      logging.log(
        logging.Error,
        "[connector_runtime] Connector read failed for "
          <> activation_id
          <> ": "
          <> error,
      )
  }
}

fn reconcile(
  db_subject: process.Subject(db.DbMessage),
  configurations: List(config.ConnectorConfiguration),
) -> Nil {
  case load(db_subject, configurations) {
    Ok(_) -> Nil
    Error(error) ->
      logging.log(
        logging.Error,
        "[connector_runtime] Disabled local activation runtime: " <> error,
      )
  }
}
