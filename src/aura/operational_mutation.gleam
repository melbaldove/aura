//// Structured, idempotent domain and concern command mutations.

import aura/config
import aura/db
import aura/domain_registry
import aura/operating_contracts
import aura/time
import aura/xdg
import gleam/dict
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some, unwrap}
import gleam/result
import gleam/string
import simplifile

/// Compact operational result. It contains no conversation transcript.
pub type MutationResult {
  MutationResult(
    status: String,
    target_type: String,
    target_id: String,
    source_ref: String,
  )
}

/// Apply one validated Voice-originated mutation.
pub fn apply(
  paths: xdg.Paths,
  db_subject: process.Subject(db.DbMessage),
  command: operating_contracts.CommandMutation,
) -> Result(MutationResult, String) {
  use validated <- result.try(
    command
    |> operating_contracts.encode_command_mutation
    |> operating_contracts.decode_command_mutation,
  )
  case validated.intent_kind {
    "domain.upsert" -> apply_domain_upsert(paths, db_subject, validated)
    "concern.upsert" | "concern.pause" | "concern.close" ->
      apply_concern_mutation(paths, db_subject, validated)
    other -> Error("unsupported_mutation: " <> other)
  }
}

fn apply_domain_upsert(
  paths: xdg.Paths,
  db_subject: process.Subject(db.DbMessage),
  command: operating_contracts.CommandMutation,
) -> Result(MutationResult, String) {
  use display_name <- result.try(required_string(command, "display_name"))
  let slug =
    optional_string(command, "slug")
    |> unwrap(config.normalize_domain_slug(display_name))
  use _ <- result.try(validate_slug(slug, "domain"))
  let domain_id =
    optional_string(command, "domain_id")
    |> unwrap(domain_registry.derive_domain_id(slug))
  let purpose =
    optional_string(command, "purpose")
    |> unwrap(display_name)
  let aliases = optional_strings(command, "aliases") |> unwrap([])
  let status = optional_string(command, "status") |> unwrap("active")
  let cwd = optional_string(command, "cwd")
  let discord_channel = optional_string(command, "discord_channel")
  let target =
    MutationResult(
      status: "applied",
      target_type: "domain",
      target_id: domain_id,
      source_ref: "domains/" <> slug <> "/domain.json",
    )
  let payload_json =
    json.object([
      #("domain_id", json.string(domain_id)),
      #("slug", json.string(slug)),
      #("display_name", json.string(display_name)),
      #(
        "aliases",
        json.array(domain_registry.normalize_aliases(aliases), json.string),
      ),
      #("purpose", json.string(purpose)),
      #("status", json.string(status)),
      #("cwd", json.nullable(cwd, of: json.string)),
      #("discord_channel", json.nullable(discord_channel, of: json.string)),
      #("creation_basis", json.string(command.creation_basis)),
    ])
    |> json.to_string
  use existing <- result.try(domain_registry.load_optional(paths, slug))

  case command.creation_basis {
    "inferred" ->
      case existing {
        Some(loaded) ->
          Ok(MutationResult(
            status: "existing",
            target_type: "domain",
            target_id: loaded.record.domain_id,
            source_ref: "domains/" <> slug <> "/domain.json",
          ))
        None -> Ok(MutationResult(..target, status: "confirmation_required"))
      }
    "explicit" | "confirmed" -> {
      use _ <- result.try(case existing {
        Some(loaded) if loaded.record.domain_id != domain_id ->
          Error("domain_id_conflict: " <> loaded.record.domain_id)
        _ -> Ok(Nil)
      })
      let now = time.now_ms()
      use replay <- result.try(db.claim_operational_mutation(
        db_subject,
        command.idempotency_key,
        command.intent_kind,
        payload_json,
        now,
      ))
      case replay {
        Some(receipt) -> await_completed_result(db_subject, receipt, 500)
        None -> {
          let #(version, created_at) = case existing {
            Some(loaded) -> #(
              loaded.record.version + 1,
              loaded.record.created_at,
            )
            None -> #(1, now)
          }
          let record =
            domain_registry.Record(
              domain_id:,
              slug:,
              display_name:,
              aliases: domain_registry.normalize_aliases(aliases),
              purpose:,
              status:,
              cwd:,
              discord_channel:,
              version:,
              created_at:,
              updated_at: now,
            )
          use _ <- result.try(case domain_registry.write(paths, record) {
            Ok(_) -> Ok(Nil)
            Error(error) -> {
              let _ =
                db.abandon_operational_mutation(
                  db_subject,
                  command.idempotency_key,
                  command.intent_kind,
                  payload_json,
                )
              Error(error)
            }
          })
          let result_json = encode_result(target)
          db.complete_operational_mutation(
            db_subject,
            command.idempotency_key,
            command.intent_kind,
            payload_json,
            "domain",
            domain_id,
            "domain.upserted",
            result_json,
            None,
            now,
          )
          |> result.map(fn(_) { target })
          |> result.map_error(fn(error) {
            "effect_unknown: domain manifest changed but receipt failed: "
            <> error
          })
        }
      }
    }
    other -> Error("invalid_creation_basis: " <> other)
  }
}

