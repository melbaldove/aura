//// Focused IMAP IDLE client.
////
//// A minimal RFC 3501 + RFC 2177 + Gmail-XOAUTH2 subset for ambient email
//// ingestion: TLS connect (port 993), XOAUTH2 authenticate, SELECT, IDLE +
//// DONE, FETCH ENVELOPE, close. Not a general-purpose IMAP library —
//// everything outside this surface is deliberately absent.
////
//// The split: all networking goes through `aura_imap_ffi` (thin `ssl`
//// wrapper); parsing, command building, the XOAUTH2 string, and the
//// envelope tokenizer are pure Gleam and covered by unit tests.
////
//// Live TLS / Gmail behavior is validated by Task 11's deploy.

import gleam/bit_array
import gleam/dynamic.{type Dynamic}
import gleam/int
import gleam/list
import gleam/result
import gleam/string

// ---------------------------------------------------------------------------
// FFI
// ---------------------------------------------------------------------------

/// Opaque Erlang ssl socket reference. Wrapped as Dynamic so it stays
/// opaque on the Gleam side.
type SslSocket =
  Dynamic

@external(erlang, "aura_imap_ffi", "connect")
fn ffi_connect(
  host: BitArray,
  port: Int,
  timeout_ms: Int,
) -> Result(SslSocket, BitArray)

@external(erlang, "aura_imap_ffi", "send")
fn ffi_send(sock: SslSocket, data: BitArray) -> Result(Nil, BitArray)

@external(erlang, "aura_imap_ffi", "recv")
fn ffi_recv(sock: SslSocket, len: Int, timeout_ms: Int) -> Result(BitArray, BitArray)

@external(erlang, "aura_imap_ffi", "close")
fn ffi_close(sock: SslSocket) -> Dynamic

@external(erlang, "aura_imap_ffi", "base64_encode")
fn ffi_base64_encode(data: BitArray) -> BitArray

@external(erlang, "aura_imap_ffi", "unique_tag")
fn ffi_unique_tag() -> Int

// ---------------------------------------------------------------------------
// Public types
// ---------------------------------------------------------------------------

/// Open IMAP connection. Wraps the opaque `ssl` socket. Command tags
/// are drawn from a per-VM monotonically increasing counter
/// (`aura_imap_ffi:unique_tag/0`) so we don't need mutable state on the
/// Gleam side.
pub opaque type Connection {
  Connection(sock: SslSocket)
}

pub type Auth {
  XOAuth2(user: String, access_token: String)
}

pub type MailboxState {
  MailboxState(exists: Int, uidvalidity: Int, uidnext: Int)
}

pub type IdleEvent {
  Exists(count: Int)
  Expunge(seq: Int)
  Timeout
}

pub type Envelope {
  Envelope(
    uid: Int,
    message_id: String,
    from: String,
    to: String,
    subject: String,
    date: String,
  )
}

pub type Status {
  StatusOk
  StatusNo
  StatusBad
}

pub type ResponseLine {
  Tagged(tag: String, status: Status, text: String)
  Untagged(payload: String)
  Continuation(text: String)
}

// ---------------------------------------------------------------------------
// Public API — networking
// ---------------------------------------------------------------------------

/// Open a TLS connection to an IMAP server. Reads the server greeting
/// (`* OK ...`) and returns a ready `Connection`. Errors are stringified.
pub fn connect(
  host: String,
  port: Int,
  timeout_ms: Int,
) -> Result(Connection, String) {
  use sock <- result.try(
    ffi_connect(bit_array.from_string(host), port, timeout_ms)
    |> result.map_error(bit_to_string),
  )
  let conn = Connection(sock: sock)
  // Read and discard the server greeting. It's an untagged line.
  use #(_, _) <- result.try(read_until_tagged(conn, "", timeout_ms, True))
  Ok(conn)
}

