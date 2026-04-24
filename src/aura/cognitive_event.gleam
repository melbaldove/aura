import aura/event
import gleam/dict
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/regexp
import gleam/string

/// Source-neutral observation derived from an external `AuraEvent`.
pub type Observation {
  Observation(
    id: String,
    source: String,
    resource_id: String,
    resource_type: String,
    event_type: String,
    event_time_ms: Int,
    actors: List(String),
    tags: dict.Dict(String, String),
    text: String,
    state_before: String,
    state_after: String,
    raw_ref: String,
    raw_data: String,
  )
}

/// A citable fact extracted deterministically from an observation.
pub type EvidenceAtom {
  EvidenceAtom(
    id: String,
    kind: String,
    value: String,
    source_path: String,
    text_span: String,
    confidence: Float,
    provenance: String,
  )
}

/// A source resource referenced by one or more evidence atoms.
pub type ResourceRef {
  ResourceRef(kind: String, id: String, source_path: String)
}

/// The deterministic fact set available to the cognitive interpreter.
pub type EvidenceBundle {
  EvidenceBundle(
    observation_id: String,
    atoms: List(EvidenceAtom),
    resource_refs: List(ResourceRef),
    raw_refs: List(String),
  )
}

type RawAtom {
  RawAtom(
    kind: String,
    value: String,
    source_path: String,
    text_span: String,
    confidence: Float,
    provenance: String,
  )
}

/// Project an ingested event into the source-neutral observation shape.
pub fn from_event(e: event.AuraEvent) -> Observation {
  let actors =
    [
      tag_value(e.tags, "from"),
      tag_value(e.tags, "to"),
      tag_value(e.tags, "author"),
    ]
    |> list.filter(fn(value) { value != "" })

  Observation(
    id: e.id,
    source: e.source,
    resource_id: e.external_id,
    resource_type: resource_type_for(e.source, e.type_),
    event_type: e.type_,
    event_time_ms: e.time_ms,
    actors: actors,
    tags: e.tags,
    text: e.subject,
    state_before: "",
    state_after: "",
    raw_ref: e.source <> ":" <> e.external_id,
    raw_data: e.data,
  )
}

/// Extract source-direct and generic text evidence from an observation.
pub fn extract_evidence(observation: Observation) -> EvidenceBundle {
  let base_atoms =
    [
      raw_atom(
        "event_source",
        observation.source,
        "source",
        "",
        1.0,
        "observation",
      ),
      raw_atom(
        "event_type",
        observation.event_type,
        "event_type",
        "",
        1.0,
        "observation",
      ),
      raw_atom(
        "resource_id",
        observation.resource_id,
        "resource_id",
        "",
        1.0,
        "observation",
      ),
      raw_atom("text", observation.text, "text", "", 1.0, "observation"),
    ]
    |> list.filter(fn(a) { a.value != "" })

  let tag_atoms = extract_tag_atoms(observation)
  let json_atoms = extract_json_atoms(observation.raw_data)
  let text_atoms = extract_text_atoms(observation.text)

  let atoms =
    list.append(
      base_atoms,
      list.append(tag_atoms, list.append(json_atoms, text_atoms)),
    )
    |> dedupe_raw_atoms
    |> assign_ids(observation.id)

  EvidenceBundle(
    observation_id: observation.id,
    atoms: atoms,
    resource_refs: resource_refs(atoms),
    raw_refs: [observation.raw_ref],
  )
}

fn resource_type_for(source: String, event_type: String) -> String {
  let lowered = string.lowercase(source <> " " <> event_type)
  case string.contains(lowered, "gmail") {
    True -> "email"
    False ->
      case
        string.contains(lowered, "linear") || string.contains(lowered, "jira")
      {
        True -> "ticket"
        False ->
          case string.contains(lowered, "calendar") {
            True -> "calendar_event"
            False ->
              case
                string.contains(lowered, "github")
                || string.contains(lowered, "git")
              {
                True -> "repository_event"
                False ->
                  case string.contains(lowered, "ci") {
                    True -> "verification_event"
                    False ->
                      case string.contains(lowered, "world") {
                        True -> "world_state"
                        False -> "external_resource"
                      }
                  }
              }
          }
      }
  }
}

fn tag_value(tags: dict.Dict(String, String), key: String) -> String {
  case dict.get(tags, key) {
    Ok(value) -> value
    Error(_) -> ""
  }
}

fn raw_atom(
  kind: String,
  value: String,
  source_path: String,
  text_span: String,
  confidence: Float,
  provenance: String,
) -> RawAtom {
  RawAtom(
    kind: kind,
    value: value,
    source_path: source_path,
    text_span: text_span,
    confidence: confidence,
    provenance: provenance,
  )
}

fn assign_ids(
  atoms: List(RawAtom),
  observation_id: String,
) -> List(EvidenceAtom) {
  atoms
  |> list.index_map(fn(a, index) {
    EvidenceAtom(
      id: observation_id <> ":e" <> int.to_string(index + 1),
      kind: a.kind,
      value: a.value,
      source_path: a.source_path,
      text_span: a.text_span,
      confidence: a.confidence,
      provenance: a.provenance,
    )
  })
}