fn apply_concern_mutation(
  paths: xdg.Paths,
  db_subject: process.Subject(db.DbMessage),
  command: operating_contracts.CommandMutation,
) -> Result(MutationResult, String) {
  use domain_id <- result.try(required_string(command, "domain_id"))
  use concern_slug <- result.try(required_string(command, "slug"))
  use _ <- result.try(validate_slug(concern_slug, "concern"))
  let domain_slug = string.drop_start(domain_id, string.length("domain:"))
  use domain <- result.try(
    domain_registry.load(paths, domain_slug)
    |> result.map_error(fn(_) { "unknown_domain: " <> domain_id }),
  )
  use _ <- result.try(case domain.record.domain_id == domain_id {
    True -> Ok(Nil)
    False -> Error("cross_domain_link: " <> domain_id)
  })
  let concern_id = "concern:" <> domain_id <> ":" <> concern_slug
  let title = optional_string(command, "title") |> unwrap(concern_slug)
  let summary = optional_string(command, "summary") |> unwrap("")
  let status = case command.intent_kind {
    "concern.pause" -> "paused"
    "concern.close" -> "closed"
    _ -> "active"
  }
  let path =
    xdg.domain_concerns_dir(paths, domain_slug) <> "/" <> concern_slug <> ".md"
  use _ <- result.try(
    case
      command.intent_kind != "concern.upsert"
      && simplifile.is_file(path) != Ok(True)
    {
      True -> Error("concern_not_found: " <> concern_id)
      False -> Ok(Nil)
    },
  )
  let payload_json = case command.intent_kind {
    "concern.upsert" ->
      json.object([
        #("domain_id", json.string(domain_id)),
        #("concern_id", json.string(concern_id)),
        #("slug", json.string(concern_slug)),
        #("title", json.string(title)),
        #("summary", json.string(summary)),
        #("status", json.string(status)),
      ])
      |> json.to_string
    _ ->
      json.object([
        #("domain_id", json.string(domain_id)),
        #("concern_id", json.string(concern_id)),
        #("status", json.string(status)),
      ])
      |> json.to_string
  }
  let now = time.now_ms()
  use replay <- result.try(db.claim_operational_mutation(
    db_subject,
    command.idempotency_key,
    command.intent_kind,
    payload_json,
    now,
  ))
  case replay {
    Some(receipt) -> await_completed_result(db_subject, receipt, 500)
    None -> {
      use _ <- result.try(
        simplifile.create_directory_all(xdg.domain_concerns_dir(
          paths,
          domain_slug,
        ))
        |> result.map_error(fn(error) {
          "Failed to create domain concerns directory: "
          <> string.inspect(error)
        }),
      )
      use content <- result.try(case command.intent_kind {
        "concern.upsert" ->
          Ok(
            "# "
            <> title
            <> "\n\nStatus: "
            <> status
            <> "\nDomain-ID: "
            <> domain_id
            <> "\nConcern-ID: "
            <> concern_id
            <> "\nSlug: "
            <> concern_slug
            <> "\nUpdated: "
            <> int.to_string(now)
            <> "\n\n## Summary\n"
            <> summary
            <> "\n",
          )
        _ ->
          simplifile.read(path)
          |> result.map(fn(existing_content) {
            update_concern_status(existing_content, status, now)
          })
          |> result.map_error(fn(error) {
            "Failed to read domain concern "
            <> path
            <> ": "
            <> string.inspect(error)
          })
      })
      use _ <- result.try(case simplifile.write(path, content) {
        Ok(_) -> Ok(Nil)
        Error(error) -> {
          let _ =
            db.abandon_operational_mutation(
              db_subject,
              command.idempotency_key,
              command.intent_kind,
              payload_json,
            )
          Error(
            "Failed to write domain concern "
            <> path
            <> ": "
            <> string.inspect(error),
          )
        }
      })
      let mutation_result =
        MutationResult(
          status: "applied",
          target_type: "concern",
          target_id: concern_id,
          source_ref: "domains/"
            <> domain_slug
            <> "/concerns/"
            <> concern_slug
            <> ".md",
        )
      db.complete_operational_mutation(
        db_subject,
        command.idempotency_key,
        command.intent_kind,
        payload_json,
        "concern",
        concern_id,
        command.intent_kind <> "d",
        encode_result(mutation_result),
        Some(domain_id),
        now,
      )
      |> result.map(fn(_) { mutation_result })
      |> result.map_error(fn(error) {
        "effect_unknown: concern file changed but receipt failed: " <> error
      })
    }
  }
}

