//// Per-channel actor that runs turns concurrently across channels.

import aura/acp/flare_manager
import aura/attachment
import aura/brain_tools
import aura/browser
import aura/clients/browser_runner
import aura/clients/discord_client
import aura/clients/llm_client
import aura/clients/skill_runner
import aura/compressor
import aura/conversation
import aura/db
import aura/discord
import aura/discord/message as discord_message
import aura/domain
import aura/llm
import aura/models
import aura/review
import aura/review_runner.{type ReviewRunner}
import aura/scheduler
import aura/shell
import aura/skill
import aura/structured_memory
import aura/system_prompt
import aura/time
import aura/tools
import aura/validator
import aura/vision
import aura/xdg
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Monitor, type Pid, type Subject, type Timer}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import gleam/string
import logging

// ---------------------------------------------------------------------------
// Worker spawn function aliases
// ---------------------------------------------------------------------------
//
// Workers import `ChannelMessage` from this module, which creates a cyclic
// dependency if we import the worker modules directly. Instead, the spawn
// functions are threaded in via `Deps` (same pattern as `LLMClient` etc.).

pub type StreamWorkerSpawn =
  fn(
    fn(llm.LlmConfig, List(llm.Message), List(llm.ToolDefinition), Pid) -> Nil,
    llm.LlmConfig,
    List(llm.Message),
    List(llm.ToolDefinition),
    Subject(ChannelMessage),
  ) ->
    Pid

pub type ToolWorkerSpawn =
  fn(brain_tools.ToolContext, llm.ToolCall, Subject(ChannelMessage)) -> Pid

pub type VisionWorkerSpawn =
  fn(
    fn(llm.LlmConfig, List(llm.Message), option.Option(Float)) ->
      Result(String, String),
    llm.LlmConfig,
    List(llm.Message),
    option.Option(Float),
    String,
    Subject(ChannelMessage),
  ) ->
    Pid

pub type ChannelMessage {
  HandleIncoming(discord.IncomingMessage)
  HandleHandback(flare_id: String, session_name: String, result: String)
  HandleInteraction(
    interaction_id: String,
    interaction_token: String,
    custom_id: String,
  )
  Cancel

  VisionComplete(filename: String, description: String)
  VisionError(reason: String)

  StreamDelta(text: String)
  StreamReasoning
  StreamComplete(content: String, tool_calls_json: String, prompt_tokens: Int)
  StreamError(reason: String)

  RetryStream(messages: List(llm.Message))

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
  HandleInteractionResolve(action: String, approval_id: String)
}

pub type TurnKind {
  UserTurn(message_id: String, author_id: String)
  HandbackTurn(flare_id: String, session_name: String)
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
    last_edit_len: Int,
  )
}

pub type PendingWork {
  PendingUserMessage(discord.IncomingMessage)
  PendingHandback(flare_id: String, session_name: String, result: String)
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
    paths: xdg.Paths,
    review_interval: Int,
    skill_review_interval: Int,
    notify_on_review: Bool,
    monitor_model: String,
    review_runner: ReviewRunner,
    llm_config: llm.LlmConfig,
    vision_config: llm.LlmConfig,
    resolved_vision_config: vision.ResolvedVisionConfig,
    built_in_tools: List(llm.ToolDefinition),
    stream_spawn: StreamWorkerSpawn,
    tool_spawn: ToolWorkerSpawn,
    vision_spawn: VisionWorkerSpawn,
    self_subject: Subject(ChannelMessage),
    brain_context: Int,
    soul: String,
    domain_names: List(String),
    compression_in_flight: Bool,
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
    guild_id: String,
    db_subject: process.Subject(db.DbMessage),
    acp_subject: process.Subject(flare_manager.FlareMsg),
    scheduler_subject: option.Option(process.Subject(scheduler.SchedulerMessage)),
    paths: xdg.Paths,
    domain: option.Option(String),
    review_interval: Int,
    skill_review_interval: Int,
    notify_on_review: Bool,
    monitor_model: String,
    review_runner: ReviewRunner,
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
    acp_provider: String,
    acp_binary: String,
    acp_worktree: Bool,
    acp_server_url: String,
    acp_agent_name: String,
    llm_config: llm.LlmConfig,
    vision_config: llm.LlmConfig,
    resolved_vision_config: vision.ResolvedVisionConfig,
    built_in_tools: List(llm.ToolDefinition),
    stream_spawn: StreamWorkerSpawn,
    tool_spawn: ToolWorkerSpawn,
    vision_spawn: VisionWorkerSpawn,
    brain_context: Int,
    soul: String,
    domain_names: List(String),
  )
}

/// Start a channel actor with production deps.
pub fn start(deps: Deps) -> Result(Subject(ChannelMessage), actor.StartError) {
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
      guild_id: deps.guild_id,
      message_id: "",
      channel_id: deps.channel_id,
      paths: deps.paths,
      skill_infos: deps.skill_infos,
      skills_dir: deps.skills_dir,
      validation_rules: deps.validation_rules,
      db_subject: deps.db_subject,
      scheduler_subject: deps.scheduler_subject,
      acp_subject: deps.acp_subject,
      domain_name: deps.domain_name,
      domain_cwd: deps.domain_cwd,
      acp_provider: deps.acp_provider,
      acp_binary: deps.acp_binary,
      acp_worktree: deps.acp_worktree,
      acp_server_url: deps.acp_server_url,
      acp_agent_name: deps.acp_agent_name,
      on_propose: fn(proposal) {
        process.send(self, RegisterProposal(proposal))
      },
      shell_patterns: shell.compile_patterns(),
      on_shell_approve: fn(approval) {
        process.send(self, RegisterShellApproval(approval))
      },
      vision_fn: {
        let rvc = deps.resolved_vision_config
        let llm_client = deps.llm_client
        fn(image_url: String, question: String) -> Result(String, String) {
          case vision.is_enabled(rvc) {
            False ->
              Error(
                "vision not configured (set [models] vision in config.toml)",
              )
            True -> {
              let cfg = case question {
                "" -> rvc
                q -> vision.ResolvedVisionConfig(..rvc, prompt: q)
              }
              vision.describe_via_client(llm_client, cfg, image_url)
            }
          }
        }
      },
      discord: deps.discord,
      llm_client: deps.llm_client,
      skill_runner: deps.skill_runner,
      browser_runner: deps.browser_runner,
    )
  let #(history, comp_state) =
    conversation.load_channel_bootstrap(
      deps.db_subject,
      platform,
      deps.channel_id,
      time.now_ms(),
    )
  ChannelState(
    channel_id: deps.channel_id,
    domain: deps.domain,
    conversation: history,
    compressor_state: comp_state,
    tool_ctx: tool_ctx,
    turn: None,
    queue: [],
    review_counts: #(0, 0),
    pending_proposals: [],
    pending_shell_approvals: [],
    typing_pid: None,
    discord_token: deps.discord_token,
    paths: deps.paths,
    review_interval: deps.review_interval,
    skill_review_interval: deps.skill_review_interval,
    notify_on_review: deps.notify_on_review,
    monitor_model: deps.monitor_model,
    review_runner: deps.review_runner,
    llm_config: deps.llm_config,
    vision_config: deps.vision_config,
    resolved_vision_config: deps.resolved_vision_config,
    built_in_tools: deps.built_in_tools,
    stream_spawn: deps.stream_spawn,
    tool_spawn: deps.tool_spawn,
    vision_spawn: deps.vision_spawn,
    self_subject: self,
    brain_context: deps.brain_context,
    soul: deps.soul,
    domain_names: deps.domain_names,
    compression_in_flight: False,
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
  // Start a real in-memory DB so load_channel_bootstrap can call into it
  // without blocking on a dead subject.
  let assert Ok(db_subject) = db.start(":memory:")
  let acp_subject = process.new_subject()
  Deps(
    channel_id: channel_id,
    discord_token: discord_token,
    guild_id: "",
    db_subject: db_subject,
    acp_subject: acp_subject,
    scheduler_subject: None,
    paths: paths,
    domain: None,
    review_interval: 0,
    skill_review_interval: 0,
    notify_on_review: False,
    monitor_model: "",
    review_runner: review_runner.default(),
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
    acp_provider: "claude-code",
    acp_binary: "",
    acp_worktree: True,
    acp_server_url: "",
    acp_agent_name: "",
    llm_config: dummy_llm_config(),
    vision_config: dummy_llm_config(),
    resolved_vision_config: vision.ResolvedVisionConfig(
      model_spec: "",
      prompt: "",
    ),
    built_in_tools: [],
    stream_spawn: dummy_stream_spawn,
    tool_spawn: dummy_tool_spawn,
    vision_spawn: dummy_vision_spawn,
    brain_context: 128_000,
    soul: "",
    domain_names: [],
  )
}

