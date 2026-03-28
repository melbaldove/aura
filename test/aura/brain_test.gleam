import aura/brain
import gleam/string
import gleeunit/should

pub fn route_workstream_channel_test() {
  let workstreams = [
    brain.WorkstreamInfo(name: "cm2", channel_id: "chan-cm2"),
    brain.WorkstreamInfo(name: "hy", channel_id: "chan-hy"),
  ]
  brain.route_message("chan-cm2", workstreams)
  |> should.equal(brain.DirectRoute("cm2"))
}

pub fn route_workstream_channel_second_test() {
  let workstreams = [
    brain.WorkstreamInfo(name: "cm2", channel_id: "chan-cm2"),
    brain.WorkstreamInfo(name: "hy", channel_id: "chan-hy"),
  ]
  brain.route_message("chan-hy", workstreams)
  |> should.equal(brain.DirectRoute("hy"))
}

pub fn route_unknown_channel_test() {
  let workstreams = [
    brain.WorkstreamInfo(name: "cm2", channel_id: "chan-cm2"),
  ]
  brain.route_message("chan-unknown", workstreams)
  |> should.equal(brain.NeedsClassification)
}

pub fn route_empty_workstreams_test() {
  brain.route_message("chan-cm2", [])
  |> should.equal(brain.NeedsClassification)
}

pub fn build_system_prompt_test() {
  let prompt = brain.build_system_prompt("You are Aura. Direct. Concise.")
  prompt |> string.contains("Aura") |> should.be_true
  prompt |> string.contains("Discord") |> should.be_true
}

pub fn build_system_prompt_includes_soul_content_test() {
  let prompt = brain.build_system_prompt("Custom personality goes here.")
  prompt |> string.contains("Custom personality goes here.") |> should.be_true
}

pub fn build_routing_prompt_test() {
  let prompt = brain.build_routing_prompt("fix the login bug", ["cm2", "hy", "aura"])
  prompt |> string.contains("fix the login bug") |> should.be_true
  prompt |> string.contains("cm2") |> should.be_true
  prompt |> string.contains("hy") |> should.be_true
  prompt |> string.contains("aura") |> should.be_true
}

pub fn resolve_model_name_test() {
  brain.resolve_model_name("zai/glm-5-turbo")
  |> should.equal("glm-5-turbo")
}

pub fn resolve_model_name_no_prefix_test() {
  brain.resolve_model_name("glm-5-turbo")
  |> should.equal("glm-5-turbo")
}

pub fn resolve_model_name_claude_test() {
  brain.resolve_model_name("claude/sonnet")
  |> should.equal("sonnet")
}
