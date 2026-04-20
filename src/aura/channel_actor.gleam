//// Per-channel actor that runs turns concurrently with other channels.
//// Phase 1: types + skeleton. Phase 2+ adds the state machine.

import aura/acp/flare_manager
import aura/brain_tools
import aura/clients/browser_runner
import aura/clients/discord_client
import aura/clients/llm_client
import aura/clients/skill_runner
import aura/conversation
import aura/db
import aura/discord
import aura/llm
import aura/notification
import aura/shell
import aura/skill
import aura/validator
import aura/vision
import aura/xdg
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Monitor, type Pid, type Subject, type Timer}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import gleam/string

pub type ChannelMessage {
  HandleIncoming(discord.IncomingMessage)
  HandleHandback(flare_id: String, result: String)
  HandleFinding(notification.Finding)
  HandleInteraction(
    interaction_id: String,
    interaction_token: String,
    custom_id: String,
  )
  Cancel

  VisionComplete(description: String)
  VisionError(reason: String)

  StreamDelta(text: String)
  StreamReasoning
  StreamComplete(
    content: String,
    tool_calls_json: String,
    prompt_tokens: Int,
  )
  StreamError(reason: String)

  ToolResult(call_id: String, result: String, is_error: Bool)

  CompressionComplete(
    new_history: List(llm.Message),
    new_state: conversation.CompressorState,
    snapshot_len: Int,
  )

  TurnDeadline

  WorkerDown(monitor: Monitor, reason: String)

  RegisterProposal(proposal: brain_tools.PendingProposal)
  RegisterShellApproval(approval: brain_tools.PendingShellApproval)
}

pub type TurnKind {
  UserTurn(message_id: String, author_id: String)
  HandbackTurn(flare_id: String)
  FindingTurn(finding: notification.Finding)
}

pub type WorkerKind {
  VisionWorker
  StreamWorker
  ToolWorker(name: String, call_id: String)
}

pub type StreamStats {
  StreamStats(
    start_ms: Int,
    reasoning_count: Int,
    delta_count: Int,
    last_heartbeat_ms: Int,
  )
}

