//// Per-channel actor that runs turns concurrently with other channels.
//// Phase 1: types + skeleton. Phase 2+ adds the state machine.

import aura/brain_tools
import aura/conversation
import aura/discord
import aura/llm
import aura/notification
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Monitor, type Pid, type Subject, type Timer}
import gleam/option.{type Option}

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
