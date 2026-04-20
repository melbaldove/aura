//// Fresh-per-scenario system under test. Given three fakes (Discord, LLM,
//// skill runner) and a scratch SQLite DB, construct a complete Aura `brain`
//// wired end-to-end with no production side effects (no real network, no
//// disk writes outside /tmp, no launchd).
////
//// Usage:
////
////   let system = test_harness.fresh_system()
////   // interact via system.fake_discord / system.fake_llm / system.brain_subject
////   test_harness.teardown(system)
////
//// Caveats:
////   - browser_runner is the real `production()` impl; Plan A scenarios do not
////     exercise the browser tool, so this is safe until a fake exists.
////   - scheduler is NOT started — brain's `scheduler_subject` stays `None`.
////     Tests that need heartbeat findings or dreaming won't fire.
////   - flare_manager runs for real (cheap: it just attaches to the DB actor);
////     it won't dispatch anything unless the test explicitly ignites a flare.
////   - ZAI_API_KEY is set to a dummy value so `models.build_llm_config` does
////     not fail. The fake LLMClient intercepts all streaming calls anyway —
////     no real HTTP ever goes out.

import aura/acp/flare_manager
import aura/acp/transport
import aura/brain
import aura/brain_tools
import aura/channel_supervisor
import aura/clients/browser_runner
import aura/clients/discord_client
import aura/clients/llm_client
import aura/clients/skill_runner
import aura/config
import aura/db
import aura/discord
import aura/shell
import aura/skill
import aura/xdg
import fakes/fake_discord.{type FakeDiscord}
import fakes/fake_llm.{type FakeLLM}
import fakes/fake_review.{type FakeReview}
import fakes/fake_skill_runner.{type FakeSkillRunner}
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/option.{None}
import simplifile

// ---------------------------------------------------------------------------
// Public types
// ---------------------------------------------------------------------------

pub type TestSystem {
  TestSystem(
    brain_subject: Subject(brain.BrainMessage),
    fake_discord: FakeDiscord,
    fake_llm: FakeLLM,
    fake_skill_runner: FakeSkillRunner,
    fake_review: FakeReview,
    db_path: String,
    db_subject: Subject(db.DbMessage),
    acp_subject: Subject(flare_manager.FlareMsg),
  )
}

// ---------------------------------------------------------------------------
// FFI
// ---------------------------------------------------------------------------

@external(erlang, "aura_test_ffi", "unique_integer")
fn unique_integer() -> Int

