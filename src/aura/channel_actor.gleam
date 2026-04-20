//// Per-channel actor that runs turns concurrently with other channels.
//// Phase 1: types + skeleton. Phase 2+ adds the state machine.

import aura/acp/flare_manager
import aura/brain_tools
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
import aura/notification
import aura/review
import aura/review_runner.{type ReviewRunner}
import aura/shell
import aura/skill
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
    Subject(ChannelMessage),
  ) ->
    Pid

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
  HandleInteractionResolve(action: String, approval_id: String)
}

pub type TurnKind {
  UserTurn(message_id: String, author_id: String)
  HandbackTurn(flare_id: String, result: String)
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
    last_edit_len: Int,
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
    paths: xdg.Paths,
    review_interval: Int,
    skill_review_interval: Int,
    notify_on_review: Bool,
    monitor_model: String,
    review_runner: ReviewRunner,
    llm_config: llm.LlmConfig,
    vision_config: llm.LlmConfig,
    built_in_tools: List(llm.ToolDefinition),
    stream_spawn: StreamWorkerSpawn,
    tool_spawn: ToolWorkerSpawn,
    vision_spawn: VisionWorkerSpawn,
    self_subject: Subject(ChannelMessage),
    brain_context: Int,
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
    llm_config: llm.LlmConfig,
    vision_config: llm.LlmConfig,
    built_in_tools: List(llm.ToolDefinition),
    stream_spawn: StreamWorkerSpawn,
    tool_spawn: ToolWorkerSpawn,
    vision_spawn: VisionWorkerSpawn,
    brain_context: Int,
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
      on_propose: fn(proposal) {
        process.send(self, RegisterProposal(proposal))
      },
      shell_patterns: shell.compile_patterns(),
      on_shell_approve: fn(approval) {
        process.send(self, RegisterShellApproval(approval))
      },
      vision_fn: fn(_url, _question) { Error("stub") },
      discord: deps.discord,
      llm_client: deps.llm_client,
      skill_runner: deps.skill_runner,
      browser_runner: deps.browser_runner,
    )
  let #(history, comp_state) =
    conversation.load_channel_bootstrap(
      deps.db_subject,
      "discord",
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
    built_in_tools: deps.built_in_tools,
    stream_spawn: deps.stream_spawn,
    tool_spawn: deps.tool_spawn,
    vision_spawn: deps.vision_spawn,
    self_subject: self,
    brain_context: deps.brain_context,
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
    db_subject: db_subject,
    acp_subject: acp_subject,
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
    llm_config: dummy_llm_config(),
    vision_config: dummy_llm_config(),
    built_in_tools: [],
    stream_spawn: dummy_stream_spawn,
    tool_spawn: dummy_tool_spawn,
    vision_spawn: dummy_vision_spawn,
    brain_context: 128_000,
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
    built_in_tools: [],
    stream_spawn: dummy_stream_spawn,
    tool_spawn: dummy_tool_spawn,
    vision_spawn: dummy_vision_spawn,
    self_subject: self,
    brain_context: 128_000,
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
    SpawnVisionWorker(image_path, question) ->
      execute_spawn_vision_worker(state, image_path, question)
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
          case state.tool_ctx.discord.send_message(
            state.channel_id,
            discord_message.clip_to_discord_limit(content),
          ) {
            Ok(id) -> update_turn_msg_id(state, id)
            Error(_) -> state
          }
        }
        existing -> {
          let _ = state.tool_ctx.discord.edit_message(
            state.channel_id,
            existing,
            discord_message.clip_to_discord_limit(content),
          )
          state
        }
      }
    }
    DiscordSend(content) -> {
      let _ = state.tool_ctx.discord.send_message(
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
          "discord",
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
      let resolved_domain = option.unwrap(state.domain, "aura")
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
      let resolved_domain = option.unwrap(state.domain, "aura")
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
    ResolveProposal(proposal, action) -> {
      let now = time.now_ms()
      let expired = now - proposal.requested_at_ms > 900_000
      case expired {
        True -> {
          logging.log(
            logging.Info,
            "[channel_actor] Proposal expired: " <> proposal.id,
          )
          process.send(proposal.reply_to, brain_tools.Expired)
          let _ =
            state.tool_ctx.discord.edit_message(
              proposal.channel_id,
              proposal.message_id,
              "**Expired** -- proposal timed out after 15 minutes.",
            )
          state
        }
        False ->
          case action {
            "approve" -> {
              case
                tools.write_file(
                  proposal.path,
                  state.paths.data,
                  proposal.content,
                  state.tool_ctx.validation_rules,
                  True,
                )
              {
                Ok(_) -> {
                  process.send(proposal.reply_to, brain_tools.Approved)
                  let _ =
                    state.tool_ctx.discord.edit_message(
                      proposal.channel_id,
                      proposal.message_id,
                      "**Approved** -- wrote `" <> proposal.path <> "`",
                    )
                  state
                }
                Error(e) -> {
                  process.send(proposal.reply_to, brain_tools.Rejected)
                  let _ =
                    state.tool_ctx.discord.edit_message(
                      proposal.channel_id,
                      proposal.message_id,
                      "**Failed** -- " <> e,
                    )
                  state
                }
              }
            }
            _ -> {
              // "reject" or anything else
              process.send(proposal.reply_to, brain_tools.Rejected)
              let _ =
                state.tool_ctx.discord.edit_message(
                  proposal.channel_id,
                  proposal.message_id,
                  "**Rejected**",
                )
              state
            }
          }
      }
    }
    ResolveShellApproval(approval, action) -> {
      let now = time.now_ms()
      let expired = now - approval.requested_at_ms > 900_000
      case expired {
        True -> {
          process.send(approval.reply_to, brain_tools.Expired)
          let _ =
            state.tool_ctx.discord.edit_message(
              approval.channel_id,
              approval.message_id,
              "**Expired** -- approval timed out after 15 minutes.",
            )
          state
        }
        False ->
          case action {
            "approve" -> {
              process.send(approval.reply_to, brain_tools.Approved)
              let _ =
                state.tool_ctx.discord.edit_message(
                  approval.channel_id,
                  approval.message_id,
                  ":white_check_mark: **Approved** -- `" <> approval.command <> "`",
                )
              state
            }
            _ -> {
              // "reject" or anything else
              process.send(approval.reply_to, brain_tools.Rejected)
              let _ =
                state.tool_ctx.discord.edit_message(
                  approval.channel_id,
                  approval.message_id,
                  ":x: **Rejected**",
                )
              state
            }
          }
      }
    }
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
    SpawnCompression(domain, history) -> {
      let snapshot_len = list.length(history)
      let paths = state.paths
      let db_subject = state.tool_ctx.db_subject
      let self = state.self_subject
      let llm_config = state.llm_config
      let comp_state = state.compressor_state
      let brain_context = state.brain_context
      let monitor_model = state.monitor_model
      let cache_key = "discord:" <> state.channel_id
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
      state
    }
  }
}