/// Authenticate via Gmail's XOAUTH2 SASL mechanism.
pub fn authenticate(conn: Connection, auth: Auth) -> Result(Nil, String) {
  case auth {
    XOAuth2(user: user, access_token: token) ->
      authenticate_xoauth2(conn, user, token)
  }
}

/// Select a mailbox. Returns EXISTS / UIDVALIDITY / UIDNEXT.
pub fn select(
  conn: Connection,
  mailbox: String,
) -> Result(MailboxState, String) {
  let tag = format_tag(ffi_unique_tag())
  let cmd = tag <> " SELECT " <> mailbox <> "\r\n"
  use _ <- result.try(send_raw(conn, cmd))
  use #(untagged, tagged) <- result.try(read_until_tagged(
    conn,
    tag,
    default_cmd_timeout,
    False,
  ))
  case tagged {
    Tagged(_, StatusOk, _) -> parse_select_untagged(untagged)
    Tagged(_, _, text) -> Error("SELECT failed: " <> text)
    _ -> Error("SELECT: unexpected non-tagged terminator")
  }
}

/// Enter IDLE mode. Collects untagged events as they arrive, returns
/// either the collected events or a single `Timeout` if the server stays
/// silent for `timeout_ms`. Always sends `DONE` before returning.
pub fn idle(
  conn: Connection,
  timeout_ms: Int,
) -> Result(List(IdleEvent), String) {
  let tag = format_tag(ffi_unique_tag())
  let cmd = tag <> " IDLE\r\n"
  use _ <- result.try(send_raw(conn, cmd))
  // Expect a continuation line `+ idling` before events start.
  use _ <- result.try(expect_continuation(conn, timeout_ms))
  // Collect untagged events until timeout or some arrive.
  let events = collect_idle_events(conn, timeout_ms, [])
  // Leave IDLE.
  use _ <- result.try(send_raw(conn, "DONE\r\n"))
  // Drain until tagged OK.
  use _ <- result.try(read_until_tagged(
    conn,
    tag,
    default_cmd_timeout,
    False,
  ))
  case events {
    [] -> Ok([Timeout])
    _ -> Ok(list.reverse(events))
  }
}

/// Fetch envelope + UID for one sequence number.
pub fn fetch_envelope(conn: Connection, seq: Int) -> Result(Envelope, String) {
  let tag = format_tag(ffi_unique_tag())
  let cmd = tag <> " FETCH " <> int.to_string(seq) <> " (ENVELOPE UID)\r\n"
  use _ <- result.try(send_raw(conn, cmd))
  use #(untagged, tagged) <- result.try(read_until_tagged(
    conn,
    tag,
    default_cmd_timeout,
    False,
  ))
  case tagged {
    Tagged(_, StatusOk, _) ->
      case untagged {
        [] -> Error("FETCH: no envelope in response")
        [line, ..] -> parse_envelope_fetch(line)
      }
    Tagged(_, _, text) -> Error("FETCH failed: " <> text)
    _ -> Error("FETCH: unexpected non-tagged terminator")
  }
}

/// Close the TLS socket. Errors from the underlying `ssl:close/1` are
/// swallowed — the connection is going away regardless.
pub fn close(conn: Connection) -> Nil {
  let _ = ffi_close(conn.sock)
  Nil
}

// ---------------------------------------------------------------------------
// Public helpers — pure, unit-tested
// ---------------------------------------------------------------------------

const default_cmd_timeout: Int = 30_000

/// Build the raw XOAUTH2 SASL auth string. Caller base64-encodes before
/// sending. Format per Google XOAUTH2 docs:
///
///   user=<email>\x01auth=Bearer <token>\x01\x01
pub fn xoauth2_auth_string(user: String, access_token: String) -> String {
  let ctrl_a = bit_array.base16_decode("01")
  let ctrl_a_str = case ctrl_a {
    Ok(bits) ->
      case bit_array.to_string(bits) {
        Ok(s) -> s
        _ -> ""
      }
    _ -> ""
  }
  "user="
  <> user
  <> ctrl_a_str
  <> "auth=Bearer "
  <> access_token
  <> ctrl_a_str
  <> ctrl_a_str
}