pub type TurnState {
  TurnState(
    kind: TurnKind,
    discord_msg_id: String,
    started_at: Int,
    iteration: Int,
    worker_pid: Pid,
    worker_monitor: Option(Monitor),
    worker_kind: WorkerKind,
    accumulated_content: String,
    accumulated_tool_calls: List(llm.ToolCall),
    pending_tool_results: Dict(String, #(String, Bool)),
    new_messages: List(llm.Message),
    traces: List(conversation.ToolTrace),
    messages_at_llm_call: List(llm.Message),
    stream_retry_count: Int,
    stream_stats: StreamStats,
    deadline_timer: Option(Timer),
  )
}

pub type PendingWork {
  PendingUserMessage(discord.IncomingMessage)
  PendingHandback(flare_id: String, result: String)
  PendingFinding(notification.Finding)
}

pub type ChannelState {
  ChannelState(
    channel_id: String,
    domain: Option(String),
    conversation: List(llm.Message),
    compressor_state: conversation.CompressorState,
    tool_ctx: brain_tools.ToolContext,
    turn: Option(TurnState),
    queue: List(PendingWork),
    review_counts: #(Int, Int),
    pending_proposals: List(brain_tools.PendingProposal),
    pending_shell_approvals: List(brain_tools.PendingShellApproval),
    typing_pid: Option(Pid),
    discord_token: String,
    self_subject: Subject(ChannelMessage),
  )
}

// ---------------------------------------------------------------------------
// Production Deps type
// ---------------------------------------------------------------------------

/// Full dependencies for production channel actor construction.
pub type Deps {
  Deps(
    channel_id: String,
    discord_token: String,
    db_subject: process.Subject(db.DbMessage),
    acp_subject: process.Subject(flare_manager.FlareMsg),
    paths: xdg.Paths,
    discord: discord_client.DiscordClient,
    llm_client: llm_client.LLMClient,
    skill_runner: skill_runner.SkillRunner,
    browser_runner: browser_runner.BrowserRunner,
    skill_infos: List(skill.SkillInfo),
    skills_dir: String,
    validation_rules: List(validator.Rule),
    base_dir: String,
    domain_name: String,
    domain_cwd: String,
  )
}

/// Start a channel actor with production deps.
pub fn start(
  deps: Deps,
) -> Result(Subject(ChannelMessage), actor.StartError) {
  actor.new_with_initialiser(5000, fn(self_subject) {
    let state = build_initial_state(deps, self_subject)
    Ok(actor.initialised(state) |> actor.returning(self_subject))
  })
  |> actor.on_message(handle_message)
  |> actor.start
  |> result.map(fn(started) { started.data })
}

fn build_initial_state(
  deps: Deps,
  self: Subject(ChannelMessage),
) -> ChannelState {
  let tool_ctx =
    brain_tools.ToolContext(
      base_dir: deps.base_dir,
      discord_token: deps.discord_token,
      guild_id: "",
      message_id: "",
      channel_id: deps.channel_id,
      paths: deps.paths,
      skill_infos: deps.skill_infos,
      skills_dir: deps.skills_dir,
      validation_rules: deps.validation_rules,
      db_subject: deps.db_subject,
      scheduler_subject: None,
      acp_subject: deps.acp_subject,
      domain_name: deps.domain_name,
      domain_cwd: deps.domain_cwd,
      acp_provider: "",
      acp_binary: "",
      acp_worktree: False,
      acp_server_url: "",
      acp_agent_name: "",
      on_propose: fn(_proposal) { Nil },
      shell_patterns: shell.compile_patterns(),
      on_shell_approve: fn(_approval) { Nil },
      vision_fn: fn(_url, _question) { Error("stub") },
      discord: deps.discord,
      llm_client: deps.llm_client,
      skill_runner: deps.skill_runner,
      browser_runner: deps.browser_runner,
    )
  ChannelState(
    channel_id: deps.channel_id,
    domain: None,
    conversation: [],
    compressor_state: conversation.new_compressor_state(),
    tool_ctx: tool_ctx,
    turn: None,
    queue: [],
    review_counts: #(0, 0),
    pending_proposals: [],
    pending_shell_approvals: [],
    typing_pid: None,
    discord_token: deps.discord_token,
    self_subject: self,
  )
}

// ---------------------------------------------------------------------------
// Test construction
// ---------------------------------------------------------------------------

/// Minimal deps for test-only actor construction.
pub type TestDeps {
  TestDeps(channel_id: String, discord_token: String)
}

/// Build a `Deps` record suitable for tests, using stub subjects and real
/// (but network-idle) production clients. Reuse this in test files to avoid
/// duplicating stub wiring logic.
pub fn test_deps(channel_id: String, discord_token: String) -> Deps {
  let paths = xdg.resolve()
  let db_subject = process.new_subject()
  let acp_subject = process.new_subject()
  Deps(
    channel_id: channel_id,
    discord_token: discord_token,
    db_subject: db_subject,
    acp_subject: acp_subject,
    paths: paths,
    discord: discord_client.production(discord_token),
    llm_client: llm_client.production(),
    skill_runner: skill_runner.production(),
    browser_runner: browser_runner.production(),
    skill_infos: [],
    skills_dir: "",
    validation_rules: [],
    base_dir: "/tmp",
    domain_name: "",
    domain_cwd: "",
  )
}

/// Start a channel actor with stubbed deps for smoke tests.
/// Production clients are used but no real network calls will be made
/// since the no-op handle_message never invokes the tool context.
pub fn start_for_test(
  deps: TestDeps,
) -> Result(Subject(ChannelMessage), actor.StartError) {
  actor.new_with_initialiser(5000, fn(self_subject) {
    let state = build_initial_state_for_test(deps, self_subject)
    Ok(actor.initialised(state) |> actor.returning(self_subject))
  })
  |> actor.on_message(handle_message)
  |> actor.start
  |> result.map(fn(started) { started.data })
}

fn build_initial_state_for_test(
  deps: TestDeps,
  self: Subject(ChannelMessage),
) -> ChannelState {
  let paths = xdg.resolve()
  // Stub subjects that won't receive messages in smoke tests
  let db_subject = process.new_subject()
  let acp_subject = process.new_subject()
  let tool_ctx =
    brain_tools.ToolContext(
      base_dir: "/tmp",
      discord_token: deps.discord_token,
      guild_id: "",
      message_id: "",
      channel_id: deps.channel_id,
      paths: paths,
      skill_infos: [],
      skills_dir: "",
      validation_rules: [],
      db_subject: db_subject,
      scheduler_subject: None,
      acp_subject: acp_subject,
      domain_name: "",
      domain_cwd: "",
      acp_provider: "",
      acp_binary: "",
      acp_worktree: False,
      acp_server_url: "",
      acp_agent_name: "",
      on_propose: fn(_proposal) { Nil },
      shell_patterns: shell.compile_patterns(),
      on_shell_approve: fn(_approval) { Nil },
      vision_fn: fn(_url, _question) { Error("stub") },
      discord: discord_client.production(deps.discord_token),
      llm_client: llm_client.production(),
      skill_runner: skill_runner.production(),
      browser_runner: browser_runner.production(),
    )
  ChannelState(
    channel_id: deps.channel_id,
    domain: None,
    conversation: [],
    compressor_state: conversation.new_compressor_state(),
    tool_ctx: tool_ctx,
    turn: None,
    queue: [],
    review_counts: #(0, 0),
    pending_proposals: [],
    pending_shell_approvals: [],
    typing_pid: None,
    discord_token: deps.discord_token,
    self_subject: self,
  )
}

// ---------------------------------------------------------------------------
// Message handler (Phase 1 stub)
// ---------------------------------------------------------------------------

/// Phase 1: no-op handler. Every message is acknowledged and state is
/// returned unchanged. Later tasks replace individual arms with real
/// state-machine transitions.
fn handle_message(
  state: ChannelState,
  _message: ChannelMessage,
) -> actor.Next(ChannelState, ChannelMessage) {
  actor.continue(state)
}

// ---------------------------------------------------------------------------
// Effect type
// ---------------------------------------------------------------------------

/// Effects emitted by `transition`. The actor's effect interpreter (Task 16)
/// translates these into real side effects (spawn processes, edit Discord
/// messages, schedule timers). Declared up-front so Tasks 9-15 can emit
/// variants without growing the type.
pub type Effect {
  SpawnStreamWorker(messages: List(llm.Message))
  SpawnToolWorker(call: llm.ToolCall)
  SpawnVisionWorker(image_path: String, question: String)
  KillWorker(pid: Pid)
  CancelDeadline(timer: Timer)
  ScheduleDeadline(ms: Int)
  DiscordEdit(msg_id: String, content: String)
  DiscordSend(content: String)
  DbSaveExchange(
    messages: List(llm.Message),
    author_id: String,
    author_name: String,
    prompt_tokens: Int,
  )
  StopTyping(pid: Pid)
  StartTyping
  LogHeartbeat(stats: StreamStats, content_chars: Int)
  LogStreamSummary(stats: StreamStats, outcome: String, content_chars: Int)
  SpawnSkillReview
  SpawnMemoryReview
}

// ---------------------------------------------------------------------------
// Pure transition
// ---------------------------------------------------------------------------

/// Pure state-machine transition. Given current state and an incoming
/// message, return the next state and a list of effects for the interpreter
/// to execute. Task 8 handles only `HandleIncoming` — queueing when busy,
/// starting a turn when idle. Tasks 9-15 will extend other arms.
pub fn transition(
  state: ChannelState,
  message: ChannelMessage,
) -> #(ChannelState, List(Effect)) {
  case message, state.turn {
    HandleIncoming(msg), None -> start_turn(state, PendingUserMessage(msg))
    HandleIncoming(msg), Some(_) -> {
      let new_queue = list.append(state.queue, [PendingUserMessage(msg)])
      #(ChannelState(..state, queue: new_queue), [])
    }

    // --- Task 9: vision results ---------------------------------------------
    VisionComplete(description), Some(turn) -> {
      let enriched =
        enrich_messages_with_description(
          turn.messages_at_llm_call,
          description,
        )
      let new_turn =
        TurnState(
          ..turn,
          worker_kind: StreamWorker,
          messages_at_llm_call: enriched,
        )
      #(ChannelState(..state, turn: Some(new_turn)), [
        SpawnStreamWorker(enriched),
      ])
    }
    VisionError(_reason), Some(turn) -> {
      let new_turn = TurnState(..turn, worker_kind: StreamWorker)
      #(ChannelState(..state, turn: Some(new_turn)), [
        SpawnStreamWorker(turn.messages_at_llm_call),
      ])
    }
    VisionComplete(_), None -> #(state, [])
    VisionError(_), None -> #(state, [])

    // --- Task 10: stream deltas and reasoning -------------------------------
    StreamDelta(text), Some(turn) -> {
      let new_acc = turn.accumulated_content <> text
      let new_stats =
        StreamStats(
          ..turn.stream_stats,
          delta_count: turn.stream_stats.delta_count + 1,
        )
      let new_turn =
        TurnState(
          ..turn,
          accumulated_content: new_acc,
          stream_stats: new_stats,
        )
      let edit_effects = case should_progressive_edit(turn, new_acc) {
        True -> [
          DiscordEdit(turn.discord_msg_id, format_progress(new_acc, turn.traces)),
        ]
        False -> []
      }
      #(
        ChannelState(..state, turn: Some(new_turn)),
        list.append(edit_effects, [
          LogHeartbeat(new_stats, string.length(new_acc)),
        ]),
      )
    }
    StreamReasoning, Some(turn) -> {
      let new_stats =
        StreamStats(
          ..turn.stream_stats,
          reasoning_count: turn.stream_stats.reasoning_count + 1,
        )
      let new_turn = TurnState(..turn, stream_stats: new_stats)
      #(ChannelState(..state, turn: Some(new_turn)), [
        LogHeartbeat(new_stats, string.length(turn.accumulated_content)),
      ])
    }
    StreamDelta(_), None -> #(state, [])
    StreamReasoning, None -> #(state, [])

    // --- Task 11: stream complete (terminal vs tool-call) -------------------
    StreamComplete(content, tool_calls_json, prompt_tokens), Some(turn) -> {
      case llm.parse_flat_tool_calls_json(tool_calls_json) {
        Ok([]) -> finalize_turn(state, turn, content, prompt_tokens)
        Error(_) -> finalize_turn(state, turn, content, prompt_tokens)
        Ok([first_call, ..rest]) -> {
          let new_turn =
            TurnState(
              ..turn,
              accumulated_tool_calls: [first_call, ..rest],
              pending_tool_results: dict.new(),
              worker_kind: ToolWorker(first_call.name, first_call.id),
            )
          #(ChannelState(..state, turn: Some(new_turn)), [
            SpawnToolWorker(first_call),
            LogStreamSummary(
              turn.stream_stats,
              "complete",
              string.length(content),
            ),
          ])
        }
      }
    }
    StreamComplete(_, _, _), None -> #(state, [])

    // --- Task 12: tool result sequencing ------------------------------------
    ToolResult(call_id, result, is_error), Some(turn) -> {
      let new_pending =
        dict.insert(turn.pending_tool_results, call_id, #(result, is_error))
      let trace =
        conversation.ToolTrace(
          name: find_tool_name(turn.accumulated_tool_calls, call_id),
          args: "",
          result: result,
          is_error: is_error,
        )
      let new_traces = list.append(turn.traces, [trace])
      case all_tool_calls_resolved(turn.accumulated_tool_calls, new_pending) {
        False -> {
          case find_next_unresolved(turn.accumulated_tool_calls, new_pending) {
            Some(next_call) -> {
              let new_turn =
                TurnState(
                  ..turn,
                  pending_tool_results: new_pending,
                  traces: new_traces,
                  worker_kind: ToolWorker(next_call.name, next_call.id),
                )
              #(ChannelState(..state, turn: Some(new_turn)), [
                SpawnToolWorker(next_call),
              ])
            }
            None -> #(state, [])
          }
        }
        True -> {
          let tool_result_messages =
            list.map(turn.accumulated_tool_calls, fn(call) {
              case dict.get(new_pending, call.id) {
                Ok(#(text, _)) -> llm.ToolResultMessage(call.id, text)
                Error(_) -> llm.ToolResultMessage(call.id, "")
              }
            })
          let new_messages =
            list.flatten([
              turn.new_messages,
              [
                llm.AssistantToolCallMessage(
                  turn.accumulated_content,
                  turn.accumulated_tool_calls,
                ),
              ],
              tool_result_messages,
            ])
          let next_llm_messages = list.append(state.conversation, new_messages)
          let new_turn =
            TurnState(
              ..turn,
              iteration: turn.iteration + 1,
              accumulated_content: "",
              accumulated_tool_calls: [],
              pending_tool_results: dict.new(),
              new_messages: new_messages,
              traces: new_traces,
              messages_at_llm_call: next_llm_messages,
              stream_retry_count: 0,
              stream_stats: StreamStats(
                start_ms: 0,
                reasoning_count: 0,
                delta_count: 0,
                last_heartbeat_ms: 0,
              ),
              worker_kind: StreamWorker,
            )
          #(ChannelState(..state, turn: Some(new_turn)), [
            SpawnStreamWorker(next_llm_messages),
          ])
        }
      }
    }
    ToolResult(_, _, _), None -> #(state, [])

    _, _ -> #(state, [])
  }
}

