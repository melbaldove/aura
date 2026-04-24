import aura/acp/client
import aura/acp/monitor as acp_monitor
import aura/acp/provider
import aura/acp/tmux
import aura/acp/transport
import aura/acp/types
import aura/db
import aura/time
import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import gleam/string
import logging

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

pub type FlareStatus {
  Active
  Parked
  Archived
  Failed(reason: String)
}

/// Policy decision for the flare(prompt) tool. Pure — no I/O.
pub type PromptAction {
  SendToLive(session_name: String)
  RekindleFlare(flare_id: String, prompt: String)
  RejectPrompt(reason: String)
}

pub type FlareExecution {
  FlareExecution(
    provider: String,
    binary: String,
    worktree: Bool,
    timeout_ms: Int,
    transport: FlareTransport,
  )
}

/// Persisted transport metadata for recovering and controlling a flare with the
/// same transport that created it.
pub type FlareTransport {
  LegacyTransport
  HttpTransport(server_url: String, agent_name: String)
  StdioTransport(command: String)
  TmuxTransport
}

/// A resolved transport plus the handle required to control a live session.
pub type ControlSession {
  ControlSession(
    transport: transport.Transport,
    handle: transport.SessionHandle,
  )
}

/// Decide what `prompt` should do given the flare's current state.
/// Active → send to the live session. Parked → auto-rekindle (flares are
/// long-running; a parked flare is the expected post-handback state).
/// Failed/Archived → reject; user must explicitly rekindle or ignite.
pub fn resolve_prompt_action(
  status: FlareStatus,
  flare_id: String,
  session_name: String,
  prompt: String,
) -> PromptAction {
  case status {
    Active -> SendToLive(session_name)
    Parked -> RekindleFlare(flare_id, prompt)
    Failed(reason) ->
      RejectPrompt(
        "Flare "
        <> flare_id
        <> " is failed ("
        <> reason
        <> ") — rekindle explicitly to resume, or ignite a new flare",
      )
    Archived ->
      RejectPrompt(
        "Flare " <> flare_id <> " is archived — ignite a new flare instead",
      )
  }
}

pub type FlareRecord {
  FlareRecord(
    id: String,
    label: String,
    status: FlareStatus,
    domain: String,
    thread_id: String,
    original_prompt: String,
    execution_json: String,
    triggers_json: String,
    tools_json: String,
    workspace: String,
    session_id: String,
    session_name: String,
    handle: Option(transport.SessionHandle),
    started_at_ms: Int,
    updated_at_ms: Int,
    awaiting_response: Bool,
  )
}

pub type FlareMsg {
  // Flare identity operations
  Ignite(
    reply_to: process.Subject(Result(String, String)),
    label: String,
    domain: String,
    thread_id: String,
    prompt: String,
    execution_json: String,
    triggers_json: String,
    tools_json: String,
    workspace: String,
  )
  Archive(reply_to: process.Subject(Result(Nil, String)), flare_id: String)
  GetFlare(
    reply_to: process.Subject(Result(FlareRecord, Nil)),
    flare_id: String,
  )
  GetFlareByLabel(
    reply_to: process.Subject(Result(FlareRecord, Nil)),
    label: String,
  )
  GetFlareBySessionName(
    reply_to: process.Subject(Result(FlareRecord, Nil)),
    session_name: String,
  )
  ListFlares(reply_to: process.Subject(List(FlareRecord)))

  // Session operations (same interface as acp_manager)
  Dispatch(
    reply_to: process.Subject(Result(String, String)),
    task_spec: types.TaskSpec,
    thread_id: String,
    flare_id: String,
  )
  Kill(reply_to: process.Subject(Result(Nil, String)), session_name: String)
  SendInput(
    reply_to: process.Subject(Result(Nil, String)),
    session_name: String,
    input: String,
  )
  GetSession(
    reply_to: process.Subject(Result(FlareRecord, Nil)),
    session_name: String,
  )
  ListSessions(reply_to: process.Subject(List(FlareRecord)))

  // Lifecycle operations
  Park(
    reply_to: process.Subject(Result(Nil, String)),
    flare_id: String,
    triggers_json: String,
  )
  Rekindle(
    reply_to: process.Subject(Result(String, String)),
    flare_id: String,
    input: String,
  )

  // Events
  MonitorEvent(acp_monitor.AcpEvent)
  SetBrainCallback(on_brain_event: fn(acp_monitor.AcpEvent) -> Nil)

  // Query
  ListParkedWithTriggers(reply_to: process.Subject(List(FlareRecord)))

  // Test-only
  RegisterForTest(flare: FlareRecord, reply_to: process.Subject(Nil))
}

type FlareManagerState {
  FlareManagerState(
    flares: Dict(String, FlareRecord),
    session_to_flare: Dict(String, String),
    max_concurrent: Int,
    db_subject: process.Subject(db.DbMessage),
    monitor_model: String,
    on_brain_event: fn(acp_monitor.AcpEvent) -> Nil,
    self_subject: process.Subject(FlareMsg),
    transport: transport.Transport,
  )
}

// ---------------------------------------------------------------------------
// Status conversion (pure functions)
// ---------------------------------------------------------------------------

pub fn status_to_string(status: FlareStatus) -> String {
  case status {
    Active -> "active"
    Parked -> "parked"
    Archived -> "archived"
    Failed(reason) -> "failed:" <> reason
  }
}

pub fn status_from_string(s: String) -> FlareStatus {
  case s {
    "active" -> Active
    "parked" -> Parked
    "archived" -> Archived
    _ ->
      case string.starts_with(s, "failed:") {
        True -> Failed(string.drop_start(s, 7))
        False -> Failed(s)
      }
  }
}

const default_timeout_ms = 1_800_000

/// Default execution envelope for legacy flares that predate persisted
/// execution settings.
pub fn default_execution() -> FlareExecution {
  FlareExecution(
    provider: "claude-code",
    binary: "",
    worktree: True,
    timeout_ms: default_timeout_ms,
    transport: LegacyTransport,
  )
}

/// Serialize a flare execution envelope for persistence.
pub fn execution_to_json(execution: FlareExecution) -> String {
  json.object([
    #("provider", json.string(execution.provider)),
    #("binary", json.string(execution.binary)),
    #("worktree", json.bool(execution.worktree)),
    #("timeout_ms", json.int(execution.timeout_ms)),
    #("transport", flare_transport_to_json(execution.transport)),
  ])
  |> json.to_string
}