fn execute_spawn_stream_worker(
  state: ChannelState,
  messages: List(llm.Message),
) -> ChannelState {
  // If this is a retry, apply exponential backoff before spawning. The
  // transition has already incremented stream_retry_count, so 1 = first
  // retry (0ms), 2 = second (500ms), 3+ = 2s.
  let backoff_ms = case state.turn {
    Some(turn) ->
      case turn.stream_retry_count {
        0 -> 0
        1 -> 0
        2 -> 500
        _ -> 2000
      }
    None -> 0
  }
  case backoff_ms > 0 {
    True -> process.sleep(backoff_ms)
    False -> Nil
  }
  // Prepend the assembled system prompt as a SystemMessage. This is done
  // here in the effect interpreter (not in the pure transition) so that the
  // flare_manager.list_sessions call doesn't break pure unit tests that use
  // stub acp_subject values.
  let domain_name = case state.tool_ctx.domain_name {
    "" -> option.None
    name -> option.Some(name)
  }
  let system_prompt =
    assemble_system_prompt(
      "",
      domain_name,
      state.channel_id,
      state.tool_ctx.acp_subject,
    )
  // For handback turns, append the handback system message after history.
  // Resolve session_name by looking up the flare by id; fall back to flare_id.
  let messages_with_system =
    case state.turn {
      Some(TurnState(kind: HandbackTurn(flare_id, result), ..)) -> {
        let session_name =
          case
            list.find(
              flare_manager.list_sessions(state.tool_ctx.acp_subject),
              fn(s) { s.id == flare_id },
            )
          {
            Ok(s) -> s.session_name
            Error(_) -> flare_id
          }
        let handback_msg =
          "[Flare reported back: \""
          <> session_name
          <> "\"]\n\n"
          <> result
        list.flatten([
          [llm.SystemMessage(system_prompt)],
          messages,
          [llm.SystemMessage(handback_msg)],
        ])
      }
      _ -> [llm.SystemMessage(system_prompt), ..messages]
    }
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

fn typing_loop(
  discord: discord_client.DiscordClient,
  channel_id: String,
) -> Nil {
  let _ = discord.trigger_typing(channel_id)
  process.sleep(8000)
  typing_loop(discord, channel_id)
}

// ---------------------------------------------------------------------------
// Effect type
// ---------------------------------------------------------------------------

/// Effects emitted by `transition`. The actor's effect interpreter
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
}

// ---------------------------------------------------------------------------
// Pure transition
// ---------------------------------------------------------------------------

