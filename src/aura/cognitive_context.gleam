//// Text-first cognitive context packet.
////
//// This module builds the model-readable packet from an observation, citable
//// evidence, ordinary policy markdown, and ordinary concern markdown. It is
//// deliberately not a policy engine: code assembles provenance, the model
//// interprets it, and the validator gates the result.

import aura/cognitive_event
import aura/xdg
import gleam/dict
import gleam/int
import gleam/list
import gleam/result
import gleam/string
import simplifile

pub type PolicyFile {
  PolicyFile(name: String, path: String, source_ref: String, content: String)
}

pub type ConcernFile {
  ConcernFile(name: String, path: String, source_ref: String, content: String)
}

pub type ContextPacket {
  ContextPacket(
    observation: cognitive_event.Observation,
    evidence: cognitive_event.EvidenceBundle,
    policies: List(PolicyFile),
    concerns: List(ConcernFile),
    delivery_targets: List(String),
    recent_decisions: String,
  )
}

/// Build the model context packet, creating default policy files if missing.
pub fn build(
  paths: xdg.Paths,
  observation: cognitive_event.Observation,
  evidence: cognitive_event.EvidenceBundle,
) -> Result(ContextPacket, String) {
  build_with_delivery_targets(paths, observation, evidence, ["none", "default"])
}

/// Build the model context packet with explicit delivery targets.
pub fn build_with_delivery_targets(
  paths: xdg.Paths,
  observation: cognitive_event.Observation,
  evidence: cognitive_event.EvidenceBundle,
  delivery_targets: List(String),
) -> Result(ContextPacket, String) {
  use policies <- result.try(load_policies(paths))
  use concerns <- result.try(load_concerns(paths))

  Ok(ContextPacket(
    observation: observation,
    evidence: evidence,
    policies: policies,
    concerns: concerns,
    delivery_targets: normalize_delivery_targets(delivery_targets),
    recent_decisions: "",
  ))
}

/// Render a compact, citable context packet for the cognitive model.
pub fn render(packet: ContextPacket) -> String {
  "## Observation\n"
  <> render_observation(packet.observation)
  <> "\n\n## Evidence Atoms\n"
  <> render_evidence(packet.evidence)
  <> "\n\n## Known Citation Refs\n"
  <> render_known_refs(known_citation_refs(packet))
  <> "\n\n## Policies\n"
  <> render_policies(packet.policies)
  <> "\n\n## Concerns\n"
  <> render_concerns(packet.concerns)
  <> "\n\n## Delivery Targets\n"
  <> render_delivery_targets(packet.delivery_targets)
  <> "\n\n## Recent Decisions\n"
  <> case packet.recent_decisions {
    "" -> "None yet."
    text -> text
  }
}

/// All refs the model may cite in a decision envelope.
pub fn known_citation_refs(packet: ContextPacket) -> List(String) {
  list.append(
    evidence_citation_refs(packet),
    list.append(policy_citation_refs(packet), concern_citation_refs(packet)),
  )
}

pub fn evidence_citation_refs(packet: ContextPacket) -> List(String) {
  let atom_refs =
    packet.evidence.atoms
    |> list.flat_map(fn(atom) { [atom.id, "evidence:" <> atom.id] })

  list.append(atom_refs, packet.evidence.raw_refs)
}

pub fn policy_citation_refs(packet: ContextPacket) -> List(String) {
  packet.policies
  |> list.map(fn(policy) { policy.source_ref })
}

pub fn concern_citation_refs(packet: ContextPacket) -> List(String) {
  packet.concerns
  |> list.map(fn(concern) { concern.source_ref })
}

fn load_policies(paths: xdg.Paths) -> Result(List(PolicyFile), String) {
  let dir = xdg.policy_dir(paths)
  use _ <- result.try(
    simplifile.create_directory_all(dir)
    |> result.map_error(fn(e) {
      "Failed to create policy directory " <> dir <> ": " <> string.inspect(e)
    }),
  )
  use _ <- result.try(ensure_default_policies(dir))
  use entries <- result.try(
    simplifile.read_directory(dir)
    |> result.map_error(fn(e) {
      "Failed to read policy directory " <> dir <> ": " <> string.inspect(e)
    }),
  )

  entries
  |> list.filter(fn(entry) { string.ends_with(entry, ".md") })
  |> list.sort(string.compare)
  |> list.try_map(fn(entry) {
    let path = dir <> "/" <> entry
    use content <- result.try(read_text_file(path))
    Ok(PolicyFile(
      name: entry,
      path: path,
      source_ref: "policy:" <> entry,
      content: content,
    ))
  })
}