/// Parse a persisted execution envelope. Empty and `{}` payloads are legacy
/// flares and use defaults; malformed non-empty payloads are explicit errors.
pub fn execution_from_json(raw: String) -> Result(FlareExecution, String) {
  let defaults = default_execution()
  let decoder = {
    use provider <- decode.optional_field(
      "provider",
      defaults.provider,
      decode.string,
    )
    use binary <- decode.optional_field(
      "binary",
      defaults.binary,
      decode.string,
    )
    use worktree <- decode.optional_field(
      "worktree",
      defaults.worktree,
      decode.bool,
    )
    use timeout_ms <- decode.optional_field(
      "timeout_ms",
      defaults.timeout_ms,
      decode.int,
    )
    use transport_spec <- decode.optional_field(
      "transport",
      defaults.transport,
      flare_transport_decoder(),
    )
    decode.success(FlareExecution(
      provider: provider,
      binary: binary,
      worktree: worktree,
      timeout_ms: timeout_ms,
      transport: transport_spec,
    ))
  }

  case string.trim(raw) {
    "" | "{}" -> Ok(defaults)
    _ ->
      case json.parse(raw, decoder) {
        Ok(execution) -> Ok(execution)
        Error(err) ->
          Error("invalid flare execution JSON: " <> string.inspect(err))
      }
  }
}

/// Return a copy of a persisted execution envelope tagged with the transport
/// that actually dispatched the session.
pub fn execution_with_transport_json(
  raw: String,
  acp_transport: transport.Transport,
) -> Result(String, String) {
  use execution <- result.try(execution_from_json(raw))
  FlareExecution(
    ..execution,
    transport: transport_to_flare_transport(acp_transport),
  )
  |> execution_to_json
  |> Ok
}

/// Rebuild the execution task spec used when a parked flare is rekindled.
/// The execution envelope is persisted on ignite so restart + rekindle
/// preserve provider, binary, worktree, and timeout semantics.
pub fn task_spec_for_rekindle(
  flare: FlareRecord,
  input: String,
) -> Result(types.TaskSpec, String) {
  use execution <- result.try(execution_from_json(flare.execution_json))
  let cwd = case flare.workspace {
    "" -> "."
    ws -> ws
  }
  Ok(types.TaskSpec(
    id: flare.id,
    domain: flare.domain,
    prompt: input,
    cwd: cwd,
    timeout_ms: execution.timeout_ms,
    acceptance_criteria: [],
    provider: provider.parse_provider(execution.provider, execution.binary),
    worktree: execution.worktree,
  ))
}

/// Resolve the control session for a flare. Reuses the live in-memory handle
/// when present, otherwise reconstructs the handle from persisted flare state.
pub fn control_session_for_flare(
  current_transport: transport.Transport,
  flare: FlareRecord,
) -> Result(ControlSession, String) {
  use acp_transport <- result.try(transport_for_flare(current_transport, flare))
  use handle <- result.try(case flare.handle {
    Some(handle) -> validate_handle_for_transport(acp_transport, handle)
    None -> recover_session_handle(acp_transport, flare.session_id)
  })
  Ok(ControlSession(transport: acp_transport, handle: handle))
}

/// Resolve only the control handle for tests and legacy callers.
pub fn control_handle_for_flare(
  current_transport: transport.Transport,
  flare: FlareRecord,
) -> Result(transport.SessionHandle, String) {
  control_session_for_flare(current_transport, flare)
  |> result.map(fn(control) { control.handle })
}