@external(erlang, "aura_test_ffi", "set_env")
fn set_env(key: String, value: String) -> Nil

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Spin up a fresh `TestSystem`: three fakes, a scratch SQLite DB, a live
/// flare_manager, and a brain wired to all of the above. Panics on any
/// setup failure — tests should fail loud, not degrade silently.
pub fn fresh_system() -> TestSystem {
  // 1. Build the four fakes.
  let #(fake_discord, discord_client) = fake_discord.new()
  let #(fake_llm, llm_client) = fake_llm.new()
  let #(fake_skill_runner, skill_runner_client) = fake_skill_runner.new()
  let fake_review_inst = fake_review.new()

  // 2. Unique scratch DB path; delete any pre-existing file.
  let db_path =
    "/tmp/aura-test-" <> int.to_string(unique_integer()) <> ".db"
  let _ = simplifile.delete(db_path)

  // 3. Ensure models.build_llm_config can resolve an API key. The fake LLM
  //    intercepts the actual stream call — this value is never transmitted.
  set_env("ZAI_API_KEY", "test-harness-dummy-key")

  // 4. DB actor at the scratch path.
  let assert Ok(db_subject) = db.start(db_path)

  // 5. Live flare_manager — attached to the same scratch DB. Tmux transport
  //    means no ACP subprocess is ever spawned unless the test explicitly
  //    ignites a flare.
  let assert Ok(flare_subject) =
    flare_manager.start(
      1,
      "zai/glm-5-turbo",
      fn(_event) { Nil },
      transport.Tmux,
      db_subject,
    )

  // 5b. Channel supervisor — idle in tests until allowlisted channels are exercised.
  let assert Ok(channel_sup) = channel_supervisor.start()

  // 6. Build BrainConfig with test-safe defaults.
  //
  // NOTE: `paths` points at /tmp so any accidental file I/O lands in the
  // ephemeral scratch root, not the user's real XDG dirs. — change this if
  // your test needs to assert on written files.
  let tmp_root = "/tmp/aura-test-root-" <> int.to_string(unique_integer())
  let paths =
    xdg.Paths(
      config: tmp_root <> "/config",
      data: tmp_root <> "/data",
      state: tmp_root <> "/state",
    )

  // Pre-create XDG directories so file writes (e.g. memory tool writing
  // USER.md to paths.config) succeed without needing parent-dir creation.
  let assert Ok(_) = simplifile.create_directory_all(paths.config)
  let assert Ok(_) = simplifile.create_directory_all(paths.data)
  let assert Ok(_) = simplifile.create_directory_all(paths.state)

  // `models.brain = "zai/glm-5-turbo"` so build_llm_config succeeds. The
  // vision model is set so `vision.is_enabled` returns True when a test
  // sends an image attachment — actual HTTP never goes out because the
  // fake LLMClient's `chat_text` intercepts the call. Other model roles
  // default to empty; no test path exercises them.
  let global =
    config.GlobalConfig(
      ..config.default_global(),
      models: config.ModelsConfig(
        brain: "zai/glm-5-turbo",
        domain: "",
        acp: "",
        heartbeat: "",
        monitor: "",
        vision: "zai/glm-5v-turbo",
        dream: "",
      ),
      brain_context: 128_000,
    )

  // Seed a default jira skill so tests that call `run_skill` with name="jira"
  // can find it in skill_infos. The path is never accessed because the
  // fake_skill_runner intercepts the invocation — this is registry metadata only.
  let default_skill_infos = [
    skill.SkillInfo(name: "jira", description: "test", path: "/tmp/nonexistent-jira"),
  ]

  let brain_config =
    brain.BrainConfig(
      global: global,
      paths: paths,
      soul: "You are Aura, under test.",
      domains: [],
      domain_configs: [],
      skill_infos: default_skill_infos,
      validation_rules: [],
      db_subject: db_subject,
      acp_subject: flare_subject,
      discord: discord_client,
      llm: llm_client,
      skill_runner: skill_runner_client,
      browser_runner: browser_runner.production(),
      channel_supervisor: channel_sup,
      review_runner: fake_review.as_runner(fake_review_inst),
    )

  let assert Ok(brain_subject) = brain.start(brain_config)

  TestSystem(
    brain_subject: brain_subject,
    fake_discord: fake_discord,
    fake_llm: fake_llm,
    fake_skill_runner: fake_skill_runner,
    fake_review: fake_review_inst,
    db_path: db_path,
    db_subject: db_subject,
    acp_subject: flare_subject,
  )
}