/// Parse a single IMAP response line. Line may end in `\r\n` or be bare.
pub fn parse_response_line(line: String) -> Result(ResponseLine, String) {
  let trimmed = strip_crlf(line)
  case trimmed {
    "" -> Error("empty line")
    _ ->
      case string.slice(trimmed, 0, 1) {
        "+" -> {
          // `+` or `+ <text>`
          let text = case string.length(trimmed) {
            1 -> ""
            _ ->
              case string.slice(trimmed, 1, string.length(trimmed) - 1) {
                " " <> rest -> rest
                other -> other
              }
          }
          Ok(Continuation(text))
        }
        "*" -> {
          // `* <payload>`
          case string.length(trimmed) {
            1 -> Ok(Untagged(""))
            _ ->
              case string.slice(trimmed, 1, string.length(trimmed) - 1) {
                " " <> rest -> Ok(Untagged(rest))
                other -> Ok(Untagged(other))
              }
          }
        }
        _ -> parse_tagged(trimmed)
      }
  }
}

/// `* <N> EXISTS` -> Ok(N). Strict: requires EXISTS keyword.
pub fn parse_exists_count(payload: String) -> Result(Int, String) {
  case string.split(payload, " ") {
    [n_str, "EXISTS"] ->
      int.parse(n_str)
      |> result.map_error(fn(_) { "invalid EXISTS count: " <> n_str })
    _ -> Error("not an EXISTS payload: " <> payload)
  }
}

/// `* <N> EXPUNGE` -> Ok(N).
pub fn parse_expunge_seq(payload: String) -> Result(Int, String) {
  case string.split(payload, " ") {
    [n_str, "EXPUNGE"] ->
      int.parse(n_str)
      |> result.map_error(fn(_) { "invalid EXPUNGE seq: " <> n_str })
    _ -> Error("not an EXPUNGE payload: " <> payload)
  }
}