/// Dummy spawn functions for tests that never invoke them. The smoke-test
/// path only sends messages like `Cancel` / `TurnDeadline` which don't
/// traverse spawn effects.
fn dummy_stream_spawn(
  _fn: fn(llm.LlmConfig, List(llm.Message), List(llm.ToolDefinition), Pid) ->
    Nil,
  _config: llm.LlmConfig,
  _messages: List(llm.Message),
  _tools: List(llm.ToolDefinition),
  _parent: Subject(ChannelMessage),
) -> Pid {
  process.self()
}

fn dummy_tool_spawn(
  _ctx: brain_tools.ToolContext,
  _call: llm.ToolCall,
  _parent: Subject(ChannelMessage),
) -> Pid {
  process.self()
}

fn dummy_vision_spawn(
  _fn: fn(llm.LlmConfig, List(llm.Message), option.Option(Float)) ->
    Result(String, String),
  _config: llm.LlmConfig,
  _messages: List(llm.Message),
  _temperature: option.Option(Float),
  _filename: String,
  _parent: Subject(ChannelMessage),
) -> Pid {
  process.self()
}

/// Dummy LLM config for tests. Never reaches the network because smoke
/// tests never drive the actor through a real stream/vision spawn path.
fn dummy_llm_config() -> llm.LlmConfig {
  llm.LlmConfig(base_url: "", api_key: "", model: "")
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
    paths: xdg.resolve(),
    review_interval: 0,
    skill_review_interval: 0,
    notify_on_review: False,
    monitor_model: "",
    review_runner: review_runner.default(),
    llm_config: dummy_llm_config(),
    vision_config: dummy_llm_config(),
    resolved_vision_config: vision.ResolvedVisionConfig(
      model_spec: "",
      prompt: "",
    ),
    built_in_tools: [],
    stream_spawn: dummy_stream_spawn,
    tool_spawn: dummy_tool_spawn,
    vision_spawn: dummy_vision_spawn,
    self_subject: self,
    brain_context: 128_000,
    soul: "",
    domain_names: [],
    compression_in_flight: False,
  )
}

// ---------------------------------------------------------------------------
// Message handler
// ---------------------------------------------------------------------------

/// Call the pure `transition` to compute the next state and a list
/// of effects, then execute each effect. The actor only ever returns the
/// final state via `actor.continue`.
pub fn handle_message(
  state: ChannelState,
  message: ChannelMessage,
) -> actor.Next(ChannelState, ChannelMessage) {
  let #(new_state, effects) = transition(state, message)
  let executed_state = list.fold(effects, new_state, execute_effect)
  actor.continue(executed_state)
}

// ---------------------------------------------------------------------------
// Effect interpreter
// ---------------------------------------------------------------------------

