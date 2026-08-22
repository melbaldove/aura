//// Transport-independent operational domain manifests and legacy adapters.

import aura/config
import aura/operating_contracts
import aura/xdg
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import simplifile

/// The minimal operational domain record. Development and compatibility
/// metadata is optional.
pub type Record {
  Record(
    domain_id: String,
    slug: String,
    display_name: String,
    aliases: List(String),
    purpose: String,
    status: String,
    cwd: Option(String),
    discord_channel: Option(String),
    version: Int,
    created_at: Int,
    updated_at: Int,
  )
}

/// A domain plus the source used to load it.
pub type Loaded {
  Loaded(record: Record, origin: String)
}

/// Derive one stable domain ID from a display name or slug.
pub fn derive_domain_id(value: String) -> String {
  "domain:" <> config.normalize_domain_slug(value)
}

/// Normalize aliases and remove duplicates while preserving input order.
pub fn normalize_aliases(values: List(String)) -> List(String) {
  values
  |> list.fold([], fn(acc, value) {
    let normalized = config.normalize_domain_slug(value)
    case normalized == "" || list.contains(acc, normalized) {
      True -> acc
      False -> list.append(acc, [normalized])
    }
  })
}

/// Write one operational manifest. This does not write a legacy config file.
pub fn write(paths: xdg.Paths, record: Record) -> Result(Nil, String) {
  use _ <- result.try(validate_record(record))
  let path = xdg.domain_manifest_path(paths, record.slug)
  use _ <- result.try(
    simplifile.create_directory_all(xdg.domain_data_dir(paths, record.slug))
    |> result.map_error(fn(error) {
      "Failed to create domain data directory: " <> string.inspect(error)
    }),
  )
  simplifile.write(path, encode_record(record))
  |> result.map_error(fn(error) {
    "Failed to write domain manifest " <> path <> ": " <> string.inspect(error)
  })
}

/// Load a manifest first. If it is absent, adapt one legacy config in memory.
/// The compatibility read never writes a manifest.
pub fn load(paths: xdg.Paths, slug: String) -> Result(Loaded, String) {
  let normalized_slug = config.normalize_domain_slug(slug)
  use _ <- result.try(case normalized_slug == "" {
    True -> Error("invalid_domain_slug")
    False -> Ok(Nil)
  })
  let manifest_path = xdg.domain_manifest_path(paths, normalized_slug)
  case simplifile.read(manifest_path) {
    Ok(raw) ->
      operating_contracts.decode_domain(raw)
      |> result.map(contract_to_record)
      |> result.map(fn(record) { Loaded(record:, origin: "manifest") })
      |> result.map_error(fn(error) {
        "Invalid domain manifest " <> manifest_path <> ": " <> error
      })
    Error(simplifile.Enoent) -> load_legacy(paths, normalized_slug)
    Error(error) ->
      Error(
        "Failed to read domain manifest "
        <> manifest_path
        <> ": "
        <> string.inspect(error),
      )
  }
}

/// Load a domain when a manifest or legacy config exists. Missing records
/// return `None`. Invalid or unreadable records return an error.
pub fn load_optional(
  paths: xdg.Paths,
  slug: String,
) -> Result(Option(Loaded), String) {
  let normalized_slug = config.normalize_domain_slug(slug)
  let manifest_path = xdg.domain_manifest_path(paths, normalized_slug)
  let legacy_path = xdg.domain_config_path(paths, normalized_slug)
  case simplifile.is_file(manifest_path), simplifile.is_file(legacy_path) {
    Ok(True), _ | _, Ok(True) ->
      load(paths, normalized_slug) |> result.map(Some)
    Ok(False), Ok(False) -> Ok(None)
    Error(error), _ | _, Error(error) ->
      Error("Failed to inspect domain record: " <> string.inspect(error))
  }
}