/// True when every accumulated tool call has a result recorded in `pending`.
fn all_tool_calls_resolved(
  calls: List(llm.ToolCall),
  pending: Dict(String, #(String, Bool)),
) -> Bool {
  list.all(calls, fn(c) { dict.has_key(pending, c.id) })
}

/// Find the first tool call that hasn't been resolved in `pending`.
fn find_next_unresolved(
  calls: List(llm.ToolCall),
  pending: Dict(String, #(String, Bool)),
) -> Option(llm.ToolCall) {
  list.find(calls, fn(c) { !dict.has_key(pending, c.id) })
  |> option.from_result
}

/// Look up the tool name by call id in the accumulated tool calls.
fn find_tool_name(calls: List(llm.ToolCall), id: String) -> String {
  case list.find(calls, fn(c) { c.id == id }) {
    Ok(c) -> c.name
    Error(_) -> "unknown"
  }
}

fn start_turn(
  state: ChannelState,
  work: PendingWork,
) -> #(ChannelState, List(Effect)) {
  case work {
    PendingUserMessage(msg) -> {
      let messages = build_llm_messages(state, msg)
      case has_image_attachment(msg) {
        True -> {
          let #(path, question) = first_image_and_question(msg)
          #(state_with_pending_vision(state, messages, msg), [
            SpawnVisionWorker(path, question),
            StartTyping,
            ScheduleDeadline(600_000),
          ])
        }
        False ->
          #(state_with_pending_stream(state, messages, msg), [
            SpawnStreamWorker(messages),
            StartTyping,
            ScheduleDeadline(600_000),
          ])
      }
    }
    _ -> #(state, [])
  }
}