pub fn execute_effect(state: ChannelState, effect: Effect) -> ChannelState {
  case effect {
    SpawnStreamWorker(messages) -> execute_spawn_stream_worker(state, messages)
    SpawnToolWorker(call) -> execute_spawn_tool_worker(state, call)
    SpawnVisionWorker(image_path, question, filename) ->
      execute_spawn_vision_worker(state, image_path, question, filename)
    KillWorker(pid) -> {
      process.kill(pid)
      state
    }
    CancelDeadline(timer) -> {
      let _ = process.cancel_timer(timer)
      state
    }
    ScheduleDeadline(ms) -> {
      let timer = process.send_after(state.self_subject, ms, TurnDeadline)
      update_deadline_timer(state, Some(timer))
    }
    DiscordEdit(msg_id, content) -> {
      case msg_id {
        "" -> {
          // No message id yet — fall back to sending a new message so the
          // user still sees the content. Update the turn's discord_msg_id
          // when the send succeeds.
          case
            state.tool_ctx.discord.send_message(
              state.channel_id,
              discord_message.clip_to_discord_limit(content),
            )
          {
            Ok(id) -> update_turn_msg_id(state, id)
            Error(_) -> state
          }
        }
        existing -> {
          let _ =
            state.tool_ctx.discord.edit_message(
              state.channel_id,
              existing,
              discord_message.clip_to_discord_limit(content),
            )
          state
        }
      }
    }
    DiscordSend(content) -> {
      let _ =
        state.tool_ctx.discord.send_message(
          state.channel_id,
          discord_message.clip_to_discord_limit(content),
        )
      state
    }
    DbSaveExchange(messages, author_id, author_name, _prompt_tokens) -> {
      let now = time.now_ms()
      case
        db.resolve_conversation(
          state.tool_ctx.db_subject,
          platform,
          state.channel_id,
          now,
        )
      {
        Ok(convo_id) -> {
          let _ =
            conversation.save_exchange_to_db(
              state.tool_ctx.db_subject,
              convo_id,
              messages,
              author_id,
              author_name,
              now,
            )
          Nil
        }
        Error(e) ->
          logging.log(
            logging.Info,
            "[channel "
              <> state.channel_id
              <> "] conversation resolve failed: "
              <> e,
          )
      }
      state
    }
    StopTyping(pid) -> {
      process.kill(pid)
      ChannelState(..state, typing_pid: None)
    }
    StartTyping -> {
      let pid = start_typing_loop(state)
      ChannelState(..state, typing_pid: Some(pid))
    }
    LogHeartbeat(stats, content_chars) -> {
      let now = time.now_ms()
      case now - stats.last_heartbeat_ms >= 30_000 {
        True -> {
          logging.log(
            logging.Info,
            "[channel "
              <> state.channel_id
              <> "] stream progress: "
              <> int.to_string(stats.reasoning_count)
              <> " reasoning, "
              <> int.to_string(stats.delta_count)
              <> " delta ("
              <> int.to_string(content_chars)
              <> " chars), "
              <> int.to_string({ now - stats.start_ms } / 1000)
              <> "s elapsed",
          )
          update_heartbeat(state, now)
        }
        False -> state
      }
    }
    LogStreamSummary(stats, outcome, content_chars) -> {
      let elapsed = { time.now_ms() - stats.start_ms } / 1000
      logging.log(
        logging.Info,
        "[channel "
          <> state.channel_id
          <> "] stream "
          <> outcome
          <> ": "
          <> int.to_string(stats.reasoning_count)
          <> " reasoning, "
          <> int.to_string(stats.delta_count)
          <> " delta ("
          <> int.to_string(content_chars)
          <> " chars), "
          <> int.to_string(elapsed)
          <> "s total",
      )
      state
    }
    SpawnSkillReview(history, new_iterations, current_count) -> {
      let resolved_domain = option.unwrap(state.domain, default_domain)
      let new_count =
        state.review_runner.skill_run(
          state.skill_review_interval,
          resolved_domain,
          state.channel_id,
          state.discord_token,
          history,
          current_count,
          new_iterations,
          state.paths,
          state.monitor_model,
          state.tool_ctx.skills_dir,
        )
      ChannelState(..state, review_counts: #(state.review_counts.0, new_count))
    }
    SpawnMemoryReview(history) -> {
      let resolved_domain = option.unwrap(state.domain, default_domain)
      let new_count =
        state.review_runner.run(
          state.review_interval,
          state.notify_on_review,
          resolved_domain,
          state.channel_id,
          state.discord_token,
          history,
          state.review_counts.0,
          state.paths,
          state.monitor_model,
        )
      ChannelState(..state, review_counts: #(new_count, state.review_counts.1))
    }
    ResolveProposal(proposal, action) ->
      resolve_approval(
        state,
        proposal.requested_at_ms,
        proposal.channel_id,
        proposal.message_id,
        proposal.reply_to,
        action,
        "**Expired** -- proposal timed out after 15 minutes.",
        fn() {
          case
            tools.write_file(
              proposal.path,
              state.paths.data,
              proposal.content,
              state.tool_ctx.validation_rules,
              True,
            )
          {
            Ok(_) -> #(
              brain_tools.Approved,
              "**Approved** -- wrote `" <> proposal.path <> "`",
            )
            Error(e) -> #(brain_tools.Rejected, "**Failed** -- " <> e)
          }
        },
        fn() { "**Rejected**" },
      )
    ResolveShellApproval(approval, action) ->
      resolve_approval(
        state,
        approval.requested_at_ms,
        approval.channel_id,
        approval.message_id,
        approval.reply_to,
        action,
        "**Expired** -- approval timed out after 15 minutes.",
        fn() {
          #(
            brain_tools.Approved,
            ":white_check_mark: **Approved** -- `" <> approval.command <> "`",
          )
        },
        fn() { ":x: **Rejected**" },
      )
    UpdateCompressorTokens(prompt_tokens) -> {
      case prompt_tokens > 0 {
        True -> {
          let new_cs =
            conversation.CompressorState(
              ..state.compressor_state,
              last_prompt_tokens: prompt_tokens,
            )
          ChannelState(..state, compressor_state: new_cs)
        }
        False -> state
      }
    }
    PruneToolOutputs -> {
      let #(pruned, count) =
        compressor.prune_tool_outputs(
          state.conversation,
          compressor.min_tail_messages,
        )
      case count > 0 {
        True ->
          logging.log(
            logging.Info,
            "[channel_actor] Tool pruning: cleared "
              <> int.to_string(count)
              <> " output(s) for "
              <> state.channel_id,
          )
        False -> Nil
      }
      ChannelState(..state, conversation: pruned)
    }
    ScheduleRetry(messages, delay_ms) -> {
      let _ = process.send_after(state.self_subject, delay_ms, RetryStream(messages))
      state
    }
    SpawnCompression(domain, history) -> {
      let snapshot_len = list.length(history)
      let paths = state.paths
      let db_subject = state.tool_ctx.db_subject
      let self = state.self_subject
      let llm_config = state.llm_config
      let comp_state = state.compressor_state
      let brain_context = state.brain_context
      let monitor_model = state.monitor_model
      let cache_key = platform <> ":" <> state.channel_id
      logging.log(
        logging.Info,
        "[channel_actor] Full compression triggered for " <> cache_key,
      )
      process.spawn_unlinked(fn() {
        // Read domain files in the spawned process, not the actor
        let #(a_md, s_md) = domain.load_context_files(paths, domain)
        // Flush memories before compression discards messages
        case models.build_llm_config(monitor_model) {
          Ok(monitor_llm_config) ->
            review.flush_before_compression(
              monitor_llm_config,
              history,
              domain,
              paths,
            )
          Error(e) ->
            logging.log(
              logging.Info,
              "[channel_actor] Flush skipped — monitor LLM config failed: " <> e,
            )
        }
        let #(new_history, new_comp_state) =
          conversation.compress_history(
            history,
            llm_config,
            comp_state,
            domain,
            a_md,
            s_md,
            db_subject,
            cache_key,
            brain_context,
          )
        process.send(
          self,
          CompressionComplete(new_history, new_comp_state, snapshot_len),
        )
      })
      ChannelState(..state, compression_in_flight: True)
    }
  }
}

/// Resolve a pending approval (proposal or shell). Handles the 15-minute
/// expiry check, dispatches to the caller's approve/reject callbacks, and
/// emits the appropriate Discord edit. Returns an updated ChannelState.
fn resolve_approval(
  state: ChannelState,
  requested_at_ms: Int,
  channel_id: String,
  message_id: String,
  reply_to: process.Subject(brain_tools.ProposalResult),
  action: String,
  expired_msg: String,
  on_approve: fn() -> #(brain_tools.ProposalResult, String),
  on_reject: fn() -> String,
) -> ChannelState {
  let now = time.now_ms()
  let expired = now - requested_at_ms > approval_expiry_ms
  case expired {
    True -> {
      process.send(reply_to, brain_tools.Expired)
      let _ =
        state.tool_ctx.discord.edit_message(channel_id, message_id, expired_msg)
      state
    }
    False ->
      case action {
        "approve" -> {
          let #(result, body) = on_approve()
          process.send(reply_to, result)
          let _ = state.tool_ctx.discord.edit_message(channel_id, message_id, body)
          state
        }
        _ -> {
          let body = on_reject()
          process.send(reply_to, brain_tools.Rejected)
          let _ = state.tool_ctx.discord.edit_message(channel_id, message_id, body)
          state
        }
      }
  }
}

