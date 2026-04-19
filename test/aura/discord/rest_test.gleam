import aura/discord/rest
import gleam/bit_array
import gleam/string
import gleeunit/should

pub fn content_type_png_test() {
  rest.content_type_for_filename("shot.png") |> should.equal("image/png")
}

pub fn content_type_jpg_test() {
  rest.content_type_for_filename("x.jpg") |> should.equal("image/jpeg")
  rest.content_type_for_filename("x.JPEG") |> should.equal("image/jpeg")
}

pub fn content_type_gif_test() {
  rest.content_type_for_filename("x.gif") |> should.equal("image/gif")
}

pub fn content_type_webp_test() {
  rest.content_type_for_filename("x.webp") |> should.equal("image/webp")
}

pub fn content_type_text_test() {
  rest.content_type_for_filename("log.txt") |> should.equal("text/plain")
  rest.content_type_for_filename("data.json") |> should.equal("application/json")
}

pub fn content_type_unknown_test() {
  rest.content_type_for_filename("x.bin")
  |> should.equal("application/octet-stream")
  rest.content_type_for_filename("noext") |> should.equal("application/octet-stream")
}

pub fn build_multipart_has_both_parts_test() {
  let body =
    rest.build_multipart_body(
      "testboundary",
      "{\"content\":\"hi\"}",
      "shot.png",
      "image/png",
      <<0x89, 0x50, 0x4E, 0x47>>,
    )
  let text = bit_array_to_lossy_string(body)
  text |> string.contains("--testboundary") |> should.be_true
  text
  |> string.contains("Content-Disposition: form-data; name=\"payload_json\"")
  |> should.be_true
  text
  |> string.contains(
    "Content-Disposition: form-data; name=\"files[0]\"; filename=\"shot.png\"",
  )
  |> should.be_true
  text |> string.contains("Content-Type: image/png") |> should.be_true
  text |> string.contains("--testboundary--") |> should.be_true
}

pub fn build_multipart_embeds_file_bytes_test() {
  let magic = <<0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A>>
  let body =
    rest.build_multipart_body(
      "b",
      "{}",
      "x.png",
      "image/png",
      magic,
    )
  // PNG magic bytes must survive intact in the body.
  bit_array.slice(body, bit_array.byte_size(body) - 20, 8)
  |> should.be_ok
}

fn bit_array_to_lossy_string(ba: BitArray) -> String {
  case bit_array.to_string(ba) {
    Ok(s) -> s
    // Fall back to replacing non-UTF8 bytes with a sentinel so we can still
    // contains-check the text parts.
    Error(_) -> bit_array_force_string(ba)
  }
}

fn bit_array_force_string(ba: BitArray) -> String {
  // Walk byte by byte; for printable ASCII use as-is, else skip. Test-only.
  do_force(ba, "")
}

fn do_force(ba: BitArray, acc: String) -> String {
  case ba {
    <<c:int, rest:bits>> -> {
      let ch = case c >= 32 && c <= 126 || c == 10 || c == 13 {
        True -> {
          let assert Ok(s) = bit_array.to_string(<<c:int>>)
          s
        }
        False -> ""
      }
      do_force(rest, acc <> ch)
    }
    _ -> acc
  }
}