// ---------------------------------------------------------------------------
// Transition helpers
// ---------------------------------------------------------------------------

/// Build the message list to send to the LLM for this turn. For Task 8 the
/// system prompt/domain context is not assembled here — the effect
/// interpreter (Task 16) is responsible for prepending domain-aware context
/// before handing off to the LLM call.
fn build_llm_messages(
  state: ChannelState,
  msg: discord.IncomingMessage,
) -> List(llm.Message) {
  list.append(state.conversation, [llm.UserMessage(content: msg.content)])
}

fn has_image_attachment(msg: discord.IncomingMessage) -> Bool {
  list.any(msg.attachments, vision.is_image_attachment)
}

fn first_image_and_question(
  msg: discord.IncomingMessage,
) -> #(String, String) {
  let first_url =
    list.find_map(msg.attachments, fn(att) {
      case vision.is_image_attachment(att) {
        True -> Ok(att.url)
        False -> Error(Nil)
      }
    })
  let url = case first_url {
    Ok(u) -> u
    Error(_) -> ""
  }
  #(url, "Describe this image in detail for downstream tool use.")
}

fn new_turn_state(
  kind: TurnKind,
  worker_kind: WorkerKind,
  messages: List(llm.Message),
) -> TurnState {
  TurnState(
    kind: kind,
    discord_msg_id: "",
    started_at: 0,
    iteration: 0,
    worker_pid: process.self(),
    worker_monitor: None,
    worker_kind: worker_kind,
    accumulated_content: "",
    accumulated_tool_calls: [],
    pending_tool_results: dict.new(),
    new_messages: [],
    traces: [],
    messages_at_llm_call: messages,
    stream_retry_count: 0,
    stream_stats: StreamStats(
      start_ms: 0,
      reasoning_count: 0,
      delta_count: 0,
      last_heartbeat_ms: 0,
    ),
    deadline_timer: None,
  )
}