fn execute_spawn_stream_worker(
  state: ChannelState,
  messages: List(llm.Message),
) -> ChannelState {
  // Prepend the assembled system prompt as a SystemMessage. This is done
  // here in the effect interpreter (not in the pure transition) so that the
  // flare_manager.list_sessions call doesn't break pure unit tests that use
  // stub acp_subject values.
  let domain_name = case state.tool_ctx.domain_name {
    "" -> option.None
    name -> option.Some(name)
  }
  let base_prompt = build_base_system_prompt(state)
  let system_prompt =
    assemble_system_prompt(
      base_prompt,
      domain_name,
      state.channel_id,
      state.tool_ctx.acp_subject,
    )
  let messages_with_system = [llm.SystemMessage(system_prompt), ..messages]
  let pid =
    state.stream_spawn(
      state.tool_ctx.llm_client.stream_with_tools,
      state.llm_config,
      messages_with_system,
      state.built_in_tools,
      state.self_subject,
    )
  let monitor = process.monitor(pid)
  update_turn_with_worker(state, pid, Some(monitor), StreamWorker)
}

fn execute_spawn_tool_worker(
  state: ChannelState,
  call: llm.ToolCall,
) -> ChannelState {
  let pid = state.tool_spawn(state.tool_ctx, call, state.self_subject)
  let monitor = process.monitor(pid)
  update_turn_with_worker(
    state,
    pid,
    Some(monitor),
    ToolWorker(call.name, call.id),
  )
}

fn execute_spawn_vision_worker(
  state: ChannelState,
  image_path: String,
  question: String,
  filename: String,
) -> ChannelState {
  let messages = [
    llm.UserMessageWithImage(content: question, image_url: image_path),
  ]
  let pid =
    state.vision_spawn(
      state.tool_ctx.llm_client.chat_text,
      state.vision_config,
      messages,
      None,
      filename,
      state.self_subject,
    )
  let monitor = process.monitor(pid)
  update_turn_with_worker(state, pid, Some(monitor), VisionWorker)
}

// ---------------------------------------------------------------------------
// Effect helpers
// ---------------------------------------------------------------------------

/// Apply `f` to the in-flight turn if present; no-op when idle. Every
/// effect-interpreter mutation of TurnState fields routes through here.
fn update_turn(
  state: ChannelState,
  f: fn(TurnState) -> TurnState,
) -> ChannelState {
  case state.turn {
    Some(turn) -> ChannelState(..state, turn: Some(f(turn)))
    None -> state
  }
}

fn update_turn_with_worker(
  state: ChannelState,
  pid: Pid,
  monitor: Option(Monitor),
  kind: WorkerKind,
) -> ChannelState {
  // Demonitor the prior worker's monitor ref if present, so stale DOWN
  // messages from superseded workers don't fire against the new worker.
  case state.turn {
    Some(turn) ->
      case turn.worker_monitor {
        Some(old_ref) -> {
          let _ = process.demonitor_process(old_ref)
          Nil
        }
        None -> Nil
      }
    None -> Nil
  }
  update_turn(state, fn(turn) {
    TurnState(
      ..turn,
      worker_pid: pid,
      worker_monitor: monitor,
      worker_kind: kind,
    )
  })
}

fn update_deadline_timer(
  state: ChannelState,
  timer: Option(Timer),
) -> ChannelState {
  update_turn(state, fn(turn) { TurnState(..turn, deadline_timer: timer) })
}

fn update_heartbeat(state: ChannelState, now_ms: Int) -> ChannelState {
  update_turn(state, fn(turn) {
    TurnState(
      ..turn,
      stream_stats: StreamStats(..turn.stream_stats, last_heartbeat_ms: now_ms),
    )
  })
}

fn update_turn_msg_id(state: ChannelState, msg_id: String) -> ChannelState {
  update_turn(state, fn(turn) { TurnState(..turn, discord_msg_id: msg_id) })
}

/// Spawn a typing-indicator loop on an unlinked process. Kill it to stop.
fn start_typing_loop(state: ChannelState) -> Pid {
  let discord = state.tool_ctx.discord
  let channel_id = state.channel_id
  process.spawn_unlinked(fn() { typing_loop(discord, channel_id) })
}

fn typing_loop(discord: discord_client.DiscordClient, channel_id: String) -> Nil {
  let _ = discord.trigger_typing(channel_id)
  process.sleep(8000)
  typing_loop(discord, channel_id)
}

// ---------------------------------------------------------------------------
// Effect type
// ---------------------------------------------------------------------------

/// Effects emitted by `transition`. The actor's effect interpreter
/// translates these into real side effects (spawn processes, edit Discord
/// messages, schedule timers).
pub type Effect {
  SpawnStreamWorker(messages: List(llm.Message))
  SpawnToolWorker(call: llm.ToolCall)
  SpawnVisionWorker(image_path: String, question: String, filename: String)
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
  SpawnSkillReview(
    history: List(llm.Message),
    new_iterations: Int,
    current_count: Int,
  )
  SpawnMemoryReview(history: List(llm.Message))
  ResolveProposal(proposal: brain_tools.PendingProposal, action: String)
  ResolveShellApproval(
    approval: brain_tools.PendingShellApproval,
    action: String,
  )
  UpdateCompressorTokens(prompt_tokens: Int)
  PruneToolOutputs
  SpawnCompression(domain: String, history: List(llm.Message))
  ScheduleRetry(messages: List(llm.Message), delay_ms: Int)
}

// ---------------------------------------------------------------------------
// Pure transition
// ---------------------------------------------------------------------------

