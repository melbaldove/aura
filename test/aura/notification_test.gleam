import aura/notification
import gleam/list
import gleam/string
import gleeunit/should

pub fn classify_urgent_test() {
  let finding =
    notification.Finding(
      workstream: "cm2",
      summary: "P0 ticket",
      urgency: notification.Urgent,
      source: "jira",
    )
  notification.is_urgent(finding) |> should.be_true
}

pub fn classify_normal_test() {
  let finding =
    notification.Finding(
      workstream: "cm2",
      summary: "PR review",
      urgency: notification.Normal,
      source: "pr_review",
    )
  notification.is_urgent(finding) |> should.be_false
}

pub fn queue_and_drain_test() {
  let queue = notification.new_queue()
  let f1 =
    notification.Finding(
      workstream: "cm2",
      summary: "New ticket",
      urgency: notification.Normal,
      source: "jira",
    )
  let f2 =
    notification.Finding(
      workstream: "hy",
      summary: "PR review",
      urgency: notification.Normal,
      source: "pr_review",
    )
  let queue = notification.enqueue(queue, f1)
  let queue = notification.enqueue(queue, f2)
  notification.queue_size(queue) |> should.equal(2)
  let #(findings, queue) = notification.drain(queue)
  list.length(findings) |> should.equal(2)
  notification.queue_size(queue) |> should.equal(0)
}

pub fn format_digest_test() {
  let findings = [
    notification.Finding(
      workstream: "cm2",
      summary: "2 tickets in sprint",
      urgency: notification.Normal,
      source: "jira",
    ),
    notification.Finding(
      workstream: "hy",
      summary: "1 PR needs review",
      urgency: notification.Normal,
      source: "pr_review",
    ),
  ]
  let text = notification.format_digest(findings)
  text |> string.contains("cm2") |> should.be_true
  text |> string.contains("hy") |> should.be_true
}

pub fn format_digest_empty_test() {
  notification.format_digest([]) |> should.equal("No pending notifications.")
}

pub fn parse_interval_test() {
  notification.parse_interval("15m") |> should.equal(Ok(900_000))
  notification.parse_interval("30s") |> should.equal(Ok(30_000))
  notification.parse_interval("1h") |> should.equal(Ok(3_600_000))
  notification.parse_interval("bad") |> should.be_error
}