fn state_with_pending_vision(
  state: ChannelState,
  messages: List(llm.Message),
  msg: discord.IncomingMessage,
) -> ChannelState {
  let kind = UserTurn(message_id: msg.message_id, author_id: msg.author_id)
  let turn = new_turn_state(kind, VisionWorker, messages)
  ChannelState(..state, turn: Some(turn))
}

fn state_with_pending_stream(
  state: ChannelState,
  messages: List(llm.Message),
  msg: discord.IncomingMessage,
) -> ChannelState {
  let kind = UserTurn(message_id: msg.message_id, author_id: msg.author_id)
  let turn = new_turn_state(kind, StreamWorker, messages)
  ChannelState(..state, turn: Some(turn))
}

/// Progressive-edit threshold: re-render the Discord message every N chars
/// of accumulated content. Mirrors `brain.progressive_edit_chars`.
const progressive_edit_chars: Int = 150

/// Append the vision description to the last `UserMessage` in the history,
/// mirroring the `[Image: <desc>]` prefix that `brain.preprocess_attachments`
/// produces. If there is no `UserMessage`, append a new one carrying just the
/// description so the stream worker still sees the context.
fn enrich_messages_with_description(
  messages: List(llm.Message),
  description: String,
) -> List(llm.Message) {
  let reversed = list.reverse(messages)
  case replace_last_user_message(reversed, description, []) {
    Ok(enriched) -> enriched
    Error(_) ->
      list.append(messages, [
        llm.UserMessage(content: "[Image description: " <> description <> "]"),
      ])
  }
}