fn flare_transport_to_json(spec: FlareTransport) -> json.Json {
  case spec {
    LegacyTransport -> json.object([#("kind", json.string("legacy"))])
    HttpTransport(server_url, agent_name) ->
      json.object([
        #("kind", json.string("http")),
        #("server_url", json.string(server_url)),
        #("agent_name", json.string(agent_name)),
      ])
    StdioTransport(command) ->
      json.object([
        #("kind", json.string("stdio")),
        #("command", json.string(command)),
      ])
    TmuxTransport -> json.object([#("kind", json.string("tmux"))])
  }
}

fn flare_transport_decoder() -> decode.Decoder(FlareTransport) {
  let payload_decoder = {
    use kind <- decode.field("kind", decode.string)
    use server_url <- decode.optional_field("server_url", "", decode.string)
    use agent_name <- decode.optional_field("agent_name", "", decode.string)
    use command <- decode.optional_field("command", "", decode.string)
    decode.success(#(kind, server_url, agent_name, command))
  }

  decode.then(payload_decoder, fn(payload) {
    case payload {
      #("legacy", _, _, _) -> decode.success(LegacyTransport)
      #("http", server_url, agent_name, _) if server_url != "" ->
        decode.success(HttpTransport(
          server_url: server_url,
          agent_name: agent_name,
        ))
      #("stdio", _, _, command) if command != "" ->
        decode.success(StdioTransport(command: command))
      #("tmux", _, _, _) -> decode.success(TmuxTransport)
      _ -> decode.failure(LegacyTransport, expected: "valid flare transport")
    }
  })
}

fn transport_to_flare_transport(
  acp_transport: transport.Transport,
) -> FlareTransport {
  case acp_transport {
    transport.Http(server_url, agent_name) ->
      HttpTransport(server_url: server_url, agent_name: agent_name)
    transport.Stdio(command) -> StdioTransport(command: command)
    transport.Tmux -> TmuxTransport
  }
}

fn transport_for_flare(
  current_transport: transport.Transport,
  flare: FlareRecord,
) -> Result(transport.Transport, String) {
  use execution <- result.try(execution_from_json(flare.execution_json))
  transport_for_spec(execution.transport, current_transport)
}

fn transport_for_stored_flare(
  current_transport: transport.Transport,
  stored: db.StoredFlare,
) -> Result(transport.Transport, String) {
  use execution <- result.try(execution_from_json(stored.execution))
  transport_for_spec(execution.transport, current_transport)
}

fn transport_for_spec(
  spec: FlareTransport,
  current_transport: transport.Transport,
) -> Result(transport.Transport, String) {
  case spec {
    LegacyTransport -> Ok(current_transport)
    HttpTransport(server_url, agent_name) ->
      Ok(transport.Http(server_url: server_url, agent_name: agent_name))
    StdioTransport(command) -> Ok(transport.Stdio(command: command))
    TmuxTransport -> Ok(transport.Tmux)
  }
}

fn validate_handle_for_transport(
  acp_transport: transport.Transport,
  handle: transport.SessionHandle,
) -> Result(transport.SessionHandle, String) {
  case acp_transport, handle {
    transport.Http(_, _), transport.HttpHandle(_) -> Ok(handle)
    transport.Stdio(_), transport.StdioHandle(_, _, _) -> Ok(handle)
    transport.Tmux, transport.TmuxHandle -> Ok(handle)
    _, _ -> Error("Transport/handle mismatch")
  }
}

fn recover_session_handle(
  transport_kind: transport.Transport,
  session_id: String,
) -> Result(transport.SessionHandle, String) {
  case transport_kind {
    transport.Http(_, _) ->
      case session_id {
        "" -> Error("HTTP flare is missing run_id")
        run_id -> Ok(transport.HttpHandle(run_id: run_id))
      }
    transport.Stdio(_) ->
      Error("stdio session handles cannot be recovered after restart")
    transport.Tmux -> Ok(transport.TmuxHandle)
  }
}

// ---------------------------------------------------------------------------
// Public API (convenience wrappers around process.call)
// ---------------------------------------------------------------------------

pub fn ignite(
  subject: process.Subject(FlareMsg),
  label: String,
  domain: String,
  thread_id: String,
  prompt: String,
  execution_json: String,
  triggers_json: String,
  tools_json: String,
  workspace: String,
) -> Result(String, String) {
  process.call(subject, 10_000, fn(reply_to) {
    Ignite(
      reply_to: reply_to,
      label: label,
      domain: domain,
      thread_id: thread_id,
      prompt: prompt,
      execution_json: execution_json,
      triggers_json: triggers_json,
      tools_json: tools_json,
      workspace: workspace,
    )
  })
}

pub fn archive(
  subject: process.Subject(FlareMsg),
  flare_id: String,
) -> Result(Nil, String) {
  process.call(subject, 5000, fn(reply_to) {
    Archive(reply_to: reply_to, flare_id: flare_id)
  })
}

pub fn dispatch(
  subject: process.Subject(FlareMsg),
  task_spec: types.TaskSpec,
  thread_id: String,
  flare_id: String,
) -> Result(String, String) {
  process.call(subject, 30_000, fn(reply_to) {
    Dispatch(
      reply_to: reply_to,
      task_spec: task_spec,
      thread_id: thread_id,
      flare_id: flare_id,
    )
  })
}

pub fn kill(
  subject: process.Subject(FlareMsg),
  session_name: String,
) -> Result(Nil, String) {
  process.call(subject, 10_000, fn(reply_to) {
    Kill(reply_to: reply_to, session_name: session_name)
  })
}

pub fn send_input(
  subject: process.Subject(FlareMsg),
  session_name: String,
  input: String,
) -> Result(Nil, String) {
  process.call(subject, 10_000, fn(reply_to) {
    SendInput(reply_to: reply_to, session_name: session_name, input: input)
  })
}

pub fn get_session(
  subject: process.Subject(FlareMsg),
  session_name: String,
) -> Result(FlareRecord, Nil) {
  process.call(subject, 5000, fn(reply_to) {
    GetSession(reply_to: reply_to, session_name: session_name)
  })
}

pub fn list_sessions(subject: process.Subject(FlareMsg)) -> List(FlareRecord) {
  process.call(subject, 5000, fn(reply_to) { ListSessions(reply_to: reply_to) })
}

pub fn get_flare(
  subject: process.Subject(FlareMsg),
  flare_id: String,
) -> Result(FlareRecord, Nil) {
  process.call(subject, 5000, fn(reply_to) {
    GetFlare(reply_to: reply_to, flare_id: flare_id)
  })
}

pub fn get_flare_by_label(
  subject: process.Subject(FlareMsg),
  label: String,
) -> Result(FlareRecord, Nil) {
  process.call(subject, 5000, fn(reply_to) {
    GetFlareByLabel(reply_to: reply_to, label: label)
  })
}

pub fn get_flare_by_session_name(
  subject: process.Subject(FlareMsg),
  session_name: String,
) -> Result(FlareRecord, Nil) {
  process.call(subject, 5000, fn(reply_to) {
    GetFlareBySessionName(reply_to: reply_to, session_name: session_name)
  })
}

pub fn list_flares(subject: process.Subject(FlareMsg)) -> List(FlareRecord) {
  process.call(subject, 5000, fn(reply_to) { ListFlares(reply_to: reply_to) })
}

pub fn park(
  subject: process.Subject(FlareMsg),
  flare_id: String,
  triggers_json: String,
) -> Result(Nil, String) {
  process.call(subject, 10_000, fn(reply_to) {
    Park(reply_to: reply_to, flare_id: flare_id, triggers_json: triggers_json)
  })
}

pub fn rekindle(
  subject: process.Subject(FlareMsg),
  flare_id: String,
  input: String,
) -> Result(String, String) {
  process.call(subject, 30_000, fn(reply_to) {
    Rekindle(reply_to: reply_to, flare_id: flare_id, input: input)
  })
}

/// Return all parked flares that have a non-empty triggers_json.
pub fn list_parked_with_triggers(
  subject: process.Subject(FlareMsg),
) -> List(FlareRecord) {
  process.call(subject, 5000, fn(reply_to) {
    ListParkedWithTriggers(reply_to: reply_to)
  })
}

/// Test-only: register a flare session directly, bypassing the dispatch path.
pub fn register_for_test(
  subject: process.Subject(FlareMsg),
  flare: FlareRecord,
) -> Nil {
  process.call(subject, 5000, fn(reply_to) {
    RegisterForTest(flare: flare, reply_to: reply_to)
  })
}

// ---------------------------------------------------------------------------
// Actor lifecycle
// ---------------------------------------------------------------------------

pub fn start(
  max_concurrent: Int,
  monitor_model: String,
  on_brain_event: fn(acp_monitor.AcpEvent) -> Nil,
  acp_transport: transport.Transport,
  db_subject: process.Subject(db.DbMessage),
) -> Result(process.Subject(FlareMsg), String) {
  let builder =
    actor.new_with_initialiser(10_000, fn(self_subject) {
      let #(flares, session_to_flare) =
        recover_flares(
          self_subject,
          monitor_model,
          on_brain_event,
          acp_transport,
          db_subject,
        )

      let state =
        FlareManagerState(
          flares: flares,
          session_to_flare: session_to_flare,
          max_concurrent: max_concurrent,
          db_subject: db_subject,
          monitor_model: monitor_model,
          on_brain_event: on_brain_event,
          self_subject: self_subject,
          transport: acp_transport,
        )
      Ok(actor.initialised(state) |> actor.returning(self_subject))
    })
    |> actor.on_message(handle_message)

  case actor.start(builder) {
    Ok(started) -> Ok(started.data)
    Error(err) ->
      Error("Failed to start flare manager actor: " <> string.inspect(err))
  }
}

// ---------------------------------------------------------------------------
// Message handler
// ---------------------------------------------------------------------------

fn handle_message(
  state: FlareManagerState,
  message: FlareMsg,
) -> actor.Next(FlareManagerState, FlareMsg) {
  case message {
    Ignite(
      reply_to:,
      label:,
      domain:,
      thread_id:,
      prompt:,
      execution_json:,
      triggers_json:,
      tools_json:,
      workspace:,
    ) -> {
      let #(new_state, result) =
        handle_ignite(
          state,
          label,
          domain,
          thread_id,
          prompt,
          execution_json,
          triggers_json,
          tools_json,
          workspace,
        )
      process.send(reply_to, result)
      actor.continue(new_state)
    }
    Archive(reply_to:, flare_id:) -> {
      let #(new_state, result) = handle_archive(state, flare_id)
      process.send(reply_to, result)
      actor.continue(new_state)
    }
    GetFlare(reply_to:, flare_id:) -> {
      process.send(reply_to, dict.get(state.flares, flare_id))
      actor.continue(state)
    }
    GetFlareByLabel(reply_to:, label:) -> {
      let result =
        dict.values(state.flares)
        |> list.find(fn(f) { f.label == label })
        |> result.replace_error(Nil)
      process.send(reply_to, result)
      actor.continue(state)
    }
    GetFlareBySessionName(reply_to:, session_name:) -> {
      let result = lookup_flare_by_session(state, session_name)
      process.send(reply_to, result)
      actor.continue(state)
    }
    ListFlares(reply_to:) -> {
      process.send(reply_to, dict.values(state.flares))
      actor.continue(state)
    }
    Dispatch(reply_to:, task_spec:, thread_id:, flare_id:) -> {
      let #(new_state, result) =
        handle_dispatch(state, task_spec, thread_id, flare_id)
      process.send(reply_to, result)
      actor.continue(new_state)
    }
    Kill(reply_to:, session_name:) -> {
      let #(new_state, result) = handle_kill(state, session_name)
      process.send(reply_to, result)
      actor.continue(new_state)
    }
    SendInput(reply_to:, session_name:, input:) -> {
      let #(new_state, result) = handle_send_input(state, session_name, input)
      process.send(reply_to, result)
      actor.continue(new_state)
    }
    GetSession(reply_to:, session_name:) -> {
      let result = lookup_flare_by_session(state, session_name)
      process.send(reply_to, result)
      actor.continue(state)
    }
    ListSessions(reply_to:) -> {
      // Return only flares that have an active session (session_name != "")
      let active =
        dict.values(state.flares)
        |> list.filter(fn(f) { f.session_name != "" })
      process.send(reply_to, active)
      actor.continue(state)
    }
    Park(reply_to:, flare_id:, triggers_json:) -> {
      let #(new_state, result) = handle_park(state, flare_id, triggers_json)
      process.send(reply_to, result)
      actor.continue(new_state)
    }
    Rekindle(reply_to:, flare_id:, input:) -> {
      let #(new_state, result) = handle_rekindle(state, flare_id, input)
      process.send(reply_to, result)
      actor.continue(new_state)
    }
    MonitorEvent(event) -> {
      let new_state = handle_monitor_event(state, event)
      actor.continue(new_state)
    }
    SetBrainCallback(on_brain_event:) -> {
      actor.continue(FlareManagerState(..state, on_brain_event: on_brain_event))
    }
    ListParkedWithTriggers(reply_to:) -> {
      let parked_with_triggers =
        dict.values(state.flares)
        |> list.filter(fn(f) {
          f.status == Parked && f.triggers_json != "" && f.triggers_json != "[]"
        })
      process.send(reply_to, parked_with_triggers)
      actor.continue(state)
    }

    RegisterForTest(flare:, reply_to:) -> {
      let new_flares = dict.insert(state.flares, flare.id, flare)
      let new_session_to_flare = case flare.session_name {
        "" -> state.session_to_flare
        sn -> dict.insert(state.session_to_flare, sn, flare.id)
      }
      process.send(reply_to, Nil)
      actor.continue(
        FlareManagerState(
          ..state,
          flares: new_flares,
          session_to_flare: new_session_to_flare,
        ),
      )
    }
  }
}

// ---------------------------------------------------------------------------
// Ignite — create a new flare with persistent identity
// ---------------------------------------------------------------------------

fn handle_ignite(
  state: FlareManagerState,
  label: String,
  domain: String,
  thread_id: String,
  prompt: String,
  execution_json: String,
  triggers_json: String,
  tools_json: String,
  workspace: String,
) -> #(FlareManagerState, Result(String, String)) {
  case execution_from_json(execution_json) {
    Error(e) -> #(state, Error("Invalid flare execution metadata: " <> e))
    Ok(_) -> {
      let now = time.now_ms()
      let flare_id = "f-" <> int.to_string(now)

      let flare =
        FlareRecord(
          id: flare_id,
          label: label,
          status: Active,
          domain: domain,
          thread_id: thread_id,
          original_prompt: prompt,
          execution_json: execution_json,
          triggers_json: triggers_json,
          tools_json: tools_json,
          workspace: workspace,
          session_id: "",
          session_name: "",
          handle: None,
          started_at_ms: now,
          updated_at_ms: now,
          awaiting_response: False,
        )

      let stored =
        db.StoredFlare(
          id: flare_id,
          label: label,
          status: status_to_string(flare.status),
          domain: domain,
          thread_id: thread_id,
          original_prompt: prompt,
          execution: execution_json,
          triggers: triggers_json,
          tools: tools_json,
          workspace: workspace,
          session_id: "",
          created_at_ms: now,
          updated_at_ms: now,
        )
      case db.upsert_flare(state.db_subject, stored) {
        Ok(_) -> {
          let new_flares = dict.insert(state.flares, flare_id, flare)
          let new_state = FlareManagerState(..state, flares: new_flares)
          logging.log(
            logging.Info,
            "[flare] Ignited: " <> flare_id <> " (" <> label <> ")",
          )
          #(new_state, Ok(flare_id))
        }
        Error(err) -> {
          logging.log(
            logging.Error,
            "[flare] Failed to persist ignite: " <> err,
          )
          #(state, Error("Failed to persist flare: " <> err))
        }
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Archive — mark flare as archived (work is done)
// ---------------------------------------------------------------------------

fn handle_archive(
  state: FlareManagerState,
  flare_id: String,
) -> #(FlareManagerState, Result(Nil, String)) {
  case dict.get(state.flares, flare_id) {
    Error(_) -> #(state, Error("Flare not found: " <> flare_id))
    Ok(flare) -> {
      case stop_flare_session(state.transport, flare, "archive") {
        Error(e) -> #(state, Error(e))
        Ok(_) -> {
          let now = time.now_ms()
          let updated =
            FlareRecord(..flare, status: Archived, updated_at_ms: now)

          case
            db.update_flare_status(
              state.db_subject,
              flare_id,
              status_to_string(Archived),
              now,
            )
          {
            Error(e) -> {
              let reason =
                "archive persistence failed after session stopped: " <> e
              let failed_state =
                mark_flare_session_stopped_after_persist_failure(
                  state,
                  flare,
                  reason,
                  now,
                )
              #(failed_state, Error("Failed to persist archive: " <> e))
            }
            Ok(_) -> {
              let new_flares = dict.insert(state.flares, flare_id, updated)
              let new_session_to_flare = case flare.session_name {
                "" -> state.session_to_flare
                sn -> dict.delete(state.session_to_flare, sn)
              }
              let new_state =
                FlareManagerState(
                  ..state,
                  flares: new_flares,
                  session_to_flare: new_session_to_flare,
                )
              logging.log(logging.Info, "[flare] Archived: " <> flare_id)
              #(new_state, Ok(Nil))
            }
          }
        }
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Concurrency guard
// ---------------------------------------------------------------------------

fn check_concurrency(state: FlareManagerState) -> Result(Nil, String) {
  let active_count =
    dict.values(state.flares)
    |> list.filter(fn(f) { f.session_name != "" && f.status == Active })
    |> list.length
  case active_count < state.max_concurrent {
    True -> Ok(Nil)
    False ->
      Error(
        "ACP concurrency limit reached ("
        <> int.to_string(state.max_concurrent)
        <> ")",
      )
  }
}

fn stop_flare_session(
  current_transport: transport.Transport,
  flare: FlareRecord,
  action: String,
) -> Result(Nil, String) {
  case flare.session_name {
    "" -> Ok(Nil)
    session_name -> {
      use control <- result.try(control_session_for_flare(
        current_transport,
        flare,
      ))
      transport.kill(control.transport, control.handle, session_name)
      |> result.map_error(fn(e) {
        "Failed to " <> action <> " " <> session_name <> ": " <> e
      })
    }
  }
}

fn mark_flare_session_stopped_after_persist_failure(
  state: FlareManagerState,
  flare: FlareRecord,
  reason: String,
  now: Int,
) -> FlareManagerState {
  logging.log(
    logging.Error,
    "[flare] " <> flare.id <> " marked failed in memory: " <> reason,
  )
  let updated =
    FlareRecord(
      ..flare,
      status: Failed(reason),
      session_name: "",
      handle: None,
      awaiting_response: False,
      updated_at_ms: now,
    )
  let new_session_to_flare = case flare.session_name {
    "" -> state.session_to_flare
    sn -> dict.delete(state.session_to_flare, sn)
  }
  FlareManagerState(
    ..state,
    flares: dict.insert(state.flares, flare.id, updated),
    session_to_flare: new_session_to_flare,
  )
}

// ---------------------------------------------------------------------------
// Dispatch — link a flare to a transport session
// ---------------------------------------------------------------------------

fn handle_dispatch(
  state: FlareManagerState,
  task_spec: types.TaskSpec,
  thread_id: String,
  flare_id: String,
) -> #(FlareManagerState, Result(String, String)) {
  // Check flare exists
  case dict.get(state.flares, flare_id) {
    Error(_) -> #(state, Error("Flare not found: " <> flare_id))
    Ok(flare) -> {
      case check_concurrency(state) {
        Error(e) -> #(state, Error(e))
        Ok(_) -> {
          let session_name =
            tmux.build_session_name(task_spec.domain, task_spec.id)

          let on_event = fn(event) {
            process.send(state.self_subject, MonitorEvent(event))
          }

          case
            transport.dispatch(
              state.transport,
              session_name,
              task_spec,
              state.monitor_model,
              on_event,
            )
          {
            Ok(result) -> {
              case
                execution_with_transport_json(
                  flare.execution_json,
                  state.transport,
                )
              {
                Error(e) -> {
                  let _ =
                    transport.kill(state.transport, result.handle, session_name)
                  #(state, Error(e))
                }
                Ok(execution_json) -> {
                  let now = time.now_ms()
                  let updated_flare =
                    FlareRecord(
                      ..flare,
                      execution_json: execution_json,
                      session_name: session_name,
                      session_id: result.run_id,
                      handle: Some(result.handle),
                      thread_id: thread_id,
                      status: Active,
                      updated_at_ms: now,
                      awaiting_response: True,
                    )

                  case
                    db.upsert_flare(
                      state.db_subject,
                      flare_to_stored(updated_flare),
                    )
                  {
                    Error(e) -> {
                      let _ =
                        transport.kill(
                          state.transport,
                          result.handle,
                          session_name,
                        )
                      #(state, Error("Failed to persist session link: " <> e))
                    }
                    Ok(_) -> {
                      let new_flares =
                        dict.insert(state.flares, flare_id, updated_flare)
                      let new_session_to_flare =
                        dict.insert(
                          state.session_to_flare,
                          session_name,
                          flare_id,
                        )
                      let new_state =
                        FlareManagerState(
                          ..state,
                          flares: new_flares,
                          session_to_flare: new_session_to_flare,
                        )
                      logging.log(
                        logging.Info,
                        "[flare] Dispatched: "
                          <> flare_id
                          <> " -> "
                          <> session_name,
                      )
                      #(new_state, Ok(session_name))
                    }
                  }
                }
              }
            }
            Error(err) -> {
              logging.log(
                logging.Info,
                "[flare] Dispatch failed for " <> flare_id <> ": " <> err,
              )
              #(state, Error(err))
            }
          }
        }
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Kill — via transport abstraction
// ---------------------------------------------------------------------------

fn handle_kill(
  state: FlareManagerState,
  session_name: String,
) -> #(FlareManagerState, Result(Nil, String)) {
  case lookup_flare_by_session(state, session_name) {
    Ok(flare) -> {
      case control_session_for_flare(state.transport, flare) {
        Ok(control) -> {
          case transport.kill(control.transport, control.handle, session_name) {
            Error(e) -> #(
              state,
              Error("Kill failed for " <> session_name <> ": " <> e),
            )
            Ok(_) -> {
              let new_state =
                update_flare_status(state, flare.id, Failed("killed"))
              #(new_state, Ok(Nil))
            }
          }
        }
        Error(e) -> #(state, Error(e))
      }
    }
    Error(_) -> {
      // Session not linked to any flare — try tmux fallback
      case state.transport {
        transport.Tmux -> {
          case tmux.session_exists(session_name) {
            True -> {
              case tmux.kill_session(session_name) {
                Ok(_) -> Nil
                Error(e) ->
                  logging.log(
                    logging.Info,
                    "[flare] tmux kill failed for " <> session_name <> ": " <> e,
                  )
              }
            }
            False -> Nil
          }
        }
        _ -> Nil
      }
      #(state, Ok(Nil))
    }
  }
}

// ---------------------------------------------------------------------------
// Send input — via transport abstraction
// ---------------------------------------------------------------------------

fn handle_send_input(
  state: FlareManagerState,
  session_name: String,
  input: String,
) -> #(FlareManagerState, Result(Nil, String)) {
  case lookup_flare_by_session(state, session_name) {
    Ok(flare) -> {
      case control_session_for_flare(state.transport, flare) {
        Ok(control) ->
          case
            transport.send_input(
              control.transport,
              control.handle,
              session_name,
              input,
            )
          {
            Ok(_) -> {
              let updated = FlareRecord(..flare, awaiting_response: True)
              let new_flares = dict.insert(state.flares, flare.id, updated)
              #(FlareManagerState(..state, flares: new_flares), Ok(Nil))
            }
            Error(e) -> #(state, Error(e))
          }
        Error(e) -> #(state, Error(e))
      }
    }
    Error(_) -> {
      // Fallback: for tmux transport, check if tmux session exists directly
      case state.transport {
        transport.Tmux -> {
          case tmux.session_exists(session_name) {
            True -> #(state, tmux.send_input(session_name, input))
            False -> #(state, Error("Session not found: " <> session_name))
          }
        }
        _ -> #(state, Error("Session not found: " <> session_name))
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Park — suspend a flare, kill its session, persist triggers
// ---------------------------------------------------------------------------

fn handle_park(
  state: FlareManagerState,
  flare_id: String,
  triggers_json: String,
) -> #(FlareManagerState, Result(Nil, String)) {
  case dict.get(state.flares, flare_id) {
    Error(_) -> #(state, Error("Flare not found: " <> flare_id))
    Ok(flare) -> {
      // Kill the transport session if active
      case stop_flare_session(state.transport, flare, "park") {
        Error(e) -> #(state, Error(e))
        Ok(_) -> {
          let now = time.now_ms()
          let updated =
            FlareRecord(
              ..flare,
              status: Parked,
              triggers_json: triggers_json,
              handle: None,
              session_name: "",
              updated_at_ms: now,
            )

          // Full upsert to persist triggers and status
          let stored = flare_to_stored(updated)
          case db.upsert_flare(state.db_subject, stored) {
            Ok(_) -> {
              let new_flares = dict.insert(state.flares, flare_id, updated)
              let new_session_to_flare = case flare.session_name {
                "" -> state.session_to_flare
                sn -> dict.delete(state.session_to_flare, sn)
              }
              let new_state =
                FlareManagerState(
                  ..state,
                  flares: new_flares,
                  session_to_flare: new_session_to_flare,
                )
              logging.log(logging.Info, "[flare] Parked: " <> flare_id)
              #(new_state, Ok(Nil))
            }
            Error(e) -> {
              let reason =
                "park persistence failed after session stopped: " <> e
              let failed_state =
                mark_flare_session_stopped_after_persist_failure(
                  state,
                  flare,
                  reason,
                  now,
                )
              #(failed_state, Error("Failed to persist park: " <> e))
            }
          }
        }
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Rekindle — resume a parked/failed flare with a new prompt
// ---------------------------------------------------------------------------

fn handle_rekindle(
  state: FlareManagerState,
  flare_id: String,
  input: String,
) -> #(FlareManagerState, Result(String, String)) {
  case dict.get(state.flares, flare_id) {
    Error(_) -> #(state, Error("Flare not found: " <> flare_id))
    Ok(flare) -> {
      // Guard: must not be Active already
      case flare.status {
        Active -> #(state, Error("Flare is already active: " <> flare_id))
        _ -> {
          case check_concurrency(state) {
            Error(e) -> #(state, Error(e))
            Ok(_) -> {
              case
                task_spec_for_rekindle(flare, input),
                transport_for_flare(state.transport, flare)
              {
                Ok(task_spec), Ok(acp_transport) -> {
                  let session_name =
                    tmux.build_session_name(flare.domain, flare.id)

                  let on_event = fn(event) {
                    process.send(state.self_subject, MonitorEvent(event))
                  }

                  // Use resume dispatch if we have a previous stdio session id.
                  let dispatch_result = case flare.session_id, acp_transport {
                    sid, transport.Stdio(command) if sid != "" ->
                      transport.dispatch_stdio_resume(
                        command,
                        session_name,
                        task_spec,
                        sid,
                        input,
                        state.monitor_model,
                        on_event,
                      )
                    _, _ ->
                      transport.dispatch(
                        acp_transport,
                        session_name,
                        task_spec,
                        state.monitor_model,
                        on_event,
                      )
                  }

                  case dispatch_result {
                    Ok(result) -> {
                      case
                        execution_with_transport_json(
                          flare.execution_json,
                          acp_transport,
                        )
                      {
                        Error(e) -> {
                          let _ =
                            transport.kill(
                              acp_transport,
                              result.handle,
                              session_name,
                            )
                          #(state, Error(e))
                        }
                        Ok(execution_json) -> {
                          let now = time.now_ms()
                          let updated_flare =
                            FlareRecord(
                              ..flare,
                              execution_json: execution_json,
                              session_name: session_name,
                              session_id: result.run_id,
                              handle: Some(result.handle),
                              status: Active,
                              updated_at_ms: now,
                              awaiting_response: True,
                            )

                          case
                            db.upsert_flare(
                              state.db_subject,
                              flare_to_stored(updated_flare),
                            )
                          {
                            Error(e) -> {
                              let _ =
                                transport.kill(
                                  acp_transport,
                                  result.handle,
                                  session_name,
                                )
                              #(
                                state,
                                Error("Failed to persist rekindle: " <> e),
                              )
                            }
                            Ok(_) -> {
                              let new_flares =
                                dict.insert(
                                  state.flares,
                                  flare_id,
                                  updated_flare,
                                )
                              let new_session_to_flare =
                                dict.insert(
                                  state.session_to_flare,
                                  session_name,
                                  flare_id,
                                )
                              let new_state =
                                FlareManagerState(
                                  ..state,
                                  flares: new_flares,
                                  session_to_flare: new_session_to_flare,
                                )
                              logging.log(
                                logging.Info,
                                "[flare] Rekindled: "
                                  <> flare_id
                                  <> " -> "
                                  <> session_name,
                              )
                              #(new_state, Ok(session_name))
                            }
                          }
                        }
                      }
                    }
                    Error(err) -> {
                      logging.log(
                        logging.Info,
                        "[flare] Rekindle dispatch failed for "
                          <> flare_id
                          <> ": "
                          <> err,
                      )
                      #(state, Error(err))
                    }
                  }
                }
                Error(e), _ -> #(state, Error(e))
                _, Error(e) -> #(state, Error(e))
              }
            }
          }
        }
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Helpers — FlareRecord to StoredFlare conversion
// ---------------------------------------------------------------------------

/// Convert a FlareRecord to a db.StoredFlare for upsert.
fn flare_to_stored(flare: FlareRecord) -> db.StoredFlare {
  db.StoredFlare(
    id: flare.id,
    label: flare.label,
    status: status_to_string(flare.status),
    domain: flare.domain,
    thread_id: flare.thread_id,
    original_prompt: flare.original_prompt,
    execution: flare.execution_json,
    triggers: flare.triggers_json,
    tools: flare.tools_json,
    workspace: flare.workspace,
    session_id: flare.session_id,
    created_at_ms: flare.started_at_ms,
    updated_at_ms: flare.updated_at_ms,
  )
}

// ---------------------------------------------------------------------------
// Monitor events
// ---------------------------------------------------------------------------

fn handle_monitor_event(
  state: FlareManagerState,
  event: acp_monitor.AcpEvent,
) -> FlareManagerState {
  let session_name = event_session_name(event)
  let new_state = case event {
    acp_monitor.AcpStarted(..) -> state
    acp_monitor.AcpCompleted(..) ->
      update_flare_for_session(state, session_name, Archived)
    acp_monitor.AcpTurnCompleted(..) -> {
      // Turn completed but session still alive — don't archive.
      // Clear awaiting_response so status reports "idle".
      case lookup_flare_by_session(state, session_name) {
        Ok(flare) -> {
          let updated = FlareRecord(..flare, awaiting_response: False)
          let new_flares = dict.insert(state.flares, flare.id, updated)
          FlareManagerState(..state, flares: new_flares)
        }
        Error(_) -> state
      }
    }
    acp_monitor.AcpFailed(_, _, reason) ->
      update_flare_for_session(state, session_name, Failed(reason))
    acp_monitor.AcpProgress(..) -> state
    acp_monitor.AcpAlert(..) -> state
  }
  // Forward to brain — lookup_flare_by_session has a fallback scan
  // that finds archived flares even after session_to_flare is cleared
  state.on_brain_event(event)
  new_state
}

/// Extract session_name from any AcpEvent.
fn event_session_name(event: acp_monitor.AcpEvent) -> String {
  case event {
    acp_monitor.AcpStarted(session_name, _, _) -> session_name
    acp_monitor.AcpAlert(session_name, _, _, _) -> session_name
    acp_monitor.AcpCompleted(session_name, _, _, _) -> session_name
    acp_monitor.AcpTurnCompleted(session_name, _, _) -> session_name
    acp_monitor.AcpFailed(session_name, _, _) -> session_name
    acp_monitor.AcpProgress(session_name, _, _, _, _, _) -> session_name
  }
}

// ---------------------------------------------------------------------------
// State helpers
// ---------------------------------------------------------------------------

/// Look up a flare by its session_name via the reverse index.
fn lookup_flare_by_session(
  state: FlareManagerState,
  session_name: String,
) -> Result(FlareRecord, Nil) {
  case dict.get(state.session_to_flare, session_name) {
    Ok(flare_id) -> dict.get(state.flares, flare_id)
    Error(_) ->
      // Fallback: scan all flares — needed when session_to_flare mapping
      // was already cleared (e.g., after AcpCompleted archives the flare)
      list.find(dict.values(state.flares), fn(f) {
        f.session_name == session_name
      })
  }
}

/// Update a flare's status by flare_id, persisting to SQLite.
fn update_flare_status(
  state: FlareManagerState,
  flare_id: String,
  new_status: FlareStatus,
) -> FlareManagerState {
  case dict.get(state.flares, flare_id) {
    Error(_) -> {
      logging.log(
        logging.Info,
        "[flare] Warning: status update for unknown flare " <> flare_id,
      )
      state
    }
    Ok(flare) -> {
      let now = time.now_ms()
      logging.log(
        logging.Info,
        "[flare] "
          <> flare_id
          <> " status: "
          <> status_to_string(flare.status)
          <> " -> "
          <> status_to_string(new_status),
      )
      let updated = FlareRecord(..flare, status: new_status, updated_at_ms: now)

      case
        db.update_flare_status(
          state.db_subject,
          flare_id,
          status_to_string(new_status),
          now,
        )
      {
        Ok(_) -> Nil
        Error(e) ->
          logging.log(
            logging.Error,
            "[flare] Failed to persist status update: " <> e,
          )
      }

      // Clear session mapping for terminal states
      let new_session_to_flare = case new_status {
        Failed(_) | Archived ->
          case flare.session_name {
            "" -> state.session_to_flare
            sn -> dict.delete(state.session_to_flare, sn)
          }
        _ -> state.session_to_flare
      }

      let new_flares = dict.insert(state.flares, flare_id, updated)
      FlareManagerState(
        ..state,
        flares: new_flares,
        session_to_flare: new_session_to_flare,
      )
    }
  }
}

/// Update a flare's status by looking up the session_name first.
fn update_flare_for_session(
  state: FlareManagerState,
  session_name: String,
  new_status: FlareStatus,
) -> FlareManagerState {
  case dict.get(state.session_to_flare, session_name) {
    Ok(flare_id) -> update_flare_status(state, flare_id, new_status)
    Error(_) -> {
      logging.log(
        logging.Info,
        "[flare] Warning: event for unknown session " <> session_name,
      )
      state
    }
  }
}

// ---------------------------------------------------------------------------
// Recovery — load from SQLite, check liveness via transport
// ---------------------------------------------------------------------------

fn recover_flares(
  self_subject: process.Subject(FlareMsg),
  monitor_model: String,
  on_brain_event: fn(acp_monitor.AcpEvent) -> Nil,
  acp_transport: transport.Transport,
  db_subject: process.Subject(db.DbMessage),
) -> #(Dict(String, FlareRecord), Dict(String, String)) {
  case db.load_flares(db_subject, True) {
    Error(err) -> {
      logging.log(
        logging.Error,
        "[flare] Failed to load flares from DB: " <> err,
      )
      #(dict.new(), dict.new())
    }
    Ok(stored_flares) -> {
      case stored_flares {
        [] -> #(dict.new(), dict.new())
        _ -> {
          logging.log(
            logging.Info,
            "[flare] Recovering "
              <> int.to_string(list.length(stored_flares))
              <> " flare(s)...",
          )
          let pairs =
            list.map(stored_flares, fn(sf) {
              recover_single_flare(
                sf,
                self_subject,
                monitor_model,
                on_brain_event,
                acp_transport,
                db_subject,
              )
            })
          let flare_dict =
            list.map(pairs, fn(p) { #({ p.0 }.id, p.0) })
            |> dict.from_list
          let session_dict =
            list.filter_map(pairs, fn(p) {
              case p.1 {
                "" -> Error(Nil)
                sn -> Ok(#(sn, { p.0 }.id))
              }
            })
            |> dict.from_list
          // Schedule staggered rekindles for flares that need it (3s, 5s, 7s, ...)
          let needs_rekindle = list.filter(pairs, fn(p) { p.2 })
          list.index_map(needs_rekindle, fn(p, idx) {
            let delay = 3000 + idx * 2000
            process.send_after(
              self_subject,
              delay,
              Rekindle(
                reply_to: process.new_subject(),
                flare_id: { p.0 }.id,
                input: "Check your current state. If you have unfinished work, continue. If you are done, report what you accomplished.",
              ),
            )
          })
          #(flare_dict, session_dict)
        }
      }
    }
  }
}

/// Recover a single flare. Returns the FlareRecord, its session_name
/// (empty string if no active session), and a Bool indicating whether
/// a rekindle should be scheduled (staggered by the caller).
fn recover_single_flare(
  sf: db.StoredFlare,
  self_subject: process.Subject(FlareMsg),
  monitor_model: String,
  _on_brain_event: fn(acp_monitor.AcpEvent) -> Nil,
  acp_transport: transport.Transport,
  db_subject: process.Subject(db.DbMessage),
) -> #(FlareRecord, String, Bool) {
  let stored_status = status_from_string(sf.status)
  let session_name = tmux.build_session_name(sf.domain, sf.id)

  case stored_status {
    Active -> {
      case transport_for_stored_flare(acp_transport, sf) {
        Error(e) -> {
          let reason = "invalid execution metadata: " <> e
          logging.log(
            logging.Error,
            "[flare] Cannot recover " <> sf.id <> ": " <> reason,
          )
          let _ =
            db.update_flare_status(
              db_subject,
              sf.id,
              status_to_string(Failed(reason)),
              time.now_ms(),
            )
          let flare = stored_flare_to_record(sf, Failed(reason), "", None)
          #(flare, "", False)
        }
        Ok(recovery_transport) -> {
          // Check if the original transport session is still alive.
          case
            transport.is_alive(recovery_transport, sf.session_id, session_name)
          {
            True -> {
              logging.log(
                logging.Info,
                "[flare] Recovering alive flare: "
                  <> sf.id
                  <> " ("
                  <> sf.label
                  <> ")",
              )

              // Re-attach monitor
              let on_event = fn(event) {
                process.send(self_subject, MonitorEvent(event))
              }
              reattach_monitor(
                recovery_transport,
                sf,
                session_name,
                monitor_model,
                on_event,
              )

              let handle = case
                recover_session_handle(recovery_transport, sf.session_id)
              {
                Ok(recovered) -> Some(recovered)
                Error(_) -> None
              }
              let flare =
                stored_flare_to_record(sf, Active, session_name, handle)
              #(flare, session_name, False)
            }
            False -> {
              // Process died (deploy/restart) — caller schedules staggered rekindle
              logging.log(
                logging.Info,
                "[flare] Session dead, auto-rekindling: "
                  <> sf.id
                  <> " ("
                  <> sf.label
                  <> ")",
              )
              // Load as Parked so rekindle guard passes (rejects Active)
              let flare = stored_flare_to_record(sf, Parked, "", None)
              #(flare, "", True)
            }
          }
        }
      }
    }
    Parked -> {
      // Just load into memory, no session to check
      logging.log(
        logging.Info,
        "[flare] Loading parked flare: " <> sf.id <> " (" <> sf.label <> ")",
      )
      let flare = stored_flare_to_record(sf, Parked, "", None)
      #(flare, "", False)
    }
    Failed(reason) -> {
      // Load failed flares into memory for visibility
      logging.log(
        logging.Info,
        "[flare] Loading failed flare: " <> sf.id <> " (" <> sf.label <> ")",
      )
      let flare = stored_flare_to_record(sf, Failed(reason), "", None)
      #(flare, "", False)
    }
    Archived -> {
      // Shouldn't reach here (excluded by load_flares), but handle gracefully
      let flare = stored_flare_to_record(sf, Archived, "", None)
      #(flare, "", False)
    }
  }
}

/// Convert a StoredFlare to a FlareRecord.
fn stored_flare_to_record(
  sf: db.StoredFlare,
  status: FlareStatus,
  session_name: String,
  handle: Option(transport.SessionHandle),
) -> FlareRecord {
  FlareRecord(
    id: sf.id,
    label: sf.label,
    status: status,
    domain: sf.domain,
    thread_id: sf.thread_id,
    original_prompt: sf.original_prompt,
    execution_json: sf.execution,
    triggers_json: sf.triggers,
    tools_json: sf.tools,
    workspace: sf.workspace,
    session_id: sf.session_id,
    session_name: session_name,
    handle: handle,
    started_at_ms: sf.created_at_ms,
    updated_at_ms: sf.updated_at_ms,
    awaiting_response: False,
  )
}

/// Re-attach a monitor to a recovered session based on transport type.
fn reattach_monitor(
  acp_transport: transport.Transport,
  sf: db.StoredFlare,
  session_name: String,
  monitor_model: String,
  on_event: fn(acp_monitor.AcpEvent) -> Nil,
) -> Nil {
  case acp_transport {
    transport.Tmux -> {
      let task_spec =
        types.TaskSpec(
          id: sf.id,
          domain: sf.domain,
          prompt: sf.original_prompt,
          cwd: sf.workspace,
          timeout_ms: 30 * 60_000,
          acceptance_criteria: [],
          provider: provider_from_domain(),
          worktree: True,
        )
      case
        acp_monitor.start_monitor_only(
          task_spec,
          session_name,
          monitor_model,
          on_event,
          False,
          False,
        )
      {
        Ok(_) ->
          logging.log(
            logging.Info,
            "[flare] Monitor re-attached: " <> session_name,
          )
        Error(e) ->
          logging.log(
            logging.Info,
            "[flare] Failed to re-attach monitor for "
              <> session_name
              <> ": "
              <> e,
          )
      }
    }
    transport.Http(server_url, _) -> {
      // Re-start SSE listener for HTTP sessions
      let run_id = sf.session_id
      let domain = sf.domain
      process.spawn_unlinked(fn() {
        let self_pid = process.self()
        process.spawn_unlinked(fn() {
          client.subscribe_events(server_url, run_id, self_pid)
        })
        transport.http_event_loop(
          on_event,
          session_name,
          domain,
          run_id,
          server_url,
        )
      })
      Nil
    }
    transport.Stdio(_) -> {
      // Stdio sessions can't survive restarts — should never reach here
      Nil
    }
  }
}

/// Default provider for recovery (ClaudeCode is the standard).
fn provider_from_domain() -> provider.AcpProvider {
  provider.ClaudeCode
}
