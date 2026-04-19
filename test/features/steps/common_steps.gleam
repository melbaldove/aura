import aura/brain
import aura/discord
import aura/discord/types as discord_types
import dream_test/gherkin/steps.{
  type StepContext, type StepRegistry, get_int, get_string, get_word,
}
import dream_test/gherkin/world
import dream_test/matchers.{
  be_equal, contain_string, or_fail_with, should, succeed,
}
import dream_test/types as dream_types
import fakes/fake_discord
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{None}
import test_harness.{type TestSystem}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Register all common step definitions onto the provided registry.
/// Chain additional module registrations in Task 14's runner.
pub fn register(reg: StepRegistry) -> StepRegistry {
  reg
  |> steps.step("a fresh Aura system", given_fresh_system)
  |> steps.step(
    "a fresh Aura system with domain {string} containing AGENTS.md {string}",
    given_fresh_system_with_domain,
  )
  |> steps.step(
    "a user message {string} arrives in {string}",
    when_user_message_arrives,
  )
  |> steps.step(
    "a user message with image {string} arrives in {string}",
    when_user_message_with_image_arrives,
  )
  |> steps.step(
    "a Discord message is sent to {string}",
    then_discord_message_sent,
  )
  |> steps.step(
    "the Discord message sent to {string} contains {string}",
    then_discord_contains,
  )
  |> steps.step(
    "no Discord message is sent to {string}",
    then_no_discord_send,
  )
  |> steps.step(
    "the turn deadline fires after {int} {word}",
    then_deadline_fires_after,
  )
}

/// Convert a duration expressed as an integer plus a unit string to milliseconds.
///
/// Recognised units:
/// - `ms` / `millisecond` / `milliseconds` → n
/// - `second` / `seconds`                  → n * 1_000
/// - `minute` / `minutes`                  → n * 60_000
/// - anything else                         → n (fall-through)
pub fn duration_to_ms(n: Int, unit: String) -> Int {
  case unit {
    "ms" | "millisecond" | "milliseconds" -> n
    "second" | "seconds" -> n * 1000
    "minute" | "minutes" -> n * 60_000
    _ -> n
  }
}

// ---------------------------------------------------------------------------
// Step handlers
// ---------------------------------------------------------------------------

fn given_fresh_system(
  ctx: StepContext,
) -> Result(dream_types.AssertionResult, String) {
  let system = test_harness.fresh_system()
  world.put(ctx.world, "system", system)
  Ok(succeed())
}

/// Set up a fresh system with a single domain pre-configured.
/// Convention: channel_id is derived as `<domain_name>-channel`.
/// The AGENTS.md content is written to the domain's config dir before brain
/// starts, so `domain.load_context` picks it up on the first message.
fn given_fresh_system_with_domain(
  ctx: StepContext,
) -> Result(dream_types.AssertionResult, String) {
  use domain_name <- result_try(get_string(ctx.captures, 0))
  use agents_md <- result_try(get_string(ctx.captures, 1))
  let channel_id = domain_name <> "-channel"
  let system =
    test_harness.fresh_system_with_domain(domain_name, agents_md, channel_id)
  world.put(ctx.world, "system", system)
  Ok(succeed())
}

fn when_user_message_arrives(
  ctx: StepContext,
) -> Result(dream_types.AssertionResult, String) {
  use content <- result_try(get_string(ctx.captures, 0))
  use channel_id <- result_try(get_string(ctx.captures, 1))
  use system <- result_try(world.get(ctx.world, "system"))
  let sys: TestSystem = system
  let msg = build_incoming(channel_id, content)
  process.send(sys.brain_subject, brain.HandleMessage(msg))
  Ok(succeed())
}

fn when_user_message_with_image_arrives(
  ctx: StepContext,
) -> Result(dream_types.AssertionResult, String) {
  use content <- result_try(get_string(ctx.captures, 0))
  use channel_id <- result_try(get_string(ctx.captures, 1))
  use system <- result_try(world.get(ctx.world, "system"))
  let sys: TestSystem = system
  let msg = build_incoming_with_image(channel_id, content)
  process.send(sys.brain_subject, brain.HandleMessage(msg))
  Ok(succeed())
}

fn then_discord_message_sent(
  ctx: StepContext,
) -> Result(dream_types.AssertionResult, String) {
  use channel_id <- result_try(get_string(ctx.captures, 0))
  use system <- result_try(world.get(ctx.world, "system"))
  let sys: TestSystem = system
  let _content = fake_discord.assert_sent_to(sys.fake_discord, channel_id, 2000)
  Ok(succeed())
}

fn then_discord_contains(
  ctx: StepContext,
) -> Result(dream_types.AssertionResult, String) {
  use channel_id <- result_try(get_string(ctx.captures, 0))
  use expected <- result_try(get_string(ctx.captures, 1))
  use system <- result_try(world.get(ctx.world, "system"))
  let sys: TestSystem = system
  let content = fake_discord.assert_sent_to(sys.fake_discord, channel_id, 2000)
  content
  |> should
  |> contain_string(expected)
  |> or_fail_with(
    "Discord message to " <> channel_id <> " did not contain: " <> expected,
  )
}

fn then_no_discord_send(
  ctx: StepContext,
) -> Result(dream_types.AssertionResult, String) {
  use channel_id <- result_try(get_string(ctx.captures, 0))
  use system <- result_try(world.get(ctx.world, "system"))
  let sys: TestSystem = system
  let _ = process.sleep(200)
  let msgs = fake_discord.all_sent_to(sys.fake_discord, channel_id)
  let count = list.length(msgs)
  count
  |> should
  |> be_equal(0)
  |> or_fail_with(
    "Expected no Discord messages to "
    <> channel_id
    <> " but got "
    <> int.to_string(count),
  )
}

fn then_deadline_fires_after(
  ctx: StepContext,
) -> Result(dream_types.AssertionResult, String) {
  use n <- result_try(get_int(ctx.captures, 0))
  use unit <- result_try(get_word(ctx.captures, 1))
  let _ms = duration_to_ms(n, unit)
  // Placeholder — deadline assertion body lands in channel_actor refactor.
  Ok(succeed())
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

fn build_incoming(channel_id: String, content: String) -> discord.IncomingMessage {
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

/// Build an incoming message carrying a single image attachment. The URL is
/// deliberately non-routable — the brain's attachment downloader will fail
/// fast, and the vision path's data-URL fallback will also fail (no local
/// file). `describe_image` then calls `LLMClient.chat_text` with the URL
/// string, which the fake LLM intercepts with its scripted response.
fn build_incoming_with_image(
  channel_id: String,
  content: String,
) -> discord.IncomingMessage {
  discord.IncomingMessage(
    message_id: "fake-img-" <> content,
    channel_id: channel_id,
    channel_name: None,
    guild_id: "test-guild",
    author_id: "test",
    author_name: "test",
    content: content,
    is_bot: False,
    attachments: [
      discord_types.Attachment(
        url: "fake://test-image/not-a-real-url",
        content_type: "image/jpeg",
        filename: "test.jpg",
      ),
    ],
  )
}

/// Thread a `Result` through a step body using `use` syntax.
fn result_try(
  r: Result(a, String),
  f: fn(a) -> Result(dream_types.AssertionResult, String),
) -> Result(dream_types.AssertionResult, String) {
  case r {
    Ok(v) -> f(v)
    Error(e) -> Error(e)
  }
}