/// Spin up a fresh `TestSystem` where the given channel_ids are in the
/// channel_actor allowlist. Messages to these channels route through the new
/// concurrent channel_actor path instead of the legacy synchronous brain
/// loop. All other behavior matches `fresh_system/0`.
pub fn fresh_system_with_allowlist(
  channel_ids: List(String),
) -> TestSystem {
  // 1. Build the four fakes.
  let #(fake_discord, discord_client) = fake_discord.new()
  let #(fake_llm, llm_client) = fake_llm.new()
  let #(fake_skill_runner, skill_runner_client) = fake_skill_runner.new()
  let fake_review_inst = fake_review.new()

  // 2. Unique scratch DB path; delete any pre-existing file.
  let db_path =
    "/tmp/aura-test-" <> int.to_string(unique_integer()) <> ".db"
  let _ = simplifile.delete(db_path)

  // 3. Ensure models.build_llm_config can resolve an API key.
  set_env("ZAI_API_KEY", "test-harness-dummy-key")

  // 4. DB actor at the scratch path.
  let assert Ok(db_subject) = db.start(db_path)

  // 5. Live flare_manager.
  let assert Ok(flare_subject) =
    flare_manager.start(
      1,
      "zai/glm-5-turbo",
      fn(_event) { Nil },
      transport.Tmux,
      db_subject,
    )

  // 5b. Channel supervisor.
  let assert Ok(channel_sup) = channel_supervisor.start()

  // 6. Build paths pointing at a unique tmp root.
  let tmp_root = "/tmp/aura-test-root-" <> int.to_string(unique_integer())
  let paths =
    xdg.Paths(
      config: tmp_root <> "/config",
      data: tmp_root <> "/data",
      state: tmp_root <> "/state",
    )

  let assert Ok(_) = simplifile.create_directory_all(paths.config)
  let assert Ok(_) = simplifile.create_directory_all(paths.data)
  let assert Ok(_) = simplifile.create_directory_all(paths.state)

  // 7. Build GlobalConfig with the allowlist set.
  let default = config.default_global()
  let global =
    config.GlobalConfig(
      ..default,
      models: config.ModelsConfig(
        brain: "zai/glm-5-turbo",
        domain: "",
        acp: "",
        heartbeat: "",
        monitor: "",
        vision: "zai/glm-5v-turbo",
        dream: "",
      ),
      brain_context: 128_000,
      experimental: config.ExperimentalConfig(
        channel_actor_channels: channel_ids,
      ),
    )

  let default_skill_infos = [
    skill.SkillInfo(name: "jira", description: "test", path: "/tmp/nonexistent-jira"),
  ]

  let brain_config =
    brain.BrainConfig(
      global: global,
      paths: paths,
      soul: "You are Aura, under test.",
      domains: [],
      domain_configs: [],
      skill_infos: default_skill_infos,
      validation_rules: [],
      db_subject: db_subject,
      acp_subject: flare_subject,
      discord: discord_client,
      llm: llm_client,
      skill_runner: skill_runner_client,
      browser_runner: browser_runner.production(),
      channel_supervisor: channel_sup,
      review_runner: fake_review.as_runner(fake_review_inst),
    )

  let assert Ok(brain_subject) = brain.start(brain_config)

  TestSystem(
    brain_subject: brain_subject,
    fake_discord: fake_discord,
    fake_llm: fake_llm,
    fake_skill_runner: fake_skill_runner,
    fake_review: fake_review_inst,
    db_path: db_path,
    db_subject: db_subject,
    acp_subject: flare_subject,
  )
}

