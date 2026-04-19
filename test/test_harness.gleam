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
import aura/clients/browser_runner
import aura/config
import aura/db
import aura/xdg
import fakes/fake_discord.{type FakeDiscord}
import fakes/fake_llm.{type FakeLLM}
import fakes/fake_skill_runner.{type FakeSkillRunner}
import gleam/erlang/process.{type Subject}
import gleam/int
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
    db_path: String,
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
  // 1. Build the three fakes.
  let #(fake_discord, discord_client) = fake_discord.new()
  let #(fake_llm, llm_client) = fake_llm.new()
  let #(fake_skill_runner, skill_runner_client) = fake_skill_runner.new()

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

  // `models.brain = "zai/glm-5-turbo"` so build_llm_config succeeds. All
  // other model roles default to empty; no test path exercises them.
  let global =
    config.GlobalConfig(
      ..config.default_global(),
      models: config.ModelsConfig(
        brain: "zai/glm-5-turbo",
        domain: "",
        acp: "",
        heartbeat: "",
        monitor: "",
        vision: "",
        dream: "",
      ),
      brain_context: 128_000,
    )

  let brain_config =
    brain.BrainConfig(
      global: global,
      paths: paths,
      soul: "You are Aura, under test.",
      domains: [],
      domain_configs: [],
      skill_infos: [],
      validation_rules: [],
      db_subject: db_subject,
      acp_subject: flare_subject,
      discord: discord_client,
      llm: llm_client,
      skill_runner: skill_runner_client,
      browser_runner: browser_runner.production(),
    )

  let assert Ok(brain_subject) = brain.start(brain_config)

  TestSystem(
    brain_subject: brain_subject,
    fake_discord: fake_discord,
    fake_llm: fake_llm,
    fake_skill_runner: fake_skill_runner,
    db_path: db_path,
  )
}

/// Stop the brain actor and remove the scratch DB. The fakes are linked to
/// their own actors — they die with the test process.
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
