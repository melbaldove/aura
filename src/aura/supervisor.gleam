import aura/acp/flare_manager
import aura/acp/transport
import aura/blather/poller as blather_poller
import aura/blather/types as blather_types
import aura/brain
import aura/channel_supervisor
import aura/clients/blather as blather_client
import aura/clients/browser_runner
import aura/clients/discord as discord_client
import aura/clients/llm_client
import aura/clients/skill_runner
import aura/cognitive_delivery
import aura/cognitive_worker
import aura/config
import aura/connector_runtime
import aura/core_supervision
import aura/ctl
import aura/db
import aura/db_migration
import aura/discord
import aura/discord/rest
import aura/event_ingest
import aura/external_asks
import aura/google_oauth_runtime
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
import gleam/dict
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/otp/actor
import gleam/otp/static_supervisor
import gleam/otp/supervision
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

  // 3. Resolve Discord channel name → ID mapping
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
  let discord_domains =
    list.filter(brain_domains, fn(d) { d.platform == discord.platform_name })
  logging.log(
    logging.Info,
    "[supervisor] Domains: "
      <> string.join(list.map(domain_configs, fn(dc) { dc.0 }), ", "),
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
    ..list.map(discord_domains, fn(d) {
      cognitive_delivery.domain_target(d.name, d.channel_id)
    })
  ]
  let delivery_target_ids =
    cognitive_delivery.allowed_target_ids(delivery_targets)
  use cognitive_llm_config <- result.try(
    models.build_llm_config_with_codex_reasoning_effort(
      global_config.models.brain,
      global_config.models.codex_reasoning_effort,
    )
    |> result.map_error(fn(e) {
      "Failed to configure cognitive worker model: " <> e
    }),
  )
  let app_id = case rest.get_application_id(global_config.discord.token) {
    Ok(id) -> id
    Error(err) -> {
      logging.log(
        logging.Error,
        "[supervisor] Failed to resolve application id for ask edits: " <> err,
      )
      ""
    }
  }

  let db_name = process.new_name("aura_database")
  let delivery_name = process.new_name("aura_cognitive_delivery")
  let cognitive_name = process.new_name("aura_cognitive_worker")
  let event_ingest_name = process.new_name("aura_event_ingest")
  let asks_name = process.new_name("aura_external_asks")
  let flare_name = process.new_name("aura_flare_manager")
  let channel_supervisor_name = process.new_name("aura_channel_supervisor")
  let brain_name = process.new_name("aura_brain")
  let scheduler_name = process.new_name("aura_scheduler")
  let connector_runtime_name = process.new_name("aura_connector_runtime")
  let google_oauth_runtime_name = process.new_name("aura_google_oauth_runtime")

  let db_subject = process.named_subject(db_name)
  let delivery_subject = process.named_subject(delivery_name)
  let cognitive_subject = process.named_subject(cognitive_name)
  let event_ingest_subject = process.named_subject(event_ingest_name)
  let asks_subject = process.named_subject(asks_name)
  let flare_subject = process.named_subject(flare_name)
  let channel_sup = process.named_subject(channel_supervisor_name)
  let brain_subject = process.named_subject(brain_name)
  let scheduler_subject = process.named_subject(scheduler_name)
  let connector_runtime_subject = process.named_subject(connector_runtime_name)
  let google_oauth_runtime_subject =
    process.named_subject(google_oauth_runtime_name)

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

  // 5b. Resolve the flare transport before the core tree starts.
  let acp_transport =
    transport.parse(
      global_config.acp_transport,
      global_config.acp_server_url,
      global_config.acp_agent_name,
      global_config.acp_command,
    )
  // 6. Build the brain dependencies before the core tree starts.
  let llm_client_val = llm_client.production()
  let skill_runner_val = skill_runner.production()
  let browser_runner_val = browser_runner.production()

  // Platform-keyed transport registry. Discord is always present;
  // Blather joins when the optional `[blather]` config block is set.
  let transports = case global_config.blather {
    Some(b) ->
      dict.from_list([
        #(discord.platform_name, discord_client_val),
        #(blather_types.platform_name, blather_client.production(b)),
      ])
    None -> dict.from_list([#(discord.platform_name, discord_client_val)])
  }
  let brain_config =
    brain.BrainConfig(
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
      transports: transports,
      llm: llm_client_val,
      skill_runner: skill_runner_val,
      browser_runner: browser_runner_val,
      channel_supervisor: channel_sup,
      review_runner: review_runner.default(),
    )

  // 7. Build the scheduler callbacks before the core tree starts.
  let schedules_path = xdg.config_path(paths, "schedules.toml")
  let on_finding = fn(finding: notification.Finding) {
    case
      event_ingest.submit_evidence(
        event_ingest_subject,
        scheduler.finding_to_evidence(finding, time.now_ms()),
      )
    {
      Ok(_) -> Nil
      Error(error) ->
        logging.log(
          logging.Error,
          "[scheduler] Failed to submit finding evidence: " <> error,
        )
    }
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
  let dream_config =
    scheduler.DreamScheduleConfig(
      cron: global_config.dreaming_cron,
      model_spec: global_config.models.dream,
      paths: paths,
      db_subject: db_subject,
      domains: list.map(domain_configs, fn(dc) { dc.0 }),
      budget_percent: global_config.dreaming_budget_percent,
      brain_context: global_config.brain_context,
    )

  let database_spec =
    supervision.worker(fn() {
      use started <- result.try(db.start_named(xdg.db_path(paths), db_name))
      case db_migration.migrate_jsonl(started.data, paths.data) {
        Ok(0) -> {
          logging.log(logging.Info, "[supervisor] No JSONL files to migrate")
          Ok(started)
        }
        Ok(count) -> {
          logging.log(
            logging.Info,
            "[supervisor] Migrated "
              <> int.to_string(count)
              <> " messages from JSONL",
          )
          Ok(started)
        }
        Error(error) ->
          Error(actor.InitFailed("JSONL migration failed: " <> error))
      }
    })
    |> supervision.map_data(fn(_) { Nil })

  let delivery_spec =
    supervision.worker(fn() {
      cognitive_delivery.start_named_with_history(
        delivery_name,
        paths,
        discord_client_val,
        delivery_targets,
        global_config.notifications.digest_windows,
        db_subject,
        None,
      )
    })
    |> supervision.map_data(fn(_) { Nil })

  let cognitive_spec =
    supervision.worker(fn() {
      cognitive_worker.start_named_with_delivery(
        cognitive_name,
        db_subject,
        paths,
        cognitive_llm_config,
        delivery_subject,
        delivery_target_ids,
        global_config.notifications.digest_windows,
      )
    })
    |> supervision.map_data(fn(_) { Nil })

  let event_ingest_spec =
    supervision.worker(fn() {
      event_ingest.start_named_with_cognitive(
        event_ingest_name,
        db_subject,
        Some(cognitive_subject),
      )
    })
    |> supervision.map_data(fn(_) { Nil })

  let asks_spec =
    supervision.worker(fn() {
      external_asks.start_named(
        asks_name,
        db_subject,
        Some(delivery_subject),
        delivery_targets,
        fn(channel, text, buttons) {
          rest.send_message_with_components(
            global_config.discord.token,
            channel,
            text,
            buttons,
          )
        },
        fn(channel, message_id, body, components) {
          rest.edit_message_with_components(
            global_config.discord.token,
            channel,
            message_id,
            body,
            components,
          )
        },
        fn(interaction_token, body, components) {
          rest.edit_interaction_response(
            app_id,
            interaction_token,
            body,
            components,
          )
        },
      )
    })
    |> supervision.map_data(fn(_) { Nil })

  let flare_spec =
    supervision.worker(fn() {
      flare_manager.start_named(
        flare_name,
        global_config.acp_global_max_concurrent,
        global_config.models.monitor,
        fn(event) { process.send(brain_subject, brain.AcpEvent(event)) },
        acp_transport,
        db_subject,
      )
    })
    |> supervision.map_data(fn(_) { Nil })

  let channel_supervisor_spec =
    supervision.worker(fn() {
      channel_supervisor.start_named(channel_supervisor_name)
    })
    |> supervision.map_data(fn(_) { Nil })

  let brain_spec =
    supervision.worker(fn() {
      brain.start_named(brain_name, brain_config)
      |> result.map_error(actor.InitFailed)
    })
    |> supervision.map_data(fn(_) { Nil })

  let scheduler_spec =
    supervision.worker(fn() {
      use started <- result.try(scheduler.start_named(
        scheduler_name,
        schedules_path,
        all_skills,
        on_finding,
        on_rekindle,
      ))
      process.send(brain_subject, brain.SetScheduler(scheduler_subject))
      process.send(brain_subject, brain.SetExternalAsks(asks_subject))
      process.send(scheduler_subject, scheduler.SetFlareSubject(flare_subject))
      process.send(scheduler_subject, scheduler.SetDreamConfig(dream_config))
      Ok(started)
    })
    |> supervision.map_data(fn(_) { Nil })

  let core_children =
    core_supervision.CoreChildren(
      database: database_spec,
      cognitive_delivery: delivery_spec,
      cognitive_worker: cognitive_spec,
      event_ingest: event_ingest_spec,
      external_asks: asks_spec,
      flare_manager: flare_spec,
      channel_supervisor: channel_supervisor_spec,
      brain: brain_spec,
      scheduler: scheduler_spec,
    )

  // 8. Start the core tree and the compatibility transports.
  let discord_config = global_config.discord

  let base_tree =
    static_supervisor.new(static_supervisor.OneForOne)
    |> static_supervisor.restart_tolerance(intensity: 10, period: 60)
    |> static_supervisor.auto_shutdown(static_supervisor.AnySignificant)
    |> static_supervisor.add(core_supervision.supervised(core_children))
    |> static_supervisor.add(connector_runtime.supervised_with_google(
      connector_runtime_name,
      db_subject,
      event_ingest_subject,
      paths,
      global_config.connector_configurations,
    ))
    |> static_supervisor.add(google_oauth_runtime.supervised_production(
      google_oauth_runtime_name,
      db_subject,
      paths,
      global_config.connector_configurations,
    ))
    |> static_supervisor.add(poller.supervised(discord_config, brain_subject))
    |> static_supervisor.add(mcp_pool.supervised(global_config.mcp))

  let with_blather = case global_config.blather {
    Some(b) -> {
      logging.log(
        logging.Info,
        "[supervisor] Starting Blather poller: " <> b.url,
      )
      static_supervisor.add(
        base_tree,
        blather_poller.supervised(b, brain_subject),
      )
    }
    None -> base_tree
  }

  let result = static_supervisor.start(with_blather)

  case result {
    Ok(started) -> {
      logging.log(logging.Info, "Aura supervisor started")
      case
        ctl.start(ctl.CtlContext(
          paths: paths,
          db_subject: db_subject,
          event_ingest_subject: event_ingest_subject,
          cognitive_subject: cognitive_subject,
          delivery_subject: Some(delivery_subject),
          asks_subject: Some(asks_subject),
          oauth_subject: google_oauth_runtime_subject,
          connector_runtime_subject: connector_runtime_subject,
          connector_configurations: global_config.connector_configurations,
          domains: list.map(domain_configs, fn(dc) { dc.0 }),
          dream_model: global_config.models.dream,
          dream_budget_percent: global_config.dreaming_budget_percent,
          brain_context: global_config.brain_context,
          started_at_ms: time.now_ms(),
        ))
      {
        Ok(_) -> Nil
        Error(error) ->
          logging.log(
            logging.Error,
            "[supervisor] Failed to start ctl: " <> error,
          )
      }
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
      Ok(#(
        list.flat_map(results, fn(r) { r.0 }),
        list.map(results, fn(r) { r.1 }),
      ))
    }
  }
}

fn load_domain_config(
  paths: xdg.Paths,
  channel_map: List(#(String, String)),
  name: String,
) -> Result(#(List(brain.DomainInfo), #(String, config.DomainConfig)), String) {
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
  let domains =
    [
      brain.DomainInfo(
        name: name,
        platform: discord.platform_name,
        channel_id: channel_id,
      ),
    ]
    |> list.append(case cfg.blather_channel {
      Some(channel_id) -> [
        brain.DomainInfo(
          name: name,
          platform: blather_types.platform_name,
          channel_id: channel_id,
        ),
      ]
      None -> []
    })
  Ok(#(domains, #(name, cfg)))
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