/// Spin up a fresh `TestSystem` with a single domain pre-configured. Creates a
/// temporary directory under /tmp, writes `agents_md` to AGENTS.md in the
/// domain's config dir, seeds a `DomainInfo` pointing `channel_id` to
/// `domain_name`, and includes it in BrainConfig's domains list.
///
/// Convention: the channel_id for the domain is always `<domain_name>-channel`
/// unless overridden. This helper uses that convention internally.
///
/// The domain config dir is at:
///   {paths.config}/domains/{domain_name}/AGENTS.md
///
/// which matches what `domain.load_context` reads via `xdg.domain_config_dir`.
pub fn fresh_system_with_domain(
  domain_name: String,
  agents_md: String,
  channel_id: String,
) -> TestSystem {
  // 1. Build the four fakes.
  let #(fake_discord, discord_client) = fake_discord.new()
  let #(fake_llm, llm_client) = fake_llm.new()
  let #(fake_skill_runner, skill_runner_client) = fake_skill_runner.new()
  let fake_review_inst = fake_review.new()

  // 2. Unique scratch DB path; delete any pre-existing file.
  let db_path =
    "/tmp/aura-test-" <> int.to_string(unique_integer()) <> ".db"
  let _ = simplifile.delete(db_path)

  // 3. Ensure models.build_llm_config can resolve an API key.
  set_env("ZAI_API_KEY", "test-harness-dummy-key")

  // 4. DB actor at the scratch path.
  let assert Ok(db_subject) = db.start(db_path)

  // 5. Live flare_manager.
  let assert Ok(flare_subject) =
    flare_manager.start(
      1,
      "zai/glm-5-turbo",
      fn(_event) { Nil },
      transport.Tmux,
      db_subject,
    )

  // 5b. Channel supervisor — idle in tests until allowlisted channels are exercised.
  let assert Ok(channel_sup) = channel_supervisor.start()

  // 6. Build paths pointing at a unique tmp root.
  let tmp_root = "/tmp/aura-test-root-" <> int.to_string(unique_integer())
  let paths =
    xdg.Paths(
      config: tmp_root <> "/config",
      data: tmp_root <> "/data",
      state: tmp_root <> "/state",
    )

  // 7. Create the domain config directory and write AGENTS.md.
  //    domain.load_context reads AGENTS.md from:
  //      {paths.config}/domains/{domain_name}/AGENTS.md
  let domain_config_dir =
    paths.config <> "/domains/" <> domain_name
  let assert Ok(_) = simplifile.create_directory_all(domain_config_dir)
  let assert Ok(_) =
    simplifile.write(domain_config_dir <> "/AGENTS.md", agents_md)

  // 8. Build BrainConfig with the test domain included.
  let global =
    config.GlobalConfig(
      ..config.default_global(),
      models: config.ModelsConfig(
        brain: "zai/glm-5-turbo",
        domain: "",
        acp: "",
        heartbeat: "",
        monitor: "",
        vision: "zai/glm-5v-turbo",
        dream: "",
      ),
      brain_context: 128_000,
    )

  let domain_info = brain.DomainInfo(name: domain_name, channel_id: channel_id)

  // Seed the same default jira skill as fresh_system/0 so domain-scoped
  // tests can also exercise run_skill without extra setup steps.
  let default_skill_infos = [
    skill.SkillInfo(name: "jira", description: "test", path: "/tmp/nonexistent-jira"),
  ]

  let brain_config =
    brain.BrainConfig(
      global: global,
      paths: paths,
      soul: "You are Aura, under test.",
      domains: [domain_info],
      domain_configs: [],
      skill_infos: default_skill_infos,
      validation_rules: [],
      db_subject: db_subject,
      acp_subject: flare_subject,
      discord: discord_client,
      llm: llm_client,
      skill_runner: skill_runner_client,
      browser_runner: browser_runner.production(),
      channel_supervisor: channel_sup,
      review_runner: fake_review.as_runner(fake_review_inst),
    )

  let assert Ok(brain_subject) = brain.start(brain_config)

  TestSystem(
    brain_subject: brain_subject,
    fake_discord: fake_discord,
    fake_llm: fake_llm,
    fake_skill_runner: fake_skill_runner,
    fake_review: fake_review_inst,
    db_path: db_path,
    db_subject: db_subject,
    acp_subject: flare_subject,
  )
}

/// Build a minimal `IncomingMessage` for use in tests.
/// Mirrors the private `build_incoming` in `common_steps.gleam`.
pub fn incoming(channel_id: String, content: String) -> discord.IncomingMessage {
  discord.IncomingMessage(
    message_id: "fake-" <> content,
    channel_id: channel_id,
    channel_name: None,
    guild_id: "test-guild",
    author_id: "test",
    author_name: "test",
    content: content,
    is_bot: False,
    attachments: [],
  )
}