/// Pure state-machine transition. Given current state and an incoming
/// message, return the next state and a list of effects for the interpreter
/// to execute. `HandleIncoming` queues when busy, starting a turn when idle.
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

    // --- vision results ---------------------------------------------
    VisionComplete(filename, description), Some(turn) -> {
      let enriched =
        enrich_messages_with_description(
          turn.messages_at_llm_call,
          filename,
          description,
        )
      let enriched_new =
        enrich_messages_with_description(turn.new_messages, filename, description)
      let new_turn =
        TurnState(
          ..turn,
          worker_kind: StreamWorker,
          messages_at_llm_call: enriched,
          new_messages: enriched_new,
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
    VisionComplete(_, _), None -> #(state, [])
    VisionError(_), None -> #(state, [])

    // --- stream deltas and reasoning -------------------------------
    StreamDelta(text), Some(turn) -> {
      let new_acc = turn.accumulated_content <> text
      let new_stats =
        StreamStats(
          ..turn.stream_stats,
          delta_count: turn.stream_stats.delta_count + 1,
        )
      let #(edit_effects, new_last_edit_len) = case
        should_progressive_edit(turn, new_acc)
      {
        True -> #(
          [
            DiscordEdit(
              turn.discord_msg_id,
              format_progress(new_acc, turn.traces),
            ),
          ],
          string.length(new_acc),
        )
        False -> #([], turn.last_edit_len)
      }
      let new_turn =
        TurnState(
          ..turn,
          accumulated_content: new_acc,
          stream_stats: new_stats,
          last_edit_len: new_last_edit_len,
        )
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

    // --- stream complete (terminal vs tool-call) -------------------
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

    // --- tool result sequencing ------------------------------------
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
            None -> {
              logging.log(
                logging.Error,
                "[channel "
                  <> state.channel_id
                  <> "] ToolResult inconsistency: not all resolved but no next unresolved found",
              )
              fail_turn_internal(state, turn, "tool_result inconsistency")
            }
          }
        }
        True -> {
          // Guard against runaway tool loops.
          case turn.iteration + 1 >= max_tool_iterations {
            True ->
              fail_turn_internal(
                state,
                turn,
                "Tool loop exceeded maximum iterations",
              )
            False -> {
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
              let next_llm_messages =
                list.append(state.conversation, new_messages)
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
      }
    }
    ToolResult(_, _, _), None -> #(state, [])

    // --- stream error retry ----------------------------------------
    StreamError(reason), Some(turn) -> {
      case turn.stream_retry_count < max_stream_retries {
        True -> {
          let new_retry = turn.stream_retry_count + 1
          let backoff_ms = case new_retry {
            1 -> 0
            2 -> 500
            _ -> 2000
          }
          let new_turn = TurnState(..turn, stream_retry_count: new_retry)
          #(ChannelState(..state, turn: Some(new_turn)), [
            ScheduleRetry(turn.messages_at_llm_call, backoff_ms),
            LogStreamSummary(
              turn.stream_stats,
              "retry-" <> int.to_string(new_retry),
              string.length(turn.accumulated_content),
            ),
          ])
        }
        False ->
          fail_turn_internal(
            state,
            turn,
            "stream exhausted retries: " <> reason,
          )
      }
    }
    StreamError(_), None -> #(state, [])

    // --- scheduled retry (non-blocking backoff) --------------------
    RetryStream(messages), Some(_) -> {
      // The backoff delay has already elapsed via send_after. Spawn the
      // worker directly — no further backoff here.
      #(state, [SpawnStreamWorker(messages)])
    }
    RetryStream(_), None -> #(state, [])

    // --- cancel + deadline -----------------------------------------
    Cancel, Some(turn) -> {
      let kill_effects = [
        KillWorker(turn.worker_pid),
        DiscordEdit(turn.discord_msg_id, "Cancelled by user"),
      ]
      let fail_effects = fail_turn_effects(state, turn, "cancelled")
      let #(cleared, deq_effects) = clear_and_dequeue(state)
      #(cleared, list.flatten([kill_effects, fail_effects, deq_effects]))
    }
    Cancel, None -> #(state, [])

    TurnDeadline, Some(turn) -> {
      let kill_effects = [
        KillWorker(turn.worker_pid),
        DiscordEdit(turn.discord_msg_id, "Turn exceeded 10-minute deadline"),
      ]
      let fail_effects = fail_turn_effects(state, turn, "deadline")
      let #(cleared, deq_effects) = clear_and_dequeue(state)
      #(cleared, list.flatten([kill_effects, fail_effects, deq_effects]))
    }
    TurnDeadline, None -> #(state, [])

    // --- compression complete -------------------------------------
    CompressionComplete(new_history, new_comp_state, snapshot_len), _ -> {
      // Merge: compressed history + any messages that arrived during compression.
      let current_len = list.length(state.conversation)
      let merged = case current_len > snapshot_len {
        True -> {
          // New messages arrived while compression was running — append the
          // delta to the compressed history so nothing is lost.
          let delta = list.drop(state.conversation, snapshot_len)
          let delta_len = list.length(delta)
          logging.log(
            logging.Info,
            "[channel_actor] Compression complete for "
              <> state.channel_id
              <> " (merging "
              <> int.to_string(delta_len)
              <> " new messages)",
          )
          list.append(new_history, delta)
        }
        False -> {
          logging.log(
            logging.Info,
            "[channel_actor] Compression complete for "
              <> state.channel_id
              <> " ("
              <> int.to_string(list.length(state.conversation))
              <> " → "
              <> int.to_string(list.length(new_history))
              <> " messages)",
          )
          new_history
        }
      }
      #(
        ChannelState(
          ..state,
          conversation: merged,
          compressor_state: new_comp_state,
          compression_in_flight: False,
        ),
        [],
      )
    }

    // --- worker down translation -----------------------------------
    WorkerDown(ref, reason), Some(turn) -> {
      case Some(ref) == turn.worker_monitor {
        False -> {
          // Stale DOWN from a superseded worker — ignore.
          #(state, [])
        }
        True -> {
          case reason {
            "normal" -> #(state, [])
            _ ->
              case turn.worker_kind {
                StreamWorker ->
                  transition(state, StreamError("worker crashed: " <> reason))
                ToolWorker(_, call_id) ->
                  transition(
                    state,
                    ToolResult(
                      call_id,
                      "Error: worker crashed: " <> reason,
                      True,
                    ),
                  )
                VisionWorker ->
                  transition(state, VisionError("crashed: " <> reason))
              }
          }
        }
      }
    }
    WorkerDown(_, _), None -> #(state, [])

    // --- handback ---------------------------------------------------
    HandleHandback(flare_id, session_name, result), None ->
      start_turn(state, PendingHandback(flare_id, session_name, result))
    HandleHandback(flare_id, session_name, result), Some(_) -> {
      let new_queue =
        list.append(state.queue, [
          PendingHandback(flare_id, session_name, result),
        ])
      #(ChannelState(..state, queue: new_queue), [])
    }

    // --- proposal / shell approval registration --------------------
    RegisterProposal(proposal), _ -> {
      // Supersede existing proposal for same channel
      let #(new_proposals, supersede_effects) = case
        list.find(state.pending_proposals, fn(p) {
          p.channel_id == proposal.channel_id
        })
      {
        Ok(old) -> {
          process.send(old.reply_to, brain_tools.Expired)
          let effects = [DiscordEdit(old.message_id, "~~Superseded~~")]
          let pruned =
            list.filter(state.pending_proposals, fn(p) { p.id != old.id })
          #(pruned, effects)
        }
        Error(_) -> #(state.pending_proposals, [])
      }
      let updated_proposals = list.append(new_proposals, [proposal])
      #(
        ChannelState(..state, pending_proposals: updated_proposals),
        supersede_effects,
      )
    }

    RegisterShellApproval(approval), _ -> {
      // Supersede existing shell approval for same channel
      let #(new_approvals, supersede_effects) = case
        list.find(state.pending_shell_approvals, fn(a) {
          a.channel_id == approval.channel_id
        })
      {
        Ok(old) -> {
          process.send(old.reply_to, brain_tools.Expired)
          let effects = [DiscordEdit(old.message_id, "~~Superseded~~")]
          let pruned =
            list.filter(state.pending_shell_approvals, fn(a) { a.id != old.id })
          #(pruned, effects)
        }
        Error(_) -> #(state.pending_shell_approvals, [])
      }
      let updated_approvals = list.append(new_approvals, [approval])
      #(
        ChannelState(..state, pending_shell_approvals: updated_approvals),
        supersede_effects,
      )
    }

    // --- interaction resolve (proposal or shell approval) ----------
    HandleInteractionResolve(action, approval_id), _ -> {
      case list.find(state.pending_proposals, fn(p) { p.id == approval_id }) {
        Ok(proposal) -> {
          let new_proposals =
            list.filter(state.pending_proposals, fn(p) { p.id != approval_id })
          #(ChannelState(..state, pending_proposals: new_proposals), [
            ResolveProposal(proposal, action),
          ])
        }
        Error(_) ->
          case
            list.find(state.pending_shell_approvals, fn(a) {
              a.id == approval_id
            })
          {
            Ok(approval) -> {
              let new_approvals =
                list.filter(state.pending_shell_approvals, fn(a) {
                  a.id != approval_id
                })
              #(ChannelState(..state, pending_shell_approvals: new_approvals), [
                ResolveShellApproval(approval, action),
              ])
            }
            Error(_) -> {
              logging.log(
                logging.Info,
                "[channel_actor] Unknown approval: " <> approval_id,
              )
              #(state, [])
            }
          }
      }
    }

    _, _ -> #(state, [])
  }
}

