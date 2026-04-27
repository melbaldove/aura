import aura/acp/flare_manager
import aura/acp/transport
import aura/brain
import aura/channel_supervisor
import aura/clients/browser_runner
import aura/clients/discord_client
import aura/clients/llm_client
import aura/clients/skill_runner
import aura/cognitive_delivery
import aura/cognitive_worker
import aura/config
import aura/ctl
import aura/db
import aura/db_migration
import aura/discord/rest
import aura/event_ingest
import aura/integrations/supervisor as integrations_supervisor
import aura/mcp/pool as mcp_pool
import aura/memory
import aura/models
import aura/notification
import aura/poller
import aura/review_runner
import aura/scaffold
import aura/scheduler
import aura/skill
import aura/time
import aura/validator
import aura/xdg
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/otp/static_supervisor
import gleam/result
import gleam/string
import logging
import simplifile

/// Start the root supervision tree
pub fn start(
  global_config: config.GlobalConfig,
  paths: xdg.Paths,
) -> Result(process.Pid, String) {
  // 0. Migrate legacy workstreams/ → domains/ if needed
  migrate_directories(paths)

  // 1. Load SOUL.md
  let soul = case memory.read_file(xdg.soul_path(paths)) {
    Ok(content) -> content
    Error(_) -> "You are Aura, a helpful AI assistant."
  }

  // 2. Discover skills
  let all_skills = case skill.discover(xdg.skills_dir(paths)) {
    Ok(skills) -> skills
    Error(e) -> {
      logging.log(logging.Error, "[supervisor] Skill discovery failed: " <> e)
      []
    }
  }
  logging.log(
    logging.Info,
    "[supervisor] Discovered "
      <> int.to_string(list.length(all_skills))
      <> " skills",
  )

  // 3. Start database
  use db_subject <- result.try(
    db.start(xdg.db_path(paths))
    |> result.map_error(fn(e) { "Failed to start database: " <> e }),
  )
  logging.log(logging.Info, "[supervisor] Database started")

  // Migrate JSONL files if they exist
  case db_migration.migrate_jsonl(db_subject, paths.data) {
    Ok(0) -> logging.log(logging.Info, "[supervisor] No JSONL files to migrate")
    Ok(n) ->
      logging.log(
        logging.Info,
        "[supervisor] Migrated " <> int.to_string(n) <> " messages from JSONL",
      )
    Error(e) ->
      logging.log(logging.Error, "[supervisor] JSONL migration error: " <> e)
  }

  // 4. Resolve Discord channel name → ID mapping
  let channel_map = case
    rest.list_channels(global_config.discord.token, global_config.discord.guild)
  {
    Ok(channels) -> channels
    Error(e) -> {
      logging.log(
        logging.Error,
        "[supervisor] Failed to list Discord channels: " <> e,
      )
      []
    }
  }

  // 5. Load domain configs (no actors — brain handles all channels directly)
  use domain_info <- result.try(load_domain_configs(paths, channel_map))
  let #(brain_domains, domain_configs) = domain_info
  logging.log(
    logging.Info,
    "[supervisor] Domains: "
      <> string.join(list.map(brain_domains, fn(d) { d.name }), ", "),
  )

  let discord_client_val =
    discord_client.production(global_config.discord.token)

  // 5a. Start cognitive delivery, worker, and event_ingest actors.
  // event_ingest remains fire-and-forget; the cognitive worker observes only
  // successfully persisted event IDs, and delivery only sees validated
  // decisions after they are appended to the decision log.
  use default_channel_id <- result.try(resolve_channel_id(
    "discord.default_channel",
    global_config.discord.default_channel,
    channel_map,
  ))
  let delivery_targets = [
    cognitive_delivery.default_target(default_channel_id),
    ..list.map(brain_domains, fn(d) {
      cognitive_delivery.domain_target(d.name, d.channel_id)
    })
  ]
  let delivery_target_ids =
    cognitive_delivery.allowed_target_ids(delivery_targets)
  let assert Ok(delivery_started) =
    cognitive_delivery.start_with_history(
      paths,
      discord_client_val,
      delivery_targets,
      global_config.notifications.digest_windows,
      db_subject,
      None,
    )
  let delivery_subject = delivery_started.data
  logging.log(logging.Info, "[supervisor] Cognitive delivery started")

  use cognitive_llm_config <- result.try(
    models.build_llm_config(global_config.models.brain)
    |> result.map_error(fn(e) {
      "Failed to configure cognitive worker model: " <> e
    }),
  )
  let assert Ok(cognitive_started) =
    cognitive_worker.start_with_delivery(
      db_subject,
      paths,
      cognitive_llm_config,
      delivery_subject,
      delivery_target_ids,
      global_config.notifications.digest_windows,
    )
  let cognitive_subject = cognitive_started.data
  logging.log(logging.Info, "[supervisor] Cognitive worker started")

  let assert Ok(event_ingest_started) =
    event_ingest.start_with_cognitive(db_subject, Some(cognitive_subject))
  let event_ingest_subject = event_ingest_started.data
  logging.log(logging.Info, "[supervisor] Event ingest started")

  // 5. Load validation rules
  let validation_rules = case
    memory.read_file(xdg.config_path(paths, "validations.toml"))
  {
    Ok(content) -> {
      case validator.parse_rules(content) {
        Ok(rules) -> {
          logging.log(
            logging.Info,
            "[supervisor] Loaded "
              <> int.to_string(list.length(rules))
              <> " validation rules",
          )
          rules
        }
        Error(e) -> {
          logging.log(
            logging.Error,
            "[supervisor] Failed to parse validation rules: " <> e,
          )
          []
        }
      }
    }
    Error(_) -> {
      logging.log(
        logging.Info,
        "[supervisor] No validations.toml found, using no validation rules",
      )
      []
    }
  }

  // 5b. Start flare manager actor (with placeholder callback — brain not started yet)
  let acp_transport =
    transport.parse(
      global_config.acp_transport,
      global_config.acp_server_url,
      global_config.acp_agent_name,
      global_config.acp_command,
    )
  use flare_subject <- result.try(flare_manager.start(
    global_config.acp_global_max_concurrent,
    global_config.models.monitor,
    fn(_event) { Nil },
    acp_transport,
    db_subject,
  ))
  logging.log(logging.Info, "[supervisor] Flare manager started")

  // 6. Start channel_supervisor (sibling of brain under root supervisor)
  let assert Ok(channel_sup) = channel_supervisor.start()
  logging.log(logging.Info, "[supervisor] Channel supervisor started")

  // 6. Start brain (with flare_subject and channel_supervisor)
  let llm_client_val = llm_client.production()
  let skill_runner_val = skill_runner.production()
  let browser_runner_val = browser_runner.production()
  use brain_subject <- result.try(
    brain.start(brain.BrainConfig(
      global: global_config,
      paths: paths,
      soul: soul,
      domains: brain_domains,
      domain_configs: domain_configs,
      skill_infos: all_skills,
      validation_rules: validation_rules,
      db_subject: db_subject,
      acp_subject: flare_subject,
      discord: discord_client_val,
      llm: llm_client_val,
      skill_runner: skill_runner_val,
      browser_runner: browser_runner_val,
      channel_supervisor: channel_sup,
      review_runner: review_runner.default(),
    )),
  )
  logging.log(logging.Info, "[supervisor] Brain started")

  // 6b. Wire flare events to brain
  process.send(
    flare_subject,
    flare_manager.SetBrainCallback(fn(event) {
      process.send(brain_subject, brain.AcpEvent(event))
    }),
  )

  // 7. Start scheduler
  let schedules_path = xdg.config_path(paths, "schedules.toml")
  let on_finding = fn(finding: notification.Finding) {
    process.send(brain_subject, brain.HeartbeatFinding(finding))
  }
  let on_rekindle = fn(flare_id: String, context: String) {
    case flare_manager.rekindle(flare_subject, flare_id, context) {
      Ok(session_name) ->
        logging.log(
          logging.Info,
          "[scheduler] Rekindled flare " <> flare_id <> " -> " <> session_name,
        )
      Error(e) ->
        logging.log(
          logging.Info,
          "[scheduler] Failed to rekindle " <> flare_id <> ": " <> e,
        )
    }
  }
  case scheduler.start(schedules_path, all_skills, on_finding, on_rekindle) {
    Ok(scheduler_subject) -> {
      logging.log(logging.Info, "[supervisor] Scheduler started")
      process.send(brain_subject, brain.SetScheduler(scheduler_subject))
      process.send(scheduler_subject, scheduler.SetFlareSubject(flare_subject))

      // Configure dreaming schedule
      let dream_config =
        scheduler.DreamScheduleConfig(
          cron: global_config.dreaming_cron,
          model_spec: global_config.models.dream,
          paths: paths,
          db_subject: db_subject,
          domains: list.map(brain_domains, fn(d) { d.name }),
          budget_percent: global_config.dreaming_budget_percent,
          brain_context: global_config.brain_context,
        )
      process.send(scheduler_subject, scheduler.SetDreamConfig(dream_config))
    }
    Error(e) -> {
      logging.log(
        logging.Error,
        "[supervisor] Failed to start scheduler: " <> e,
      )
      Nil
    }
  }

  // 8. Start control socket for CLI commands
  case
    ctl.start(ctl.CtlContext(
      paths: paths,
      db_subject: db_subject,
      event_ingest_subject: event_ingest_subject,
      cognitive_subject: cognitive_subject,
      delivery_subject: Some(delivery_subject),
      domains: list.map(brain_domains, fn(d) { d.name }),
      dream_model: global_config.models.dream,
      dream_budget_percent: global_config.dreaming_budget_percent,
      brain_context: global_config.brain_context,
      started_at_ms: time.now_ms(),
    ))
  {
    Ok(_) -> Nil
    Error(e) ->
      logging.log(logging.Error, "[supervisor] Failed to start ctl: " <> e)
  }

  // 9. Start OTP supervisor with gateway + MCP pool as supervised children
  let discord_config = global_config.discord
  let result =
    static_supervisor.new(static_supervisor.OneForOne)
    |> static_supervisor.restart_tolerance(intensity: 10, period: 60)
    |> static_supervisor.add(poller.supervised(discord_config, brain_subject))
    |> static_supervisor.add(mcp_pool.supervised(global_config.mcp))
    |> static_supervisor.add(integrations_supervisor.supervised(
      event_ingest_subject,
      db_subject,
    ))
    |> static_supervisor.start

  case result {
    Ok(started) -> {
      logging.log(logging.Info, "Aura supervisor started")
      // Bootstrap initial integrations from config (runs after the
      // factory_supervisor is registered and ready for start_child).
      integrations_supervisor.bootstrap(global_config.integrations)
      Ok(started.pid)
    }
    Error(e) -> Error("Failed to start supervisor: " <> string.inspect(e))
  }
}