fn replace_last_user_message(
  reversed: List(llm.Message),
  description: String,
  acc_forward_suffix: List(llm.Message),
) -> Result(List(llm.Message), Nil) {
  case reversed {
    [] -> Error(Nil)
    [llm.UserMessage(content: original), ..rest] -> {
      let enriched =
        llm.UserMessage(
          content: original
            <> "\n\n[Image description: "
            <> description
            <> "]",
        )
      Ok(list.append(list.reverse(rest), [enriched, ..acc_forward_suffix]))
    }
    [other, ..rest] ->
      replace_last_user_message(rest, description, [other, ..acc_forward_suffix])
  }
}

/// Trigger a progressive edit every `progressive_edit_chars` characters of
/// newly accumulated content. Uses `delta_count` as a coarse pacing signal
/// — since deltas are small and frequent, this keeps edit cadence bounded.
fn should_progressive_edit(turn: TurnState, new_acc: String) -> Bool {
  let last_edit_len = turn.stream_stats.delta_count * progressive_edit_chars
  string.length(new_acc) - last_edit_len > progressive_edit_chars
}

/// Format the in-progress message for Discord, mirroring how
/// `brain.collect_stream_loop` renders partial content.
fn format_progress(content: String, traces: List(conversation.ToolTrace)) -> String {
  conversation.format_full_message(traces, content <> " ...")
}

/// Finalize a turn with no further tool calls: emit the final Discord edit,
/// persist the exchange, log the stream summary, and (conditionally) stop
/// typing / cancel the deadline. If work is queued, start the next turn.
fn finalize_turn(
  state: ChannelState,
  turn: TurnState,
  content: String,
  prompt_tokens: Int,
) -> #(ChannelState, List(Effect)) {
  let final_messages =
    list.append(turn.new_messages, [llm.AssistantMessage(content)])
  let author_id = case turn.kind {
    UserTurn(_, author_id) -> author_id
    _ -> ""
  }
  let base_effects = [
    DiscordEdit(turn.discord_msg_id, format_progress(content, turn.traces)),
    DbSaveExchange(final_messages, author_id, "", prompt_tokens),
    LogStreamSummary(turn.stream_stats, "complete", string.length(content)),
  ]
  let with_typing = case state.typing_pid {
    Some(pid) -> list.append(base_effects, [StopTyping(pid)])
    None -> base_effects
  }
  let with_deadline = case turn.deadline_timer {
    Some(timer) -> list.append(with_typing, [CancelDeadline(timer)])
    None -> with_typing
  }
  let cleared = ChannelState(..state, turn: None, typing_pid: None)
  case state.queue {
    [] -> #(cleared, with_deadline)
    [next, ..rest] -> {
      let #(new_state, start_effects) =
        start_turn(ChannelState(..cleared, queue: rest), next)
      #(new_state, list.append(with_deadline, start_effects))
    }
  }
}

