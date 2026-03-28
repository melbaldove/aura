import aura/workstream
import gleam/string
import gleeunit/should

pub fn build_context_prompt_test() {
  let context =
    workstream.WorkstreamContext(
      config_description: "CMSquared PCHC CICS. Backend. Rust.",
      recent_anchors: ["Chose separate ACK format for RETURN files"],
      todays_log: "Worked on CICS-967 fix.",
      skill_descriptions: "Available tools:\n- jira: Manage tickets",
    )
  let prompt = workstream.build_context_prompt(context)
  prompt |> string.contains("CMSquared") |> should.be_true
  prompt |> string.contains("ACK format") |> should.be_true
  prompt |> string.contains("jira") |> should.be_true
}

pub fn build_context_prompt_empty_test() {
  let context =
    workstream.WorkstreamContext(
      config_description: "Test workstream",
      recent_anchors: [],
      todays_log: "",
      skill_descriptions: "No tools available.",
    )
  let prompt = workstream.build_context_prompt(context)
  prompt |> string.contains("Test workstream") |> should.be_true
}

pub fn today_date_string_test() {
  let date = workstream.today_date_string()
  string.length(date) |> should.equal(10)
  string.contains(date, "-") |> should.be_true
}