/// Spin up a fresh `TestSystem` with a single domain pre-configured AND
/// a set of channel IDs on the channel_actor allowlist. Combining both is
/// necessary for tests that exercise thread creation — the top-level domain
/// channel must be on the allowlist so brain routes through channel_actor,
/// and the domain must be registered so brain detects it as a top-level
/// domain channel and creates a thread.
pub fn fresh_system_with_domain_and_allowlist(
  domain_name: String,
  agents_md: String,
  channel_id: String,
  allowlist: List(String),
) -> TestSystem {
  // 1. Build the four fakes.
  let #(fake_discord, discord_client) = fake_discord.new()
  let #(fake_llm, llm_client) = fake_llm.new()
  let #(fake_skill_runner, skill_runner_client) = fake_skill_runner.new()
  let fake_review_inst = fake_review.new()

  // 2. Unique scratch DB path; delete any pre-existing file.
  let db_path =
    "/tmp/aura-test-" <> int.to_string(unique_integer()) <> ".db"
  let _ = simplifile.delete(db_path)

  // 3. Ensure models.build_llm_config can resolve an API key.
  set_env("ZAI_API_KEY", "test-harness-dummy-key")

  // 4. DB actor at the scratch path.
  let assert Ok(db_subject) = db.start(db_path)

  // 5. Live flare_manager.
  let assert Ok(flare_subject) =
    flare_manager.start(
      1,
      "zai/glm-5-turbo",
      fn(_event) { Nil },
      transport.Tmux,
      db_subject,
    )

  // 5b. Channel supervisor.
  let assert Ok(channel_sup) = channel_supervisor.start()

  // 6. Build paths pointing at a unique tmp root.
  let tmp_root = "/tmp/aura-test-root-" <> int.to_string(unique_integer())
  let paths =
    xdg.Paths(
      config: tmp_root <> "/config",
      data: tmp_root <> "/data",
      state: tmp_root <> "/state",
    )

  // 7. Create the domain config directory and write AGENTS.md.
  let domain_config_dir =
    paths.config <> "/domains/" <> domain_name
  let assert Ok(_) = simplifile.create_directory_all(domain_config_dir)
  let assert Ok(_) =
    simplifile.write(domain_config_dir <> "/AGENTS.md", agents_md)

  // 8. Build GlobalConfig with the domain and the allowlist.
  let global =
    config.GlobalConfig(
      ..config.default_global(),
      models: config.ModelsConfig(
        brain: "zai/glm-5-turbo",
        domain: "",
        acp: "",
        heartbeat: "",
        monitor: "",
        vision: "zai/glm-5v-turbo",
        dream: "",
      ),
      brain_context: 128_000,
      experimental: config.ExperimentalConfig(
        channel_actor_channels: allowlist,
      ),
    )

  let domain_info = brain.DomainInfo(name: domain_name, channel_id: channel_id)

  let default_skill_infos = [
    skill.SkillInfo(name: "jira", description: "test", path: "/tmp/nonexistent-jira"),
  ]

  let brain_config =
    brain.BrainConfig(
      global: global,
      paths: paths,
      soul: "You are Aura, under test.",
      domains: [domain_info],
      domain_configs: [],
      skill_infos: default_skill_infos,
      validation_rules: [],
      db_subject: db_subject,
      acp_subject: flare_subject,
      discord: discord_client,
      llm: llm_client,
      skill_runner: skill_runner_client,
      browser_runner: browser_runner.production(),
      channel_supervisor: channel_sup,
      review_runner: fake_review.as_runner(fake_review_inst),
    )

  let assert Ok(brain_subject) = brain.start(brain_config)

  TestSystem(
    brain_subject: brain_subject,
    fake_discord: fake_discord,
    fake_llm: fake_llm,
    fake_skill_runner: fake_skill_runner,
    fake_review: fake_review_inst,
    db_path: db_path,
    db_subject: db_subject,
    acp_subject: flare_subject,
  )
}