fn ensure_default_policies(dir: String) -> Result(Nil, String) {
  default_policies()
  |> list.try_each(fn(policy) {
    let #(name, content) = policy
    let path = dir <> "/" <> name
    case simplifile.is_file(path) {
      Ok(True) -> Ok(Nil)
      _ ->
        simplifile.write(path, content)
        |> result.map_error(fn(e) {
          "Failed to write default policy " <> path <> ": " <> string.inspect(e)
        })
    }
  })
}

fn load_concerns(paths: xdg.Paths) -> Result(List(ConcernFile), String) {
  let dir = xdg.concerns_dir(paths)
  case simplifile.is_directory(dir) {
    Ok(True) -> {
      use entries <- result.try(
        simplifile.read_directory(dir)
        |> result.map_error(fn(e) {
          "Failed to read concerns directory "
          <> dir
          <> ": "
          <> string.inspect(e)
        }),
      )

      entries
      |> list.filter(fn(entry) { string.ends_with(entry, ".md") })
      |> list.sort(string.compare)
      |> list.try_map(fn(entry) {
        let path = dir <> "/" <> entry
        use content <- result.try(read_text_file(path))
        Ok(ConcernFile(
          name: entry,
          path: path,
          source_ref: "concerns/" <> entry,
          content: content,
        ))
      })
    }
    _ -> Ok([])
  }
}

fn read_text_file(path: String) -> Result(String, String) {
  simplifile.read(path)
  |> result.map_error(fn(e) {
    "Failed to read " <> path <> ": " <> string.inspect(e)
  })
}

fn render_observation(observation: cognitive_event.Observation) -> String {
  "- event_id: "
  <> observation.id
  <> "\n- source: "
  <> observation.source
  <> "\n- event_type: "
  <> observation.event_type
  <> "\n- resource_type: "
  <> observation.resource_type
  <> "\n- resource_id: "
  <> observation.resource_id
  <> "\n- event_time_ms: "
  <> int.to_string(observation.event_time_ms)
  <> "\n- actors: "
  <> string.join(observation.actors, ", ")
  <> "\n- tags: "
  <> render_tags(observation.tags)
  <> "\n- text: "
  <> excerpt(observation.text, 1000)
  <> "\n- raw_ref: "
  <> observation.raw_ref
  <> "\n- raw_data_excerpt: "
  <> excerpt(observation.raw_data, 2000)
}

fn render_tags(tags: dict.Dict(String, String)) -> String {
  let parts =
    tags
    |> dict.to_list
    |> list.sort(fn(a, b) { string.compare(a.0, b.0) })
    |> list.map(fn(entry) {
      let #(key, value) = entry
      key <> "=" <> value
    })

  case parts {
    [] -> "none"
    _ -> string.join(parts, ", ")
  }
}

fn render_evidence(evidence: cognitive_event.EvidenceBundle) -> String {
  let atoms =
    evidence.atoms
    |> list.map(fn(atom) {
      "- "
      <> atom.id
      <> " | kind="
      <> atom.kind
      <> " | source="
      <> atom.source_path
      <> " | confidence="
      <> float_to_short_string(atom.confidence)
      <> " | value="
      <> excerpt(atom.value, 800)
    })

  case atoms {
    [] -> "No evidence atoms."
    _ -> string.join(atoms, "\n")
  }
}

fn render_known_refs(refs: List(String)) -> String {
  refs
  |> list.map(fn(ref) { "- " <> ref })
  |> string.join("\n")
}

fn render_policies(policies: List(PolicyFile)) -> String {
  case policies {
    [] -> "No policy files loaded."
    _ ->
      policies
      |> list.map(fn(policy) {
        "### " <> policy.source_ref <> "\n" <> excerpt(policy.content, 5000)
      })
      |> string.join("\n\n")
  }
}

fn render_concerns(concerns: List(ConcernFile)) -> String {
  case concerns {
    [] -> "No concern files loaded."
    _ ->
      concerns
      |> list.map(fn(concern) {
        "### " <> concern.source_ref <> "\n" <> excerpt(concern.content, 5000)
      })
      |> string.join("\n\n")
  }
}

fn normalize_delivery_targets(targets: List(String)) -> List(String) {
  let with_none = case list.contains(targets, "none") {
    True -> targets
    False -> ["none", ..targets]
  }

  with_none
  |> list.filter(fn(target) { string.trim(target) != "" })
  |> unique_strings
}

fn render_delivery_targets(targets: List(String)) -> String {
  targets
  |> list.map(fn(target) { "- " <> target })
  |> string.join("\n")
}

fn unique_strings(values: List(String)) -> List(String) {
  unique_strings_loop(values, [])
}