fn dedupe_raw_atoms(atoms: List(RawAtom)) -> List(RawAtom) {
  dedupe_raw_atoms_loop(atoms, [])
}

fn dedupe_raw_atoms_loop(
  remaining: List(RawAtom),
  kept: List(RawAtom),
) -> List(RawAtom) {
  case remaining {
    [] -> list.reverse(kept)
    [atom, ..rest] -> {
      case has_raw_atom(kept, atom.kind, atom.value) {
        True -> dedupe_raw_atoms_loop(rest, kept)
        False -> dedupe_raw_atoms_loop(rest, [atom, ..kept])
      }
    }
  }
}

fn has_raw_atom(atoms: List(RawAtom), kind: String, value: String) -> Bool {
  list.any(atoms, fn(atom) { atom.kind == kind && atom.value == value })
}

fn extract_tag_atoms(observation: Observation) -> List(RawAtom) {
  observation.tags
  |> dict.to_list
  |> list.filter_map(fn(entry) {
    let #(key, value) = entry
    case value {
      "" -> Error(Nil)
      _ ->
        Ok(raw_atom(tag_kind(key, value), value, "tags." <> key, "", 1.0, "tag"))
    }
  })
}

fn tag_kind(key: String, value: String) -> String {
  case key {
    "from" -> "actor_email"
    "to" -> "actor_email"
    "author" -> "actor_email"
    "ticket_id" -> "resource_id"
    "thread_id" -> "thread_id"
    "message_id" -> "message_id"
    "status" -> "status"
    "subject_line" -> "text"
    _ ->
      case string.contains(value, "@") {
        True -> "actor_email"
        False -> "tag"
      }
  }
}

fn extract_json_atoms(data: String) -> List(RawAtom) {
  case json.parse(data, decode.dynamic) {
    Ok(payload) ->
      [
        json_atom(payload, "actor_email", ["from"]),
        json_atom(payload, "actor_email", ["to"]),
        json_atom(payload, "actor_email", ["comment", "user", "email"]),
        json_atom(payload, "actor_email", ["issue", "assignee", "email"]),
        json_atom(payload, "message_id", ["message_id"]),
        json_atom(payload, "thread_id", ["thread_id"]),
        json_atom(payload, "resource_id", ["issue", "identifier"]),
        json_atom(payload, "resource_id", ["ticket", "key"]),
        json_atom(payload, "resource_id", ["repository", "full_name"]),
        json_atom(payload, "status", ["status"]),
        json_atom(payload, "status", ["conclusion"]),
        json_atom(payload, "status", ["issue", "state", "name"]),
        json_atom(payload, "url", ["url"]),
        json_atom(payload, "url", ["html_url"]),
        json_atom(payload, "datetime", ["date"]),
        json_atom(payload, "datetime", ["start"]),
        json_atom(payload, "datetime", ["end"]),
        json_atom(payload, "branch", ["branch"]),
        json_atom(payload, "commit_sha", ["commit"]),
        json_atom(payload, "commit_sha", ["sha"]),
      ]
      |> list.filter_map(fn(result) { result })
    Error(_) -> []
  }
}

fn json_atom(
  payload: Dynamic,
  kind: String,
  path: List(String),
) -> Result(RawAtom, Nil) {
  case decode.run(payload, decode.at(path, decode.string)) {
    Ok(value) ->
      case value {
        "" -> Error(Nil)
        _ ->
          Ok(raw_atom(
            kind,
            value,
            "data." <> string.join(path, "."),
            "",
            1.0,
            "json",
          ))
      }
    _ -> Error(Nil)
  }
}

fn extract_text_atoms(text: String) -> List(RawAtom) {
  [
    scan("actor_email", "[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}", text),
    scan("url", "https?://[^\\s\\\"'<>]+", text),
    scan("resource_id", "\\b[A-Z][A-Z0-9]+-[0-9]+\\b", text),
    scan(
      "datetime",
      "\\b\\d{4}-\\d{2}-\\d{2}\\b|\\b(today|tomorrow|yesterday)\\b",
      text,
    ),
    scan("commit_sha", "\\b[0-9a-f]{7,40}\\b", text),
    scan("branch", "\\b[a-zA-Z0-9._-]+/[a-zA-Z0-9._/-]+\\b", text),
  ]
  |> list.flatten
}

fn scan(kind: String, pattern: String, text: String) -> List(RawAtom) {
  let opts = regexp.Options(case_insensitive: True, multi_line: False)
  case regexp.compile(pattern, opts) {
    Ok(re) ->
      regexp.scan(with: re, content: text)
      |> list.map(fn(m) {
        raw_atom(kind, m.content, "text", "match:" <> m.content, 0.8, "text")
      })
    Error(_) -> []
  }
}

fn resource_refs(atoms: List(EvidenceAtom)) -> List(ResourceRef) {
  atoms
  |> list.filter_map(fn(atom) {
    case atom.kind {
      "resource_id" -> Ok(ResourceRef("resource", atom.value, atom.source_path))
      "message_id" -> Ok(ResourceRef("message", atom.value, atom.source_path))
      "thread_id" -> Ok(ResourceRef("thread", atom.value, atom.source_path))
      "url" -> Ok(ResourceRef("url", atom.value, atom.source_path))
      _ -> Error(Nil)
    }
  })
}
