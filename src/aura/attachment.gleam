//// Attachment preprocessing: download all attachments to /tmp, inline text
//// file content, and prepend path reference lines to the user message.
////
//// This module is called synchronously in `channel_actor.start_turn` before
//// building the LLM message. Downloads are best-effort: failures are logged
//// but never block the message. Image attachments are downloaded here too so
//// the vision path can prefer a local `data:` URL over the Discord CDN URL
//// (CDN URLs with HMAC query strings get rejected by some vision endpoints).

import aura/discord
import aura/discord/types as discord_types
import aura/web
import gleam/int
import gleam/list
import gleam/string
import logging
import simplifile

const attachment_tmp_base = "/tmp/aura-attachments"

const attachment_download_timeout_ms = 30_000

/// Preprocess all attachments in a Discord message:
///  1. Download every attachment to /tmp/aura-attachments/<msg_id>/
///  2. Prepend `[attachment: /path] filename` lines to the content
///  3. Inline text file content as `[File: name]\n```\ncontent\n```\n`
///
/// Returns the enriched content string. Gracefully degrades on failures.
pub fn preprocess(msg: discord.IncomingMessage) -> String {
  case msg.attachments {
    [] -> msg.content
    attachments -> {
      let path_lines =
        download_attachments_to_tmp(attachments, msg.message_id)
      let text_content = fetch_text_attachments(attachments, msg.message_id)
      let with_paths = case path_lines {
        "" -> msg.content
        p -> p <> "\n\n" <> msg.content
      }
      case text_content {
        "" -> with_paths
        content -> content <> "\n\n" <> with_paths
      }
    }
  }
}

/// Build the path where an attachment would be saved in the tmp dir.
/// Exported so vision path in channel_actor can resolve the local file.
pub fn local_path(msg_id: String, filename: String) -> String {
  attachment_dir(msg_id) <> "/" <> safe_filename(filename)
}

fn attachment_dir(msg_id: String) -> String {
  attachment_tmp_base <> "/" <> msg_id
}

/// Drop path separators and navigation elements from a user-supplied
/// filename so it can't escape the per-message tmp dir.
fn safe_filename(name: String) -> String {
  let segments =
    name
    |> string.replace("\\", "/")
    |> string.split("/")
  case list.last(segments) {
    Ok("") | Ok(".") | Ok("..") | Error(_) -> "attachment"
    Ok(seg) -> seg
  }
}

/// Download every attachment to /tmp/aura-attachments/<msg_id>/ and return
/// one line per attachment formatted as `[attachment: /path] filename`.
/// Best-effort: failures are logged but don't block the message.
fn download_attachments_to_tmp(
  attachments: List(discord_types.Attachment),
  msg_id: String,
) -> String {
  let dir = attachment_dir(msg_id)
  case simplifile.create_directory_all(dir) {
    Error(e) -> {
      logging.log(
        logging.Error,
        "[attachment] Dir create failed for "
          <> dir
          <> ": "
          <> simplifile.describe_error(e),
      )
      ""
    }
    Ok(_) -> {
      let lines =
        list.filter_map(attachments, fn(att) {
          let path = dir <> "/" <> safe_filename(att.filename)
          case web.fetch_bytes(att.url, attachment_download_timeout_ms) {
            Error(e) -> {
              logging.log(
                logging.Error,
                "[attachment] Download failed for "
                  <> att.filename
                  <> ": "
                  <> e,
              )
              Error(Nil)
            }
            Ok(bytes) ->
              case simplifile.write_bits(path, bytes) {
                Error(e) -> {
                  logging.log(
                    logging.Error,
                    "[attachment] Write failed for "
                      <> path
                      <> ": "
                      <> simplifile.describe_error(e),
                  )
                  Error(Nil)
                }
                Ok(_) -> {
                  logging.log(
                    logging.Info,
                    "[attachment] Saved: " <> path,
                  )
                  Ok("[attachment: " <> path <> "] " <> att.filename)
                }
              }
          }
        })
      string.join(lines, "\n")
    }
  }
}

/// Read text file attachments and return their content for inlining.
/// Prefers the local copy at /tmp/aura-attachments/<msg_id>/; falls back to
/// CDN fetch when the download hook left no file on disk.
fn fetch_text_attachments(
  attachments: List(discord_types.Attachment),
  msg_id: String,
) -> String {
  let dir = attachment_dir(msg_id)
  let text_parts =
    list.filter_map(attachments, fn(att) {
      case is_text_attachment(att) {
        False -> Error(Nil)
        True -> {
          let local = dir <> "/" <> safe_filename(att.filename)
          let content_result = case simplifile.read(local) {
            Ok(content) -> Ok(content)
            Error(_) -> web.fetch(att.url, 50_000)
          }
          case content_result {
            Ok(content) -> {
              logging.log(
                logging.Info,
                "[attachment] Inlining text attachment "
                  <> att.filename
                  <> " ("
                  <> int.to_string(string.length(content))
                  <> " chars)",
              )
              Ok(
                "[File: "
                <> att.filename
                <> "]\n```\n"
                <> content
                <> "\n```",
              )
            }
            Error(e) -> {
              logging.log(
                logging.Error,
                "[attachment] Failed to read " <> att.filename <> ": " <> e,
              )
              Error(Nil)
            }
          }
        }
      }
    })
  string.join(text_parts, "\n\n")
}

fn is_text_attachment(att: discord_types.Attachment) -> Bool {
  let ct = string.lowercase(att.content_type)
  let fn_lower = string.lowercase(att.filename)
  string.starts_with(ct, "text/")
  || string.ends_with(fn_lower, ".json")
  || string.ends_with(fn_lower, ".toml")
  || string.ends_with(fn_lower, ".yaml")
  || string.ends_with(fn_lower, ".yml")
  || string.ends_with(fn_lower, ".md")
  || string.ends_with(fn_lower, ".gleam")
  || string.ends_with(fn_lower, ".rs")
  || string.ends_with(fn_lower, ".py")
  || string.ends_with(fn_lower, ".js")
  || string.ends_with(fn_lower, ".ts")
  || string.ends_with(fn_lower, ".swift")
  || string.ends_with(fn_lower, ".sh")
  || string.ends_with(fn_lower, ".sql")
  || string.ends_with(fn_lower, ".csv")
  || string.ends_with(fn_lower, ".xml")
  || string.ends_with(fn_lower, ".html")
  || string.ends_with(fn_lower, ".css")
  || string.ends_with(fn_lower, ".erl")
  || string.ends_with(fn_lower, ".ex")
  || string.ends_with(fn_lower, ".go")
  || string.ends_with(fn_lower, ".java")
  || string.ends_with(fn_lower, ".kt")
  || string.ends_with(fn_lower, ".c")
  || string.ends_with(fn_lower, ".h")
  || string.ends_with(fn_lower, ".cpp")
  || string.ends_with(fn_lower, ".log")
  || string.ends_with(fn_lower, ".env")
  || string.ends_with(fn_lower, ".cfg")
  || string.ends_with(fn_lower, ".ini")
  || string.ends_with(fn_lower, ".conf")
  || ct == "application/json"
  || ct == "application/xml"
  || ct == "application/toml"
}
