import aura/acp/sse
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/http
import gleam/http/request
import gleam/httpc
import gleam/int
import gleam/io
import gleam/json
import gleam/option.{type Option, None}
import gleam/result
import gleam/string
import gleam/uri

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

pub type Agent {
  Agent(name: String, description: String)
}

pub type RunStatus {
  Created
  InProgress
  Awaiting
  Completed
  Failed
  Cancelling
  Cancelled
}

pub type Run {
  Run(
    run_id: String,
    status: RunStatus,
    output: Option(String),
    error: Option(String),
  )
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// GET /agents — list available agents on the ACP server.
pub fn list_agents(server_url: String) -> Result(List(Agent), String) {
  let url = server_url <> "/agents"
  use resp <- result.try(http_get(url))
  let decoder =
    decode.list({
      use name <- decode.field("name", decode.string)
      use description <- decode.optional_field(
        "description",
        "",
        decode.string,
      )
      decode.success(Agent(name: name, description: description))
    })
  case json.parse(resp, decoder) {
    Ok(agents) -> Ok(agents)
    Error(_) -> Error("Failed to parse agents response")
  }
}

/// POST /runs — create and start a new run on the ACP server.
pub fn create_run(
  server_url: String,
  agent_name: String,
  prompt: String,
) -> Result(Run, String) {
  let url = server_url <> "/runs"
  let body =
    json.object([
      #("agent_name", json.string(agent_name)),
      #(
        "input",
        json.array(
          [
            json.object([
              #("role", json.string("user")),
              #(
                "parts",
                json.array(
                  [
                    json.object([
                      #("content_type", json.string("text/plain")),
                      #("content", json.string(prompt)),
                    ]),
                  ],
                  fn(x) { x },
                ),
              ),
            ]),
          ],
          fn(x) { x },
        ),
      ),
    ])
    |> json.to_string
  use resp <- result.try(http_post(url, body))
  parse_run(resp)
}

/// GET /runs/{run_id} — get the current status of a run.
pub fn get_run(server_url: String, run_id: String) -> Result(Run, String) {
  let url = server_url <> "/runs/" <> run_id
  use resp <- result.try(http_get(url))
  parse_run(resp)
}

/// POST /runs/{run_id}/cancel — cancel a running session.
pub fn cancel_run(server_url: String, run_id: String) -> Result(Nil, String) {
  let url = server_url <> "/runs/" <> run_id <> "/cancel"
  use _ <- result.try(http_post(url, "{}"))
  Ok(Nil)
}

/// POST /runs/{run_id} — resume a paused/awaiting run with new input.
pub fn resume_run(
  server_url: String,
  run_id: String,
  message: String,
) -> Result(Run, String) {
  let url = server_url <> "/runs/" <> run_id
  let body =
    json.object([
      #(
        "input",
        json.array(
          [
            json.object([
              #("role", json.string("user")),
              #(
                "parts",
                json.array(
                  [
                    json.object([
                      #("content_type", json.string("text/plain")),
                      #("content", json.string(message)),
                    ]),
                  ],
                  fn(x) { x },
                ),
              ),
            ]),
          ],
          fn(x) { x },
        ),
      ),
    ])
    |> json.to_string
  use resp <- result.try(http_post(url, body))
  parse_run(resp)
}

/// Subscribe to SSE events for a run. The subscribe call blocks in a
/// spawned process; events are forwarded to callback_pid's mailbox.
pub fn subscribe_events(
  server_url: String,
  run_id: String,
  callback_pid: process.Pid,
) -> Nil {
  let url = server_url <> "/runs/" <> run_id <> "/events"
  sse.subscribe(url, [], callback_pid)
}

// ---------------------------------------------------------------------------
// Run status helpers
// ---------------------------------------------------------------------------

pub fn parse_status(s: String) -> RunStatus {
  case s {
    "created" -> Created
    "in-progress" -> InProgress
    "awaiting" -> Awaiting
    "completed" -> Completed
    "failed" -> Failed
    "cancelling" -> Cancelling
    "cancelled" -> Cancelled
    unknown -> {
      io.println("[acp-client] Unknown run status: " <> unknown)
      InProgress
    }
  }
}

pub fn status_to_string(status: RunStatus) -> String {
  case status {
    Created -> "created"
    InProgress -> "in-progress"
    Awaiting -> "awaiting"
    Completed -> "completed"
    Failed -> "failed"
    Cancelling -> "cancelling"
    Cancelled -> "cancelled"
  }
}

/// Whether a run status represents a terminal state.
pub fn is_terminal(status: RunStatus) -> Bool {
  case status {
    Completed | Failed | Cancelled -> True
    _ -> False
  }
}

// ---------------------------------------------------------------------------
// Parsing
// ---------------------------------------------------------------------------

fn parse_run(body: String) -> Result(Run, String) {
  let decoder = {
    use run_id <- decode.field("run_id", decode.string)
    use status_str <- decode.field("status", decode.string)
    use output <- decode.optional_field(
      "output",
      None,
      decode.optional(decode.string),
    )
    use error <- decode.optional_field(
      "error",
      None,
      decode.optional(decode.string),
    )
    decode.success(Run(
      run_id: run_id,
      status: parse_status(status_str),
      output: output,
      error: error,
    ))
  }
  case json.parse(body, decoder) {
    Ok(run) -> Ok(run)
    Error(_) ->
      Error(
        "Failed to parse run response: " <> string.slice(body, 0, 200),
      )
  }
}

// ---------------------------------------------------------------------------
// HTTP helpers
// ---------------------------------------------------------------------------

fn http_get(url: String) -> Result(String, String) {
  io.println("[acp-client] GET " <> url)
  use parsed_uri <- result.try(
    uri.parse(url) |> result.map_error(fn(_) { "Invalid URL: " <> url }),
  )
  use req <- result.try(
    request.from_uri(parsed_uri)
    |> result.map_error(fn(_) { "Failed to build request for " <> url }),
  )
  let req = req |> request.set_method(http.Get)
  use resp <- result.try(
    httpc.configure()
    |> httpc.timeout(30_000)
    |> httpc.dispatch(req)
    |> result.map_error(fn(e) { "HTTP error: " <> string.inspect(e) }),
  )
  case resp.status {
    200 -> Ok(resp.body)
    status ->
      Error(
        "ACP server error (status "
        <> int.to_string(status)
        <> "): "
        <> string.slice(resp.body, 0, 200),
      )
  }
}

fn http_post(url: String, body: String) -> Result(String, String) {
  io.println("[acp-client] POST " <> url)
  use parsed_uri <- result.try(
    uri.parse(url) |> result.map_error(fn(_) { "Invalid URL: " <> url }),
  )
  use req <- result.try(
    request.from_uri(parsed_uri)
    |> result.map_error(fn(_) { "Failed to build request for " <> url }),
  )
  let req =
    req
    |> request.set_method(http.Post)
    |> request.set_header("content-type", "application/json")
    |> request.set_body(body)
  use resp <- result.try(
    httpc.configure()
    |> httpc.timeout(30_000)
    |> httpc.dispatch(req)
    |> result.map_error(fn(e) { "HTTP error: " <> string.inspect(e) }),
  )
  case resp.status {
    s if s >= 200 && s < 300 -> Ok(resp.body)
    status ->
      Error(
        "ACP server error (status "
        <> int.to_string(status)
        <> "): "
        <> string.slice(resp.body, 0, 200),
      )
  }
}
