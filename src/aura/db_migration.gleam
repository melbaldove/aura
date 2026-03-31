import aura/db
import aura/time
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/json
import gleam/list
import gleam/result
import gleam/string
import simplifile

/// Migrate existing JSONL conversation files to SQLite.
/// Scans {data_dir}/conversations/ for .jsonl files.
/// Each file's name (minus .jsonl) is the Discord channel_id.
/// Returns count of migrated messages.
pub fn migrate_jsonl(
  db_subject: process.Subject(db.DbMessage),
  data_dir: String,
) -> Result(Int, String) {
  let conv_dir = data_dir <> "/conversations"
  case simplifile.read_directory(conv_dir) {
    Error(_) -> Ok(0)
    Ok(entries) -> {
      let jsonl_files =
        list.filter(entries, fn(e) { string.ends_with(e, ".jsonl") })
      case jsonl_files {
        [] -> Ok(0)
        _ -> {
          // Check if we already have data (don't double-migrate)
          case db.search(db_subject, "*", 1) {
            Ok([_, ..]) -> {
              io.println(
                "[migration] Database already has data, skipping JSONL migration",
              )
              Ok(0)
            }
            _ -> {
              let count =
                list.fold(jsonl_files, 0, fn(acc, file) {
                  let channel_id =
                    string.replace(file, each: ".jsonl", with: "")
                  case
                    migrate_one_file(
                      db_subject,
                      conv_dir <> "/" <> file,
                      channel_id,
                    )
                  {
                    Ok(n) -> {
                      io.println(
                        "[migration] Migrated "
                        <> int.to_string(n)
                        <> " messages from "
                        <> file,
                      )
                      acc + n
                    }
                    Error(e) -> {
                      io.println(
                        "[migration] Failed to migrate " <> file <> ": " <> e,
                      )
                      acc
                    }
                  }
                })
              Ok(count)
            }
          }
        }
      }
    }
  }
}

fn migrate_one_file(
  db_subject: process.Subject(db.DbMessage),
  path: String,
  channel_id: String,
) -> Result(Int, String) {
  use content <- result.try(
    simplifile.read(path)
    |> result.map_error(fn(e) { "Read failed: " <> string.inspect(e) }),
  )

  let now = time.now_ms()
  use convo_id <- result.try(
    db.resolve_conversation(db_subject, "discord", channel_id, now),
  )

  // Parse JSONL lines
  let lines =
    string.split(content, "\n")
    |> list.filter(fn(l) { string.length(string.trim(l)) > 0 })

  let msg_decoder = {
    use role <- decode.field("role", decode.string)
    use c <- decode.field("content", decode.string)
    decode.success(#(role, c))
  }

  let migrated =
    list.index_fold(lines, 0, fn(acc, line, idx) {
      case json.parse(line, msg_decoder) {
        Ok(#(role, msg_content)) -> {
          let ts = now - list.length(lines) + idx
          case
            db.append_message(
              db_subject,
              convo_id,
              role,
              msg_content,
              "",
              "",
              ts,
            )
          {
            Ok(_) -> acc + 1
            Error(_) -> acc
          }
        }
        Error(_) -> acc
      }
    })

  Ok(migrated)
}