const max_stream_retries = 3

/// Maximum number of tool-call iterations per turn. Prevents runaway LLM tool
/// loops that could otherwise only be bounded by the 10-minute turn deadline.
const max_tool_iterations: Int = 80

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

/// Common failure path: emit user-facing error, optional typing stop,
/// optional deadline cancel, stream summary log, clear turn, and advance
/// the queue if non-empty.
fn fail_turn_internal(
  state: ChannelState,
  turn: TurnState,
  reason: String,
) -> #(ChannelState, List(Effect)) {
  let base = [
    DiscordSend("Error: " <> reason),
    LogStreamSummary(
      turn.stream_stats,
      "failed",
      string.length(turn.accumulated_content),
    ),
  ]
  let with_typing = case state.typing_pid {
    Some(pid) -> list.append(base, [StopTyping(pid)])
    None -> base
  }
  let effects = case turn.deadline_timer {
    Some(timer) -> list.append(with_typing, [CancelDeadline(timer)])
    None -> with_typing
  }
  let cleared = ChannelState(..state, turn: None, typing_pid: None)
  case state.queue {
    [] -> #(cleared, effects)
    [next, ..rest] -> {
      let #(new_state, start_effects) =
        start_turn(ChannelState(..cleared, queue: rest), next)
      #(new_state, list.append(effects, start_effects))
    }
  }
}

/// Side-effect list for a turn that failed for non-retry reasons (cancel,
/// deadline). Omits the Discord error message since the caller decides the
/// user-facing text.
fn fail_turn_effects(
  state: ChannelState,
  turn: TurnState,
  outcome: String,
) -> List(Effect) {
  let base = [
    LogStreamSummary(
      turn.stream_stats,
      outcome,
      string.length(turn.accumulated_content),
    ),
  ]
  let with_typing = case state.typing_pid {
    Some(pid) -> [StopTyping(pid), ..base]
    None -> base
  }
  case turn.deadline_timer {
    Some(timer) -> [CancelDeadline(timer), ..with_typing]
    None -> with_typing
  }
}

/// Clear the in-flight turn (and typing pid) and, if the queue is non-empty,
/// start the next turn. Returns the post-clear state plus any start effects
/// from the dequeued turn.
fn clear_and_dequeue(state: ChannelState) -> #(ChannelState, List(Effect)) {
  let cleared = ChannelState(..state, turn: None, typing_pid: None)
  case state.queue {
    [] -> #(cleared, [])
    [next, ..rest] -> start_turn(ChannelState(..cleared, queue: rest), next)
  }
}

fn start_turn(
  state: ChannelState,
  work: PendingWork,
) -> #(ChannelState, List(Effect)) {
  case work {
    PendingUserMessage(msg) -> {
      // Preprocess attachments synchronously: download to /tmp, inline text
      // file content. This enriches the user message content before it ever
      // reaches the LLM or is persisted. Best-effort — fails gracefully.
      let enriched_content = attachment.preprocess(msg)
      let user_msg = llm.UserMessage(content: enriched_content)
      let new_messages = [user_msg]
      let messages = list.append(state.conversation, new_messages)
      case has_image_attachment(msg) {
        True -> {
          // Prefer the local copy as a data URL to avoid Discord CDN HMAC
          // rejection. attachment.preprocess has already downloaded the file.
          let #(path, question, filename) =
            first_image_and_question(
              msg,
              state.resolved_vision_config.prompt,
            )
          #(state_with_pending_vision(state, messages, new_messages, msg), [
            SpawnVisionWorker(path, question, filename),
            StartTyping,
            ScheduleDeadline(600_000),
          ])
        }
        False -> #(
          state_with_pending_stream(state, messages, new_messages, msg),
          [SpawnStreamWorker(messages), StartTyping, ScheduleDeadline(600_000)],
        )
      }
    }
    PendingHandback(flare_id, session_name, result) -> {
      let handback_msg =
        "[Flare reported back: \"" <> session_name <> "\"]\n\n" <> result
      let handback_system = llm.SystemMessage(handback_msg)
      let new_messages = [handback_system]
      let messages = list.append(state.conversation, new_messages)
      let kind = HandbackTurn(flare_id, session_name)
      let turn = new_turn_state(kind, StreamWorker, messages, new_messages)
      #(ChannelState(..state, turn: Some(turn)), [
        SpawnStreamWorker(messages),
        StartTyping,
        ScheduleDeadline(600_000),
      ])
    }
  }
}

// ---------------------------------------------------------------------------
// Transition helpers
// ---------------------------------------------------------------------------