/// Extract an integer from a `[KEY N]` response code embedded in text.
/// e.g. `parse_resp_code_int("OK [UIDVALIDITY 1234] ...", "UIDVALIDITY")`.
pub fn parse_resp_code_int(
  text: String,
  key: String,
) -> Result(Int, String) {
  let needle = "[" <> key <> " "
  case string.split_once(text, needle) {
    Ok(#(_, after)) ->
      case string.split_once(after, "]") {
        Ok(#(n_str, _)) ->
          int.parse(string.trim(n_str))
          |> result.map_error(fn(_) {
            "invalid " <> key <> " int: " <> n_str
          })
        _ -> Error("missing ']' after " <> key)
      }
    _ -> Error(key <> " not found")
  }
}

/// Parse a single `* <seq> FETCH (ENVELOPE (...) UID <uid>)` line into
/// an `Envelope`. Tokenizer handles quoted strings, NIL, parens, atoms.
pub fn parse_envelope_fetch(raw: String) -> Result(Envelope, String) {
  // Strip `* <seq> FETCH ` prefix and enter the outer paren group.
  use rest <- result.try(strip_fetch_prefix(raw))
  use tokens <- result.try(tokenize(rest))
  case tokens {
    [TOpen, ..rest_tokens] -> parse_envelope_body(rest_tokens)
    _ -> Error("FETCH response missing opening paren")
  }
}

// ---------------------------------------------------------------------------
// Internal — tagged response parsing
// ---------------------------------------------------------------------------

fn parse_tagged(line: String) -> Result(ResponseLine, String) {
  case string.split_once(line, " ") {
    Ok(#(tag, rest)) ->
      case string.split_once(rest, " ") {
        Ok(#(status_str, text)) ->
          case status_str {
            "OK" -> Ok(Tagged(tag, StatusOk, text))
            "NO" -> Ok(Tagged(tag, StatusNo, text))
            "BAD" -> Ok(Tagged(tag, StatusBad, text))
            _ -> Error("unknown status: " <> status_str)
          }
        _ -> Error("tagged line missing status")
      }
    _ -> Error("tagged line missing tag")
  }
}

fn strip_crlf(line: String) -> String {
  // Drop trailing \r\n (or either alone) without relying on regex.
  let no_lf = case string.ends_with(line, "\n") {
    True -> string.slice(line, 0, string.length(line) - 1)
    False -> line
  }
  case string.ends_with(no_lf, "\r") {
    True -> string.slice(no_lf, 0, string.length(no_lf) - 1)
    False -> no_lf
  }
}

// ---------------------------------------------------------------------------
// Internal — socket I/O
// ---------------------------------------------------------------------------

fn send_raw(conn: Connection, cmd: String) -> Result(Nil, String) {
  ffi_send(conn.sock, bit_array.from_string(cmd))
  |> result.map_error(bit_to_string)
}

fn recv_line(conn: Connection, timeout_ms: Int) -> Result(String, String) {
  use bits <- result.try(
    ffi_recv(conn.sock, 0, timeout_ms)
    |> result.map_error(bit_to_string),
  )
  bit_array.to_string(bits)
  |> result.map_error(fn(_) { "imap: non-utf8 line from server" })
}

fn bit_to_string(b: BitArray) -> String {
  case bit_array.to_string(b) {
    Ok(s) -> s
    _ -> "<binary>"
  }
}

fn format_tag(n: Int) -> String {
  let s = int.to_string(n)
  let pad = case string.length(s) {
    1 -> "00"
    2 -> "0"
    _ -> ""
  }
  "a" <> pad <> s
}

/// Read lines until we see the tagged terminator matching `tag`. Returns
/// the untagged payloads and the terminator. When `first_is_greeting`
/// is True, accepts the first line as a greeting and returns without
/// requiring a tag (used by `connect`).
fn read_until_tagged(
  conn: Connection,
  tag: String,
  timeout_ms: Int,
  first_is_greeting: Bool,
) -> Result(#(List(String), ResponseLine), String) {
  read_until_tagged_loop(conn, tag, timeout_ms, first_is_greeting, [])
}

fn read_until_tagged_loop(
  conn: Connection,
  tag: String,
  timeout_ms: Int,
  first_is_greeting: Bool,
  acc: List(String),
) -> Result(#(List(String), ResponseLine), String) {
  use line <- result.try(recv_line(conn, timeout_ms))
  use parsed <- result.try(parse_response_line(line))
  case parsed {
    Tagged(t, _, _) as msg if t == tag -> Ok(#(list.reverse(acc), msg))
    Untagged(payload) if first_is_greeting ->
      Ok(#([payload], Tagged("", StatusOk, "greeting")))
    Untagged(payload) ->
      read_until_tagged_loop(conn, tag, timeout_ms, False, [payload, ..acc])
    Continuation(_) ->
      // Unexpected continuation during a command response. Surface loudly.
      Error("unexpected continuation in response")
    Tagged(_, _, text) ->
      // Tagged response for a different tag — shouldn't happen in this
      // simple pipelined-free client, but fail loudly rather than silently.
      Error("tagged response for unexpected tag: " <> text)
  }
}

fn expect_continuation(
  conn: Connection,
  timeout_ms: Int,
) -> Result(String, String) {
  use line <- result.try(recv_line(conn, timeout_ms))
  use parsed <- result.try(parse_response_line(line))
  case parsed {
    Continuation(text) -> Ok(text)
    _ -> Error("expected continuation, got: " <> line)
  }
}

fn collect_idle_events(
  conn: Connection,
  timeout_ms: Int,
  acc: List(IdleEvent),
) -> List(IdleEvent) {
  case recv_line(conn, timeout_ms) {
    Error(_) -> acc
    Ok(line) ->
      case parse_response_line(line) {
        Ok(Untagged(payload)) -> {
          let acc2 = case classify_idle(payload) {
            Ok(ev) -> [ev, ..acc]
            _ -> acc
          }
          // Keep reading non-blocking-ish: once we've seen at least one
          // event, use a short secondary timeout to drain batched events.
          let next_timeout = case acc2 {
            [] -> timeout_ms
            _ -> 100
          }
          collect_idle_events(conn, next_timeout, acc2)
        }
        _ -> acc
      }
  }
}

fn classify_idle(payload: String) -> Result(IdleEvent, String) {
  case parse_exists_count(payload) {
    Ok(n) -> Ok(Exists(n))
    _ ->
      case parse_expunge_seq(payload) {
        Ok(n) -> Ok(Expunge(n))
        _ -> Error("unhandled idle event: " <> payload)
      }
  }
}

// ---------------------------------------------------------------------------
// Internal — XOAUTH2 flow
// ---------------------------------------------------------------------------

fn authenticate_xoauth2(
  conn: Connection,
  user: String,
  token: String,
) -> Result(Nil, String) {
  let tag = format_tag(ffi_unique_tag())
  let raw = xoauth2_auth_string(user, token)
  let b64 = case bit_array.to_string(ffi_base64_encode(bit_array.from_string(raw))) {
    Ok(s) -> s
    _ -> ""
  }
  let cmd = tag <> " AUTHENTICATE XOAUTH2 " <> b64 <> "\r\n"
  use _ <- result.try(send_raw(conn, cmd))
  authenticate_xoauth2_loop(conn, tag)
}

fn authenticate_xoauth2_loop(
  conn: Connection,
  tag: String,
) -> Result(Nil, String) {
  use line <- result.try(recv_line(conn, default_cmd_timeout))
  use parsed <- result.try(parse_response_line(line))
  case parsed {
    Tagged(t, StatusOk, _) if t == tag -> Ok(Nil)
    Tagged(t, _, text) if t == tag ->
      Error("XOAUTH2 failed: " <> text)
    Continuation(err_b64) -> {
      // Google convention: continuation carries a base64-encoded JSON
      // error blob. Client must send an empty line to acknowledge before
      // the server will emit the tagged NO.
      use _ <- result.try(send_raw(conn, "\r\n"))
      use final <- result.try(recv_line(conn, default_cmd_timeout))
      use parsed2 <- result.try(parse_response_line(final))
      case parsed2 {
        Tagged(_, StatusOk, _) -> Ok(Nil)
        Tagged(_, _, text) ->
          Error("XOAUTH2 failed: " <> text <> " (detail b64: " <> err_b64 <> ")")
        _ -> Error("XOAUTH2: unexpected response after continuation")
      }
    }
    Untagged(_) -> authenticate_xoauth2_loop(conn, tag)
    _ -> Error("XOAUTH2: unexpected response")
  }
}

// ---------------------------------------------------------------------------
// Internal — SELECT parsing
// ---------------------------------------------------------------------------

fn parse_select_untagged(
  lines: List(String),
) -> Result(MailboxState, String) {
  // Scan for EXISTS, UIDVALIDITY, UIDNEXT across all untagged lines.
  // Each is independent — ordering varies.
  let exists =
    list.fold(lines, Error("no EXISTS"), fn(acc, line) {
      case acc, parse_exists_count(line) {
        Ok(_), _ -> acc
        _, Ok(n) -> Ok(n)
        _, _ -> acc
      }
    })
  let uidvalidity = find_resp_code_int(lines, "UIDVALIDITY")
  let uidnext = find_resp_code_int(lines, "UIDNEXT")
  use exists_n <- result.try(exists)
  use uidvalidity_n <- result.try(uidvalidity)
  use uidnext_n <- result.try(uidnext)
  Ok(MailboxState(
    exists: exists_n,
    uidvalidity: uidvalidity_n,
    uidnext: uidnext_n,
  ))
}

fn find_resp_code_int(
  lines: List(String),
  key: String,
) -> Result(Int, String) {
  list.fold(lines, Error(key <> " not found"), fn(acc, line) {
    case acc {
      Ok(_) -> acc
      _ -> parse_resp_code_int(line, key)
    }
  })
}

// ---------------------------------------------------------------------------
// Internal — envelope tokenizer + parser
// ---------------------------------------------------------------------------

type Token {
  TOpen
  TClose
  TNil
  TString(String)
  TInt(Int)
  TAtom(String)
}

fn strip_fetch_prefix(raw: String) -> Result(String, String) {
  // Expect `* <seq> FETCH ` at the start.
  case string.split_once(raw, " FETCH ") {
    Ok(#(_, after)) -> Ok(after)
    _ -> Error("not a FETCH response: " <> raw)
  }
}

fn tokenize(input: String) -> Result(List(Token), String) {
  tokenize_loop(input, [])
}

fn tokenize_loop(
  input: String,
  acc: List(Token),
) -> Result(List(Token), String) {
  case string.first(input) {
    Error(_) -> Ok(list.reverse(acc))
    Ok(c) ->
      case c {
        " " -> tokenize_loop(drop_first(input), acc)
        "(" -> tokenize_loop(drop_first(input), [TOpen, ..acc])
        ")" -> tokenize_loop(drop_first(input), [TClose, ..acc])
        "\"" -> {
          use #(s, rest) <- result.try(read_quoted(drop_first(input)))
          tokenize_loop(rest, [TString(s), ..acc])
        }
        _ -> {
          let #(word, rest) = read_atom(input)
          let tok = case word {
            "NIL" -> TNil
            _ ->
              case int.parse(word) {
                Ok(n) -> TInt(n)
                _ -> TAtom(word)
              }
          }
          tokenize_loop(rest, [tok, ..acc])
        }
      }
  }
}

fn drop_first(s: String) -> String {
  case string.length(s) {
    0 -> s
    n -> string.slice(s, 1, n - 1)
  }
}

fn read_quoted(input: String) -> Result(#(String, String), String) {
  read_quoted_loop(input, "")
}

fn read_quoted_loop(
  input: String,
  acc: String,
) -> Result(#(String, String), String) {
  case string.first(input) {
    Error(_) -> Error("unterminated quoted string")
    Ok("\"") -> Ok(#(acc, drop_first(input)))
    Ok("\\") ->
      case string.length(input) {
        n if n >= 2 -> {
          let esc = string.slice(input, 1, 1)
          read_quoted_loop(string.slice(input, 2, n - 2), acc <> esc)
        }
        _ -> Error("trailing backslash in quoted string")
      }
    Ok(c) -> read_quoted_loop(drop_first(input), acc <> c)
  }
}

fn read_atom(input: String) -> #(String, String) {
  read_atom_loop(input, "")
}

fn read_atom_loop(input: String, acc: String) -> #(String, String) {
  case string.first(input) {
    Error(_) -> #(acc, "")
    Ok(c) ->
      case c {
        " " | "(" | ")" -> #(acc, input)
        _ -> read_atom_loop(drop_first(input), acc <> c)
      }
  }
}

/// Parse envelope body:
/// ENVELOPE ( date subject from sender reply-to to cc bcc in-reply-to msg-id ) UID <n>
/// Each address list is `NIL` or `( ( name adl mailbox host ) ... )`.
fn parse_envelope_body(tokens: List(Token)) -> Result(Envelope, String) {
  // We expect: TAtom("ENVELOPE") TOpen ... TClose TAtom("UID") TInt(n) TClose
  case tokens {
    [TAtom("ENVELOPE"), TOpen, ..rest] -> {
      use #(env_fields, after_env) <- result.try(take_until_close(rest, 1, []))
      use #(date, subject, from_list, _sender, _reply_to, to_list, _cc, _bcc,
        _in_reply_to, message_id) <- result.try(extract_envelope_fields(
        env_fields,
      ))
      use uid <- result.try(find_uid(after_env))
      let from_str = first_address(from_list)
      let to_str = first_address(to_list)
      Ok(Envelope(
        uid: uid,
        message_id: message_id,
        from: from_str,
        to: to_str,
        subject: subject,
        date: date,
      ))
    }
    _ -> Error("FETCH body missing ENVELOPE marker")
  }
}

/// Consume tokens up to the matching TClose at depth 0, returning the
/// collected inner tokens and the remainder (excluding the TClose).
fn take_until_close(
  tokens: List(Token),
  depth: Int,
  acc: List(Token),
) -> Result(#(List(Token), List(Token)), String) {
  case tokens {
    [] -> Error("unterminated paren group")
    [TClose, ..rest] if depth == 1 ->
      Ok(#(list.reverse(acc), rest))
    [TClose, ..rest] ->
      take_until_close(rest, depth - 1, [TClose, ..acc])
    [TOpen, ..rest] ->
      take_until_close(rest, depth + 1, [TOpen, ..acc])
    [t, ..rest] -> take_until_close(rest, depth, [t, ..acc])
  }
}

/// Pull the ten envelope positional fields. Each is either a string, NIL,
/// or (for addresses) a paren group. Returns the raw string for each
/// scalar and the tokens-of-inner-group for each address list.
fn extract_envelope_fields(
  tokens: List(Token),
) -> Result(
  #(
    String, String, List(Token), List(Token), List(Token),
    List(Token), List(Token), List(Token), String, String,
  ),
  String,
) {
  use #(date, t1) <- result.try(take_string_or_nil(tokens, "date"))
  use #(subject, t2) <- result.try(take_string_or_nil(t1, "subject"))
  use #(from_list, t3) <- result.try(take_addr_list(t2))
  use #(sender, t4) <- result.try(take_addr_list(t3))
  use #(reply_to, t5) <- result.try(take_addr_list(t4))
  use #(to_list, t6) <- result.try(take_addr_list(t5))
  use #(cc, t7) <- result.try(take_addr_list(t6))
  use #(bcc, t8) <- result.try(take_addr_list(t7))
  use #(in_reply_to, t9) <- result.try(take_string_or_nil(t8, "in-reply-to"))
  use #(message_id, _) <- result.try(take_string_or_nil(t9, "message-id"))
  Ok(#(
    date,
    subject,
    from_list,
    sender,
    reply_to,
    to_list,
    cc,
    bcc,
    in_reply_to,
    message_id,
  ))
}

fn take_string_or_nil(
  tokens: List(Token),
  what: String,
) -> Result(#(String, List(Token)), String) {
  case tokens {
    [TString(s), ..rest] -> Ok(#(s, rest))
    [TNil, ..rest] -> Ok(#("", rest))
    _ -> Error("expected string or NIL for " <> what)
  }
}

fn take_addr_list(
  tokens: List(Token),
) -> Result(#(List(Token), List(Token)), String) {
  case tokens {
    [TNil, ..rest] -> Ok(#([], rest))
    [TOpen, ..rest] -> take_until_close(rest, 1, [])
    _ -> Error("expected address list or NIL")
  }
}

/// Extract the first address as "mailbox@host" from the inner tokens of
/// an address list `( ( name adl mailbox host ) ... )`.
fn first_address(inner: List(Token)) -> String {
  case inner {
    [TOpen, _name, _adl, TString(mailbox), TString(host), TClose, ..] ->
      mailbox <> "@" <> host
    [TOpen, _name, _adl, TString(mailbox), TNil, TClose, ..] -> mailbox
    _ -> ""
  }
}

fn find_uid(tokens: List(Token)) -> Result(Int, String) {
  case tokens {
    [TAtom("UID"), TInt(n), ..] -> Ok(n)
    [_, ..rest] -> find_uid(rest)
    [] -> Error("UID not found")
  }
}