fn unique_strings_loop(values: List(String), acc: List(String)) -> List(String) {
  case values {
    [] -> list.reverse(acc)
    [value, ..rest] -> {
      case list.contains(acc, value) {
        True -> unique_strings_loop(rest, acc)
        False -> unique_strings_loop(rest, [value, ..acc])
      }
    }
  }
}

fn excerpt(text: String, limit: Int) -> String {
  case string.length(text) > limit {
    True -> string.slice(text, 0, limit) <> "\n[truncated]"
    False -> text
  }
}

fn float_to_short_string(value: Float) -> String {
  case value >=. 1.0 {
    True -> "1.0"
    False -> "0.8"
  }
}

fn default_policies() -> List(#(String, String)) {
  [
    #("attention.md", attention_policy()),
    #("authority.md", authority_policy()),
    #("work.md", work_policy()),
    #("learning.md", learning_policy()),
    #("delivery.md", delivery_policy()),
    #("world-state.md", world_state_policy()),
  ]
}

fn attention_policy() -> String {
  "# Attention Policy\n\n"
  <> "Aura preserves the user's cognitive capacity. Do not interrupt merely because something changed.\n\n"
  <> "Every attention decision must include a rationale. Record and digest are decisions, not silent defaults.\n\n"
  <> "Synthetic smoke events are verification artifacts. They must be record-only and must not notify, dispatch, mutate memory, or learn preferences.\n\n"
  <> "## Defaults\n"
  <> "- Routine external updates: record.\n"
  <> "- Potentially useful but not time-sensitive updates: digest.\n"
  <> "- Interrupt only when the user must decide now or delay has material cost.\n"
  <> "- Ask now when Aura cannot responsibly proceed without the user's judgment.\n\n"
  <> "## Ask-Now Rule\n"
  <> "Use ask_now, not surface_now, when the event explicitly asks the user to approve, sign off, authorize, reject, choose, or otherwise make a decision under an active deadline or material risk.\n"
  <> "Use surface_now when the user should know urgently but no immediate user decision is being requested.\n\n"
  <> "## Surface-Now Proof\n"
  <> "A surface_now or ask_now decision must explain why now, the cost of deferral, and why digest is insufficient.\n"
}

fn authority_policy() -> String {
  "# Authority Policy\n\n"
  <> "Aura must not perform irreversible, external, financial, credentialed, or reputational actions without authority.\n\n"
  <> "## Gates\n"
  <> "- approval: the user must explicitly approve the action.\n"
  <> "- credential: Aura lacks access or must not request hidden secrets.\n"
  <> "- tool: Aura lacks a tool required to proceed safely.\n"
  <> "- human_judgment: taste, prioritization, or risk judgment belongs to the user.\n"
}

fn work_policy() -> String {
  "# Work Policy\n\n"
  <> "Prefer doing useful preparatory work before spending user attention.\n\n"
  <> "Synthetic smoke events must use work=none; they exist to prove the path, not to start work.\n\n"
  <> "## Defaults\n"
  <> "- none: no work is useful now.\n"
  <> "- prepare: gather context, summarize, or verify before asking.\n"
  <> "- delegate: use a flare or worker when isolated execution is useful.\n"
  <> "- execute: only when the action is reversible and already authorized.\n\n"
  <> "Every non-none work decision must say what proof would show the work is done.\n"
}

fn learning_policy() -> String {
  "# Learning Policy\n\n"
  <> "Conversation is configuration. When Aura encounters a missing reusable preference, record the gap and propose a text-policy change rather than hiding behavior in code.\n\n"
  <> "Do not promote new structure into code until replayed examples show markdown policy plus model judgment is insufficient.\n"
}

fn delivery_policy() -> String {
  "# Delivery Policy\n\n"
  <> "The model chooses a delivery target, but code validates the target before spending user attention.\n\n"
  <> "## Targets\n"
  <> "- none: use only with record. No user-facing delivery.\n"
  <> "- default: use the configured Aura default channel for cross-cutting or unclear routing.\n"
  <> "- domain:<name>: use only when the event clearly belongs to that configured domain.\n\n"
  <> "## Defaults\n"
  <> "- record decisions should use none.\n"
  <> "- digest decisions should use default unless a domain target is clearly better.\n"
  <> "- surface_now and ask_now should use the narrowest valid target that preserves context.\n"
}

fn world_state_policy() -> String {
  "# World-State Policy\n\n"
  <> "World-state sources are ordinary observations. Company news, market changes, launches, commits, tickets, calendar events, and emails use the same decision loop.\n\n"
  <> "Do not treat a source as important by default. Importance depends on the user's concerns, current commitments, policy, and cited evidence.\n"
}
