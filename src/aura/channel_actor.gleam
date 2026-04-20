//// Per-channel actor that runs turns concurrently with other channels.
//// Phase 1: types + skeleton. Phase 2+ adds the state machine.

import aura/brain_tools
import aura/clients/browser_runner
import aura/clients/discord_client
import aura/clients/llm_client
import aura/clients/skill_runner
import aura/conversation
import aura/discord
import aura/llm
import aura/notification
import aura/shell
import aura/xdg
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Monitor, type Pid, type Subject, type Timer}
import gleam/option.{type Option, None}
import gleam/otp/actor
import gleam/result

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
    worker_monitor: Monitor,
    worker_kind: WorkerKind,
    accumulated_content: String,
    accumulated_tool_calls: List(llm.ToolCall),
    pending_tool_results: Dict(String, #(String, Bool)),
    new_messages: List(llm.Message),
    traces: List(conversation.ToolTrace),
    messages_at_llm_call: List(llm.Message),
    stream_retry_count: Int,
    stream_stats: StreamStats,
    deadline_timer: Timer,
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
// Test construction
// ---------------------------------------------------------------------------

/// Minimal deps for test-only actor construction.
pub type TestDeps {
  TestDeps(channel_id: String, discord_token: String)
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