// ---------------------------------------------------------------------------
// Test helpers
// ---------------------------------------------------------------------------

/// Construct a fresh `ChannelState` for tests without spinning up an actor.
/// Uses the same wiring as `start_for_test` but returns the state directly.
pub fn initial_state_for_test(channel_id: String) -> ChannelState {
  let deps = TestDeps(channel_id: channel_id, discord_token: "")
  build_initial_state_for_test(deps, process.new_subject())
}

/// Build a state with a fake in-flight turn. Used to exercise the "busy"
/// path of `transition` without standing up real workers/monitors.
pub fn with_fake_in_flight_turn(state: ChannelState) -> ChannelState {
  let fake_turn = fresh_fake_turn(StreamWorker)
  ChannelState(..state, turn: Some(fake_turn))
}

/// Build a state with a fake vision-in-flight turn. Exercises the
/// `VisionComplete` / `VisionError` arms of `transition`.
pub fn with_fake_vision_turn(state: ChannelState) -> ChannelState {
  let fake_turn = fresh_fake_turn(VisionWorker)
  ChannelState(..state, turn: Some(fake_turn))
}

/// Build a state with a fake stream-in-flight turn. Exercises the
/// `StreamDelta` / `StreamReasoning` / `StreamComplete` arms of `transition`.
pub fn with_fake_stream_turn(state: ChannelState) -> ChannelState {
  let fake_turn = fresh_fake_turn(StreamWorker)
  ChannelState(..state, turn: Some(fake_turn))
}

/// Build a state with a fake turn that has two pending tool calls (`c1`,
/// `c2`) and is currently executing `c1`. Used to exercise sequential
/// tool-call execution in `ToolResult` transitions.
pub fn with_fake_two_tool_calls_turn(state: ChannelState) -> ChannelState {
  let call_a = llm.ToolCall(id: "c1", name: "tool_a", arguments: "{}")
  let call_b = llm.ToolCall(id: "c2", name: "tool_b", arguments: "{}")
  let fake_turn =
    TurnState(
      ..fresh_fake_turn(ToolWorker("tool_a", "c1")),
      accumulated_tool_calls: [call_a, call_b],
    )
  ChannelState(..state, turn: Some(fake_turn))
}

/// Build a state with a fake turn that has a single pending tool call (`c1`).
/// Used to exercise the "all tools resolved, advance to next LLM iteration"
/// branch of `ToolResult`.
pub fn with_fake_one_tool_call_turn(state: ChannelState) -> ChannelState {
  let call_a = llm.ToolCall(id: "c1", name: "tool_a", arguments: "{}")
  let fake_turn =
    TurnState(
      ..fresh_fake_turn(ToolWorker("tool_a", "c1")),
      accumulated_tool_calls: [call_a],
    )
  ChannelState(..state, turn: Some(fake_turn))
}

fn fresh_fake_turn(worker_kind: WorkerKind) -> TurnState {
  TurnState(
    kind: UserTurn(message_id: "fake", author_id: "fake"),
    discord_msg_id: "",
    started_at: 0,
    iteration: 0,
    worker_pid: process.self(),
    worker_monitor: None,
    worker_kind: worker_kind,
    accumulated_content: "",
    accumulated_tool_calls: [],
    pending_tool_results: dict.new(),
    new_messages: [],
    traces: [],
    messages_at_llm_call: [],
    stream_retry_count: 0,
    stream_stats: StreamStats(
      start_ms: 0,
      reasoning_count: 0,
      delta_count: 0,
      last_heartbeat_ms: 0,
    ),
    deadline_timer: None,
  )
}