fn await_completed_result(
  db_subject: process.Subject(db.DbMessage),
  receipt: db.MutationReceipt,
  attempts_remaining: Int,
) -> Result(MutationResult, String) {
  case receipt.result_version > 0 {
    True -> decode_result(receipt.result_json)
    False if attempts_remaining <= 0 -> Error("mutation_in_progress")
    False -> {
      process.sleep(10)
      use current <- result.try(db.get_mutation_receipt(
        db_subject,
        receipt.idempotency_key,
      ))
      case current {
        Some(next) ->
          await_completed_result(db_subject, next, attempts_remaining - 1)
        None -> Error("mutation_claim_lost")
      }
    }
  }
}

fn update_concern_status(
  content: String,
  status: String,
  updated_at: Int,
) -> String {
  content
  |> string.split("\n")
  |> list.map(fn(line) {
    case string.starts_with(line, "Status: ") {
      True -> "Status: " <> status
      False ->
        case string.starts_with(line, "Updated: ") {
          True -> "Updated: " <> int.to_string(updated_at)
          False -> line
        }
    }
  })
  |> string.join("\n")
}

fn required_string(
  command: operating_contracts.CommandMutation,
  key: String,
) -> Result(String, String) {
  case optional_string(command, key) {
    Some(value) -> Ok(value)
    None -> Error("missing_field: " <> key)
  }
}

fn optional_string(
  command: operating_contracts.CommandMutation,
  key: String,
) -> Option(String) {
  case dict.get(command.structured_payload, key) {
    Ok(operating_contracts.StructuredString(value)) ->
      case string.trim(value) {
        "" -> None
        present -> Some(present)
      }
    _ -> None
  }
}

fn optional_strings(
  command: operating_contracts.CommandMutation,
  key: String,
) -> Option(List(String)) {
  case dict.get(command.structured_payload, key) {
    Ok(operating_contracts.StructuredArray(values)) ->
      values
      |> list.try_map(fn(value) {
        case value {
          operating_contracts.StructuredString(text) -> Ok(text)
          _ -> Error(Nil)
        }
      })
      |> result.map(Some)
      |> result.unwrap(None)
    _ -> None
  }
}

fn validate_slug(value: String, kind: String) -> Result(Nil, String) {
  case config.normalize_domain_slug(value) == value && value != "" {
    True -> Ok(Nil)
    False -> Error("invalid_" <> kind <> "_slug: " <> value)
  }
}

fn encode_result(value: MutationResult) -> String {
  json.object([
    #("status", json.string(value.status)),
    #("target_type", json.string(value.target_type)),
    #("target_id", json.string(value.target_id)),
    #("source_ref", json.string(value.source_ref)),
  ])
  |> json.to_string
}

fn decode_result(raw: String) -> Result(MutationResult, String) {
  json.parse(raw, {
    use status <- decode.field("status", decode.string)
    use target_type <- decode.field("target_type", decode.string)
    use target_id <- decode.field("target_id", decode.string)
    use source_ref <- decode.field("source_ref", decode.string)
    decode.success(MutationResult(
      status:,
      target_type:,
      target_id:,
      source_ref:,
    ))
  })
  |> result.map_error(fn(error) {
    "invalid_mutation_receipt: " <> string.inspect(error)
  })
}