/// Explicitly copy one legacy config into an operational manifest. Repeated
/// calls return the first manifest and do not rewrite it.
pub fn migrate_legacy(
  paths: xdg.Paths,
  slug: String,
  migrated_at: Int,
) -> Result(Record, String) {
  let normalized_slug = config.normalize_domain_slug(slug)
  case simplifile.is_file(xdg.domain_manifest_path(paths, normalized_slug)) {
    Ok(True) -> {
      use loaded <- result.try(load(paths, normalized_slug))
      Ok(loaded.record)
    }
    _ -> {
      use loaded <- result.try(load_legacy(paths, normalized_slug))
      let record =
        Record(
          ..loaded.record,
          created_at: migrated_at,
          updated_at: migrated_at,
        )
      use _ <- result.try(write(paths, record))
      Ok(record)
    }
  }
}

fn load_legacy(paths: xdg.Paths, slug: String) -> Result(Loaded, String) {
  let path = xdg.domain_config_path(paths, slug)
  use raw <- result.try(
    simplifile.read(path)
    |> result.map_error(fn(error) {
      case error {
        simplifile.Enoent -> "Domain not found: " <> slug
        _ ->
          "Failed to read legacy domain config "
          <> path
          <> ": "
          <> string.inspect(error)
      }
    }),
  )
  use legacy <- result.try(config.parse_domain(raw))
  let record =
    Record(
      domain_id: legacy.domain_id,
      slug: slug,
      display_name: legacy.name,
      aliases: normalize_aliases(legacy.aliases),
      purpose: legacy.purpose,
      status: legacy.status,
      cwd: non_empty(legacy.cwd),
      discord_channel: non_empty(legacy.discord_channel),
      version: 1,
      created_at: 0,
      updated_at: 0,
    )
  use _ <- result.try(validate_record(record))
  Ok(Loaded(record:, origin: "legacy_config"))
}

fn validate_record(record: Record) -> Result(Nil, String) {
  case
    record.slug == ""
    || config.normalize_domain_slug(record.slug) != record.slug
    || record.domain_id == ""
    || !string.starts_with(record.domain_id, "domain:")
    || string.trim(record.display_name) == ""
    || string.trim(record.purpose) == ""
  {
    True -> Error("invalid_domain_record")
    False ->
      case record.status {
        "active" | "paused" | "archived" -> Ok(Nil)
        _ -> Error("invalid_domain_status")
      }
  }
}

fn encode_record(record: Record) -> String {
  operating_contracts.Domain(
    schema_version: 1,
    domain_id: record.domain_id,
    slug: record.slug,
    display_name: record.display_name,
    aliases: normalize_aliases(record.aliases),
    purpose: record.purpose,
    status: record.status,
    context_refs: [],
    default_authority_policy_ref: None,
    cwd: record.cwd,
    compatibility_transports: case record.discord_channel {
      Some(channel) -> ["discord:" <> channel]
      None -> []
    },
    version: record.version,
    created_at: record.created_at,
    updated_at: record.updated_at,
  )
  |> operating_contracts.encode_domain
}

fn contract_to_record(contract: operating_contracts.Domain) -> Record {
  Record(
    domain_id: contract.domain_id,
    slug: contract.slug,
    display_name: contract.display_name,
    aliases: normalize_aliases(contract.aliases),
    purpose: contract.purpose,
    status: contract.status,
    cwd: contract.cwd,
    discord_channel: contract.compatibility_transports
      |> list.find_map(fn(binding) {
        case string.starts_with(binding, "discord:") {
          True -> Ok(string.drop_start(binding, string.length("discord:")))
          False -> Error(Nil)
        }
      })
      |> result.map(Some)
      |> result.unwrap(None),
    version: contract.version,
    created_at: contract.created_at,
    updated_at: contract.updated_at,
  )
}

fn non_empty(value: String) -> Option(String) {
  case string.trim(value) {
    "" -> None
    present -> Some(present)
  }
}