/// Build the base system prompt for channel_actor: soul + domain names +
/// skill infos + memory/user content + domain prompt (AGENTS.md/MEMORY.md/STATE.md)
/// + flare roster section. Called fresh on every turn so memory is always current.
fn build_base_system_prompt(state: ChannelState) -> String {
  let memory_content = case
    structured_memory.format_for_display(xdg.memory_path(state.paths))
  {
    Ok(c) -> c
    Error(_) -> ""
  }
  let user_content = case
    structured_memory.format_for_display(xdg.user_path(state.paths))
  {
    Ok(c) -> c
    Error(_) -> ""
  }
  let system_prompt_text =
    system_prompt.build_system_prompt(
      state.soul,
      state.domain_names,
      state.tool_ctx.skill_infos,
      memory_content,
      user_content,
    )

  let domain_prompt = case state.domain {
    Some(name) -> {
      let config_dir = xdg.domain_config_dir(state.paths, name)
      let data_dir = xdg.domain_data_dir(state.paths, name)
      let state_dir = xdg.domain_state_dir(state.paths, name)
      let ctx =
        domain.load_context(
          config_dir,
          data_dir,
          state_dir,
          state.tool_ctx.skill_infos,
        )
      "\n\n" <> domain.build_domain_prompt(ctx)
    }
    None -> ""
  }
  let base_with_domain = system_prompt_text <> domain_prompt

  // Build roster summary (active + parked flares)
  let flares = flare_manager.list_flares(state.tool_ctx.acp_subject)
  let active_flares =
    list.filter(flares, fn(f) { f.status == flare_manager.Active })
  let parked_flares =
    list.filter(flares, fn(f) { f.status == flare_manager.Parked })
  let roster_section = case
    list.length(active_flares) + list.length(parked_flares)
  {
    0 -> ""
    _ -> {
      let active_lines =
        list.map(active_flares, fn(f) {
          "- \""
          <> f.label
          <> "\" ("
          <> f.domain
          <> ") — active, session: "
          <> f.session_name
        })
      let parked_lines =
        list.map(parked_flares, fn(f) {
          "- \"" <> f.label <> "\" (" <> f.domain <> ") — parked"
        })
      "\n\n## Flare Roster"
      <> case active_lines {
        [] -> ""
        lines -> "\nActive:\n" <> string.join(lines, "\n")
      }
      <> case parked_lines {
        [] -> ""
        lines -> "\nParked:\n" <> string.join(lines, "\n")
      }
      <> "\n\nUse flare(action='rekindle', ...) to resume a parked flare. Use flare(action='ignite', ...) to start new work."
    }
  }
  base_with_domain <> roster_section
}

/// Assemble the full system prompt: base + fs_section + flare_context.
///
/// `base` is the base prompt from `build_base_system_prompt`. `fs_section`
/// describes XDG paths and the autonomy-tier policy. `flare_context` is
/// appended when `channel_id` matches an active flare's `thread_id`.
pub fn assemble_system_prompt(
  base: String,
  domain_name: option.Option(String),
  channel_id: String,
  acp_subject: process.Subject(flare_manager.FlareMsg),
) -> String {
  let fs_section =
    "\n\n## File System\n"
    <> "You can read any file. Use ~ for home directory.\n"
    <> "\nAura directories:"
    <> "\n  Config: ~/.config/aura/"
    <> "\n  Data: ~/.local/share/aura/"
    <> "\n  State: ~/.local/state/aura/"
    <> case domain_name {
      option.Some(name) ->
        "\n\nCurrent domain: "
        <> name
        <> "\n  Instructions: ~/.config/aura/domains/"
        <> name
        <> "/AGENTS.md"
        <> "\n  Config: ~/.config/aura/domains/"
        <> name
        <> "/config.toml"
        <> "\n  Memory: ~/.local/share/aura/domains/"
        <> name
        <> "/MEMORY.md"
        <> "\n  State: ~/.local/state/aura/domains/"
        <> name
        <> "/STATE.md"
        <> "\n  Repos: ~/.local/share/aura/domains/"
        <> name
        <> "/repos/"
      option.None -> ""
    }
    <> "\n\nWrites to logs, memory, state, and skills are autonomous."
    <> "\nAll other writes require approval -- use propose(path, content, description)."

  let flare_context = case
    list.find(flare_manager.list_sessions(acp_subject), fn(s) {
      s.thread_id == channel_id
    })
  {
    Ok(flare) ->
      "\n\n## Active Flare"
      <> "\nYou are in a flare thread."
      <> "\nSession: "
      <> flare.session_name
      <> "\nState: "
      <> flare_manager.status_to_string(flare.status)
      <> "\nDomain: "
      <> flare.domain
      <> "\nTask: "
      <> string.slice(flare.original_prompt, 0, 300)
      <> "\n\nUse flare(action='status', session_name='...') to check progress, flare(action='prompt', ...) to send instructions, flare(action='list') to see all flares."
    Error(_) -> ""
  }

  base <> fs_section <> flare_context
}

/// Build the message list to send to the LLM for this turn. Does NOT prepend
/// a SystemMessage here — that is added by the effect interpreter in
/// `execute_spawn_stream_worker`, which can safely call `flare_manager.list_sessions`
/// without breaking the purity of `transition`.
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
  prompt: String,
) -> #(String, String, String) {
  let first_att =
    list.find(msg.attachments, fn(att) { vision.is_image_attachment(att) })
  let #(url, filename) = case first_att {
    Error(_) -> #("", "")
    Ok(att) -> {
      // Prefer the local copy downloaded by attachment.preprocess as a
      // base64 data URL — Discord CDN URLs with HMAC query strings get
      // rejected by some vision endpoints (e.g. GLM returns 400 on them).
      let local = attachment.local_path(msg.message_id, att.filename)
      let resolved_url = case browser.read_as_data_url(local) {
        Ok(data_url) -> data_url
        Error(_) -> att.url
      }
      #(resolved_url, att.filename)
    }
  }
  let question = case prompt {
    "" -> "Describe this image in detail for downstream tool use."
    q -> q
  }
  #(url, question, filename)
}

fn new_turn_state(
  kind: TurnKind,
  worker_kind: WorkerKind,
  messages: List(llm.Message),
  initial_new_messages: List(llm.Message),
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
    new_messages: initial_new_messages,
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
    last_edit_len: 0,
  )
}

fn state_with_pending_vision(
  state: ChannelState,
  messages: List(llm.Message),
  new_messages: List(llm.Message),
  msg: discord.IncomingMessage,
) -> ChannelState {
  let kind = UserTurn(message_id: msg.message_id, author_id: msg.author_id)
  let turn = new_turn_state(kind, VisionWorker, messages, new_messages)
  ChannelState(..state, turn: Some(turn))
}

fn state_with_pending_stream(
  state: ChannelState,
  messages: List(llm.Message),
  new_messages: List(llm.Message),
  msg: discord.IncomingMessage,
) -> ChannelState {
  let kind = UserTurn(message_id: msg.message_id, author_id: msg.author_id)
  let turn = new_turn_state(kind, StreamWorker, messages, new_messages)
  ChannelState(..state, turn: Some(turn))
}

/// 15-minute expiry for proposals and shell approvals.
const approval_expiry_ms: Int = 900_000

/// Default domain name when a channel has no domain resolved (e.g. #aura).
const default_domain: String = "aura"

/// Platform identifier used for conversation keys and DB rows. Only "discord"
/// is supported today; Telegram/Slack would add more.
const platform: String = "discord"

/// Progressive-edit threshold: re-render the Discord message every N chars
/// of accumulated content.
const progressive_edit_chars: Int = 150