fn migrate_directories(paths: xdg.Paths) -> Nil {
  migrate_dir(
    paths.config <> "/workstreams",
    paths.config <> "/domains",
    "config",
  )
  migrate_dir(paths.data <> "/workstreams", paths.data <> "/domains", "data")
}

fn load_domain_configs(
  paths: xdg.Paths,
  channel_map: List(#(String, String)),
) -> Result(
  #(List(brain.DomainInfo), List(#(String, config.DomainConfig))),
  String,
) {
  case scaffold.list_domains(paths) {
    Error(_) -> Ok(#([], []))
    Ok(names) -> {
      use results <- result.try(
        names
        |> list.try_map(fn(name) {
          load_domain_config(paths, channel_map, name)
        }),
      )
      Ok(#(list.map(results, fn(r) { r.0 }), list.map(results, fn(r) { r.1 })))
    }
  }
}

fn load_domain_config(
  paths: xdg.Paths,
  channel_map: List(#(String, String)),
  name: String,
) -> Result(#(brain.DomainInfo, #(String, config.DomainConfig)), String) {
  let config_path = xdg.domain_config_path(paths, name)
  let agents_path = xdg.domain_config_dir(paths, name) <> "/AGENTS.md"
  case simplifile.is_file(agents_path) {
    Ok(True) -> Nil
    _ -> {
      let _ =
        simplifile.write(
          agents_path,
          "# " <> name <> "\n\nDomain-specific instructions go here.\n",
        )
      Nil
    }
  }

  use toml_content <- result.try(
    simplifile.read(config_path)
    |> result.map_error(fn(_) {
      "[supervisor] Failed to read config for domain " <> name
    }),
  )
  use cfg <- result.try(
    config.parse_domain(toml_content)
    |> result.map_error(fn(e) {
      "[supervisor] Failed to parse domain " <> name <> ": " <> e
    }),
  )
  use channel_id <- result.try(resolve_channel_id(
    "domain " <> name <> " discord.channel",
    cfg.discord_channel,
    channel_map,
  ))
  Ok(#(brain.DomainInfo(name: name, channel_id: channel_id), #(name, cfg)))
}

/// Resolve a configured Discord channel name to a numeric channel ID.
///
/// Numeric IDs are accepted directly. Names must be present in the channel map;
/// silently falling back to the unresolved name causes Discord sends to fail
/// later with opaque 400s.
pub fn resolve_channel_id(
  label: String,
  name_or_id: String,
  channel_map: List(#(String, String)),
) -> Result(String, String) {
  let raw = string.trim(name_or_id)
  let name = case string.starts_with(raw, "#") {
    True -> string.drop_start(raw, 1)
    False -> raw
  }

  case is_discord_snowflake(raw) {
    True -> Ok(raw)
    False ->
      case list.find(channel_map, fn(channel) { channel.0 == name }) {
        Ok(#(_, id)) -> Ok(id)
        Error(_) ->
          Error(
            "Configured Discord channel for "
            <> label
            <> " was not found: '"
            <> name_or_id
            <> "'. Use an existing text channel name or numeric channel ID. Available text channels: "
            <> available_channel_names(channel_map),
          )
      }
  }
}

fn is_discord_snowflake(value: String) -> Bool {
  let chars = string.to_graphemes(value)
  string.length(value) >= 17
  && string.length(value) <= 22
  && list.all(chars, is_digit)
}

fn is_digit(char: String) -> Bool {
  list.contains(["0", "1", "2", "3", "4", "5", "6", "7", "8", "9"], char)
}

fn available_channel_names(channel_map: List(#(String, String))) -> String {
  case channel_map {
    [] -> "(none discovered)"
    _ ->
      channel_map
      |> list.map(fn(channel) { channel.0 })
      |> list.sort(string.compare)
      |> string.join(", ")
  }
}

fn migrate_dir(from: String, to: String, label: String) -> Nil {
  case simplifile.rename(from, to) {
    Ok(_) ->
      logging.log(
        logging.Info,
        "[supervisor] Migrated "
          <> label
          <> "/workstreams → "
          <> label
          <> "/domains",
      )
    Error(_) -> Nil
  }
}