/// Stop the brain actor and remove the scratch DB. The fakes are linked to
/// their own actors — they die with the test process.
/// Spin up a fresh `TestSystem` with the given `review_interval`. The
/// channel "c" is on the allowlist so it routes through channel_actor.
/// The fake_review in the returned TestSystem records review spawns.
pub fn fresh_system_with_review_interval(review_interval: Int) -> TestSystem {
  // 1. Build the four fakes.
  let #(fake_discord, discord_client) = fake_discord.new()
  let #(fake_llm, llm_client) = fake_llm.new()
  let #(fake_skill_runner, skill_runner_client) = fake_skill_runner.new()
  let fake_review_inst = fake_review.new()

  // 2. Unique scratch DB path.
  let db_path =
    "/tmp/aura-test-" <> int.to_string(unique_integer()) <> ".db"
  let _ = simplifile.delete(db_path)

  set_env("ZAI_API_KEY", "test-harness-dummy-key")

  let assert Ok(db_subject) = db.start(db_path)

  let assert Ok(flare_subject) =
    flare_manager.start(
      1,
      "zai/glm-5-turbo",
      fn(_event) { Nil },
      transport.Tmux,
      db_subject,
    )

  let assert Ok(channel_sup) = channel_supervisor.start()

  let tmp_root = "/tmp/aura-test-root-" <> int.to_string(unique_integer())
  let paths =
    xdg.Paths(
      config: tmp_root <> "/config",
      data: tmp_root <> "/data",
      state: tmp_root <> "/state",
    )

  let assert Ok(_) = simplifile.create_directory_all(paths.config)
  let assert Ok(_) = simplifile.create_directory_all(paths.data)
  let assert Ok(_) = simplifile.create_directory_all(paths.state)

  let default = config.default_global()
  let global =
    config.GlobalConfig(
      ..default,
      models: config.ModelsConfig(
        brain: "zai/glm-5-turbo",
        domain: "",
        acp: "",
        heartbeat: "",
        monitor: "",
        vision: "zai/glm-5v-turbo",
        dream: "",
      ),
      brain_context: 128_000,
      memory: config.MemoryConfig(
        review_interval: review_interval,
        notify_on_review: False,
        skill_review_interval: 0,
      ),
      // Channel "c" is on the allowlist so brain routes it to channel_actor.
      experimental: config.ExperimentalConfig(channel_actor_channels: ["c"]),
    )

  let default_skill_infos = [
    skill.SkillInfo(name: "jira", description: "test", path: "/tmp/nonexistent-jira"),
  ]

  let brain_config =
    brain.BrainConfig(
      global: global,
      paths: paths,
      soul: "You are Aura, under test.",
      domains: [],
      domain_configs: [],
      skill_infos: default_skill_infos,
      validation_rules: [],
      db_subject: db_subject,
      acp_subject: flare_subject,
      discord: discord_client,
      llm: llm_client,
      skill_runner: skill_runner_client,
      browser_runner: browser_runner.production(),
      channel_supervisor: channel_sup,
      review_runner: fake_review.as_runner(fake_review_inst),
    )

  let assert Ok(brain_subject) = brain.start(brain_config)

  TestSystem(
    brain_subject: brain_subject,
    fake_discord: fake_discord,
    fake_llm: fake_llm,
    fake_skill_runner: fake_skill_runner,
    fake_review: fake_review_inst,
    db_path: db_path,
    db_subject: db_subject,
    acp_subject: flare_subject,
  )
}

pub fn teardown(system: TestSystem) -> Nil {
  case process.subject_owner(system.brain_subject) {
    Ok(pid) -> {
      // Unlink first: actor.start links the brain pid to the caller (the test
      // process). Killing a linked pid propagates EXIT and kills the test too.
      process.unlink(pid)
      process.kill(pid)
    }
    Error(_) -> Nil
  }
  let _ = simplifile.delete(system.db_path)
  Nil
}

/// Build a standalone `ToolContext` suitable for tests that need to invoke
/// `brain_tools.execute_tool` directly (e.g. tool_worker_test). Uses stub
/// subjects and production clients that make no real network calls.
///
/// Callers that need a real system wired end-to-end should use
/// `fresh_system()` instead. Use this when you only need the ToolContext.
pub fn standalone_tool_context() -> brain_tools.ToolContext {
  let db_subject = process.new_subject()
  let acp_subject = process.new_subject()
  let paths =
    xdg.Paths(
      config: "/tmp/aura-tool-ctx-test/config",
      data: "/tmp/aura-tool-ctx-test/data",
      state: "/tmp/aura-tool-ctx-test/state",
    )
  brain_tools.ToolContext(
    base_dir: "/tmp",
    discord_token: "fake",
    guild_id: "",
    message_id: "",
    channel_id: "test-channel",
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
    discord: discord_client.production("fake"),
    llm_client: llm_client.production(),
    skill_runner: skill_runner.production(),
    browser_runner: browser_runner.production(),
  )
}