/// Prepend the vision description to the last `UserMessage` in the history.
/// Format: `"[Image <filename>: <description>]\n\n<original content>"`.
/// If there is no `UserMessage`, prepend a new one carrying just the
/// description so the stream worker still sees the context.
fn enrich_messages_with_description(
  messages: List(llm.Message),
  filename: String,
  description: String,
) -> List(llm.Message) {
  let prefix = "[Image " <> filename <> ": " <> description <> "]\n\n"
  let reversed = list.reverse(messages)
  case replace_last_user_message(reversed, prefix, []) {
    Ok(enriched) -> enriched
    Error(_) ->
      list.append(messages, [llm.UserMessage(content: prefix)])
  }
}

fn replace_last_user_message(
  reversed: List(llm.Message),
  prefix: String,
  acc_forward_suffix: List(llm.Message),
) -> Result(List(llm.Message), Nil) {
  case reversed {
    [] -> Error(Nil)
    [llm.UserMessage(content: original), ..rest] -> {
      let enriched = llm.UserMessage(content: prefix <> original)
      Ok(list.append(list.reverse(rest), [enriched, ..acc_forward_suffix]))
    }
    [other, ..rest] ->
      replace_last_user_message(rest, prefix, [other, ..acc_forward_suffix])
  }
}

/// Trigger a progressive edit every `progressive_edit_chars` characters of
/// newly accumulated content. Compares the current length against the length
/// at which the last edit was emitted, tracked on the turn state.
fn should_progressive_edit(turn: TurnState, new_acc: String) -> Bool {
  string.length(new_acc) - turn.last_edit_len > progressive_edit_chars
}

/// Format the in-progress message for Discord, mirroring how
/// `brain.collect_stream_loop` renders partial content.
fn format_progress(
  content: String,
  traces: List(conversation.ToolTrace),
) -> String {
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
  let #(author_id, author_name) = case turn.kind {
    UserTurn(_, aid) -> #(aid, "")
    HandbackTurn(_, _) -> #("aura", "Aura")
  }
  let full_history = list.append(state.conversation, final_messages)
  // Compute skill-review counter logic: reset to 0 when the current turn
  // included a skill_manage tool call (a fresh save makes review redundant),
  // otherwise increment by 1.
  let #(skill_review_count, new_skill_iterations) = case turn.traces {
    [] -> #(state.review_counts.1, 0)
    _ ->
      case list.any(turn.traces, fn(t) { t.name == "skill_manage" }) {
        True -> #(0, 0)
        False -> #(state.review_counts.1, 1)
      }
  }
  // Determine the effective token count for compression threshold checks:
  // use the real API-reported value if available, else fall back to the
  // last known value from state.
  let effective_tokens = case prompt_tokens > 0 {
    True -> prompt_tokens
    False -> state.compressor_state.last_prompt_tokens
  }
  // Resolve domain name for compression context loading.
  let resolved_domain = option.unwrap(state.domain, default_domain)
  // Emit compression effects after DbSaveExchange.
  // If a compression is already running, skip SpawnCompression to avoid
  // the concurrent-compression race (the in-flight process will complete
  // and clear the flag; the next turn can trigger if still needed).
  let compression_effects = case state.compression_in_flight {
    True -> []
    False ->
      case
        conversation.needs_full_compression(
          full_history,
          state.brain_context,
          effective_tokens,
        )
      {
        True -> [SpawnCompression(resolved_domain, full_history)]
        False ->
          case
            conversation.needs_tool_pruning(
              full_history,
              state.brain_context,
              effective_tokens,
            )
          {
            True -> [PruneToolOutputs]
            False -> []
          }
      }
  }
  let base_effects = [
    DiscordEdit(
      turn.discord_msg_id,
      conversation.format_full_message(turn.traces, content),
    ),
    DbSaveExchange(final_messages, author_id, author_name, prompt_tokens),
    UpdateCompressorTokens(prompt_tokens),
    ..compression_effects
  ]
  let base_with_reviews =
    list.append(base_effects, [
      SpawnMemoryReview(full_history),
      SpawnSkillReview(full_history, new_skill_iterations, skill_review_count),
      LogStreamSummary(turn.stream_stats, "complete", string.length(content)),
    ])
  let with_typing = case state.typing_pid {
    Some(pid) -> list.append(base_with_reviews, [StopTyping(pid)])
    None -> base_with_reviews
  }
  let with_deadline = case turn.deadline_timer {
    Some(timer) -> list.append(with_typing, [CancelDeadline(timer)])
    None -> with_typing
  }
  let cleared =
    ChannelState(
      ..state,
      turn: None,
      typing_pid: None,
      conversation: full_history,
    )
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

/// Build a state with a fake turn that has a single pending tool call (`c1`)
/// and the iteration counter pre-set to `n`. Used to exercise the max tool
/// iterations guard in `ToolResult` transitions.
pub fn with_fake_one_tool_call_turn_at_iteration(
  state: ChannelState,
  n: Int,
) -> ChannelState {
  let call_a = llm.ToolCall(id: "c1", name: "tool_a", arguments: "{}")
  let fake_turn =
    TurnState(
      ..fresh_fake_turn(ToolWorker("tool_a", "c1")),
      accumulated_tool_calls: [call_a],
      iteration: n,
    )
  ChannelState(..state, turn: Some(fake_turn))
}

/// Build a state with a fake stream turn whose retry counter has been
/// pre-incremented to `n`. Used to exercise retry-exhaustion paths in
/// `StreamError` transitions.
pub fn with_fake_stream_turn_at_retry(
  state: ChannelState,
  n: Int,
) -> ChannelState {
  let fake_turn =
    TurnState(..fresh_fake_turn(StreamWorker), stream_retry_count: n)
  ChannelState(..state, turn: Some(fake_turn))
}

/// Construct a fake monitor ref by monitoring the current process. Used in
/// `WorkerDown` tests where we need a real `Monitor` value but don't care
/// which process it refers to.
pub fn fake_monitor_ref() -> Monitor {
  process.monitor(process.self())
}

/// Build a state with a fake handback-in-flight turn. Used to exercise
/// the `HandbackTurn` path of `finalize_turn` and `DbSaveExchange` author
/// attribution.
pub fn with_fake_handback_turn(
  state: ChannelState,
  flare_id: String,
) -> ChannelState {
  let fake_turn =
    TurnState(
      ..fresh_fake_turn(StreamWorker),
      kind: HandbackTurn(flare_id, "fake-session"),
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
    last_edit_len: 0,
  )
}

/// Public wrapper for `enrich_messages_with_description` for regression tests.
pub fn enrich_messages_with_description_pub(
  messages: List(llm.Message),
  filename: String,
  description: String,
) -> List(llm.Message) {
  enrich_messages_with_description(messages, filename, description)
}

/// Build a state with a fake stream turn whose worker_monitor is set to `ref`.
/// Used to test WorkerDown ref-matching logic.
pub fn with_fake_stream_turn_monitored(
  state: ChannelState,
  ref: Monitor,
) -> ChannelState {
  let fake_turn =
    TurnState(..fresh_fake_turn(StreamWorker), worker_monitor: Some(ref))
  ChannelState(..state, turn: Some(fake_turn))
}
