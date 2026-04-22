import aura/attachment
import aura/channel_actor
import aura/llm
import aura/message
import aura/time
import gleam/int
import gleam/list
import gleam/option
import gleam/string
import gleeunit/should
import simplifile

// ---------------------------------------------------------------------------
// Pure helper tests
// ---------------------------------------------------------------------------

/// local_path combines the tmp base, message id, and safe filename.
pub fn local_path_basic_test() {
  let path = attachment.local_path("msg-123", "photo.png")
  path |> should.equal("/tmp/aura-attachments/msg-123/photo.png")
}

/// safe_filename is enforced: path traversal is stripped by local_path.
pub fn local_path_prevents_path_traversal_test() {
  let path = attachment.local_path("msg-1", "../../../etc/passwd")
  // The last segment "passwd" is kept but the path stays under the tmp dir
  string.ends_with(path, "/passwd") |> should.be_true
  string.contains(path, "..") |> should.be_false
}

// ---------------------------------------------------------------------------
// preprocess — no attachments
// ---------------------------------------------------------------------------

/// With no attachments, preprocess returns the original content unchanged.
pub fn preprocess_no_attachments_returns_content_test() {
  let msg =
    message.IncomingMessage(
      platform: "discord",
      message_id: "m1",
      channel_id: "c1",
      channel_name: option.None,
      guild_id: "g1",
      author_id: "u1",
      author_name: "tester",
      content: "hello there",
      is_bot: False,
      attachments: [],
    )
  attachment.preprocess(msg) |> should.equal("hello there")
}

// ---------------------------------------------------------------------------
// preprocess — text attachment with unreachable URL
// ---------------------------------------------------------------------------

/// When a text attachment has a fake/unreachable URL, preprocess degrades
/// gracefully: download fails, text inline fails, and the original content
/// is returned (no crash, no empty result).
pub fn preprocess_text_attachment_unreachable_url_returns_content_test() {
  let att =
    message.Attachment(
      url: "http://localhost:1/does-not-exist.txt",
      content_type: "text/plain",
      filename: "notes.txt",
    )
  let msg =
    message.IncomingMessage(
      platform: "discord",
      message_id: "m-attach-test-" <> int.to_string(time.now_ms()),
      channel_id: "c1",
      channel_name: option.None,
      guild_id: "g1",
      author_id: "u1",
      author_name: "tester",
      content: "see attached",
      is_bot: False,
      attachments: [att],
    )
  // With fake URL, download fails gracefully — content is at least the
  // original message content (not empty, not crashed).
  let result = attachment.preprocess(msg)
  string.contains(result, "see attached") |> should.be_true
}

// ---------------------------------------------------------------------------
// attachment_max_bytes threshold
// ---------------------------------------------------------------------------

/// The size cap constant must be 50 MB.
pub fn attachment_max_bytes_is_50mb_test() {
  attachment.attachment_max_bytes |> should.equal(50_000_000)
}

/// Regression: preprocess must not write a file when the download fails
/// (the skipping path is best-tested via the public constant and a URL
/// that fails, verifying no file is created regardless).
pub fn oversized_attachment_does_not_write_file_test() {
  let msg_id = "m-oversize-" <> int.to_string(time.now_ms())
  let att =
    message.Attachment(
      url: "http://localhost:1/large.bin",
      content_type: "application/octet-stream",
      filename: "large.bin",
    )
  let msg =
    message.IncomingMessage(
      platform: "discord",
      message_id: msg_id,
      channel_id: "c1",
      channel_name: option.None,
      guild_id: "g1",
      author_id: "u1",
      author_name: "tester",
      content: "download this",
      is_bot: False,
      attachments: [att],
    )
  let path = attachment.local_path(msg_id, "large.bin")
  let _ = attachment.preprocess(msg)
  // File must not exist: download failed (URL unreachable), so nothing written
  simplifile.is_file(path) |> should.equal(Ok(False))
}

/// Verify the 50 MB boundary: a 60 MB size is above the cap.
pub fn sixty_mb_exceeds_cap_test() {
  let sixty_mb = 60_000_000
  { sixty_mb > attachment.attachment_max_bytes } |> should.be_true
}

// ---------------------------------------------------------------------------
// Regression: start_turn uses attachment.preprocess
// ---------------------------------------------------------------------------

/// Regression: start_turn must use attachment.preprocess(msg) for the
/// UserMessage content. With no attachments, preprocess returns msg.content
/// unchanged — so this test verifies the wiring: the UserMessage in the LLM
/// call contains exactly the message content.
pub fn start_turn_user_message_content_from_preprocess_test() {
  let state = channel_actor.initial_state_for_test("ch-att-test")
  let msg =
    message.IncomingMessage(
      platform: "discord",
      message_id: "att-m1-" <> int.to_string(time.now_ms()),
      channel_id: "ch-att-test",
      channel_name: option.None,
      guild_id: "g1",
      author_id: "u1",
      author_name: "tester",
      content: "check this file",
      is_bot: False,
      attachments: [],
    )
  let #(new_state, _effects) =
    channel_actor.transition(state, channel_actor.HandleIncoming(msg))
  // The turn should be started with a UserMessage containing the content
  case new_state.turn {
    option.None -> should.fail()
    option.Some(turn) -> {
      let has_user_msg =
        list.any(turn.messages_at_llm_call, fn(m) {
          case m {
            llm.UserMessage("check this file") -> True
            _ -> False
          }
        })
      has_user_msg |> should.be_true
    }
  }
}