/// Pure state-machine transition. Given current state and an incoming
/// message, return the next state and a list of effects for the interpreter
/// to execute. `HandleIncoming` queues when busy,
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

    // --- vision results ---------------------------------------------
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

    // --- stream deltas and reasoning -------------------------------
    StreamDelta(text), Some(turn) -> {
      let new_acc = turn.accumulated_content <> text
      let new_stats =
        StreamStats(
          ..turn.stream_stats,
          delta_count: turn.stream_stats.delta_count + 1,
        )
      let #(edit_effects, new_last_edit_len) =
        case should_progressive_edit(turn, new_acc) {
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

    // --- stream error retry ----------------------------------------
    StreamError(reason), Some(turn) -> {
      case turn.stream_retry_count < max_stream_retries {
        True -> {
          let new_retry = turn.stream_retry_count + 1
          let new_turn = TurnState(..turn, stream_retry_count: new_retry)
          #(ChannelState(..state, turn: Some(new_turn)), [
            SpawnStreamWorker(turn.messages_at_llm_call),
            LogStreamSummary(
              turn.stream_stats,
              "retry-" <> int.to_string(new_retry),
              string.length(turn.accumulated_content),
            ),
          ])
        }
        False ->
          fail_turn_internal(state, turn, "stream exhausted retries: " <> reason)
      }
    }
    StreamError(_), None -> #(state, [])

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
      // Mirrors brain.gleam:693-730.
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
        ),
        [],
      )
    }

    // --- worker down translation -----------------------------------
    WorkerDown(_ref, reason), Some(turn) -> {
      case reason {
        "normal" -> #(state, [])
        _ ->
          case turn.worker_kind {
            StreamWorker ->
              transition(state, StreamError("worker crashed: " <> reason))
            ToolWorker(_, call_id) ->
              transition(
                state,
                ToolResult(call_id, "Error: worker crashed: " <> reason, True),
              )
            VisionWorker ->
              transition(state, VisionError("crashed: " <> reason))
          }
      }
    }
    WorkerDown(_, _), None -> #(state, [])

    // --- handback ---------------------------------------------------
    HandleHandback(flare_id, result), None ->
      start_turn(state, PendingHandback(flare_id, result))
    HandleHandback(flare_id, result), Some(_) -> {
      let new_queue =
        list.append(state.queue, [PendingHandback(flare_id, result)])
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
          #(
            ChannelState(..state, pending_proposals: new_proposals),
            [ResolveProposal(proposal, action)],
          )
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
              #(
                ChannelState(..state, pending_shell_approvals: new_approvals),
                [ResolveShellApproval(approval, action)],
              )
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
fn clear_and_dequeue(
  state: ChannelState,
) -> #(ChannelState, List(Effect)) {
  let cleared = ChannelState(..state, turn: None, typing_pid: None)
  case state.queue {
    [] -> #(cleared, [])
    [next, ..rest] ->
      start_turn(ChannelState(..cleared, queue: rest), next)
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
    PendingHandback(flare_id, result) -> {
      // Build messages from current conversation history. The handback system
      // message is injected in execute_spawn_stream_worker (effect interpreter)
      // so that the flare_manager.list_sessions call stays out of pure transition.
      let messages = state.conversation
      let kind = HandbackTurn(flare_id, result)
      let turn = new_turn_state(kind, StreamWorker, messages)
      #(ChannelState(..state, turn: Some(turn)), [
        SpawnStreamWorker(messages),
        StartTyping,
        ScheduleDeadline(600_000),
      ])
    }

    _ -> #(state, [])
  }
}

// ---------------------------------------------------------------------------
// Transition helpers
// ---------------------------------------------------------------------------

/// Assemble the full system prompt: base + fs_section + flare_context.
///
/// `base` is whatever base system prompt the caller has already built (e.g.
/// from a future `build_llm_context` port — currently empty string until that
/// task lands). `fs_section` describes XDG paths and the autonomy-tier policy.
/// `flare_context` is appended when `channel_id` matches an active flare's
/// `thread_id`.
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

  let flare_context =
    case
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
    last_edit_len: 0,
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
/// newly accumulated content. Compares the current length against the length
/// at which the last edit was emitted, tracked on the turn state.
fn should_progressive_edit(turn: TurnState, new_acc: String) -> Bool {
  string.length(new_acc) - turn.last_edit_len > progressive_edit_chars
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
  let #(author_id, author_name) = case turn.kind {
    UserTurn(_, aid) -> #(aid, "")
    HandbackTurn(_, _) -> #("aura", "Aura")
    FindingTurn(_) -> #("aura", "Aura")
  }
  let full_history = list.append(state.conversation, final_messages)
  // Compute skill-review counter logic: reset to 0 when the current turn
  // included a skill_manage tool call (a fresh save makes review redundant),
  // otherwise increment by 1. Mirrors brain.gleam:1998-2005.
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
  let resolved_domain = option.unwrap(state.domain, "aura")
  // Emit compression effects after DbSaveExchange, mirroring brain's
  // StoreExchange handler (brain.gleam:561-691).
  let compression_effects = case
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
  let base_effects = [
    DiscordEdit(turn.discord_msg_id, format_progress(content, turn.traces)),
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
    TurnState(..fresh_fake_turn(StreamWorker), kind: HandbackTurn(flare_id, "result"))
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

