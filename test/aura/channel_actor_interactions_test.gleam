/// Tests for RegisterProposal, RegisterShellApproval, and HandleInteractionResolve
/// transitions in channel_actor. These verify that per-channel proposal/approval
/// state is correctly managed in the channel actor, not in brain.
import aura/brain_tools
import aura/channel_actor
import aura/db
import aura/time
import gleam/erlang/process
import gleam/list
import gleam/string
import gleeunit/should

// ---------------------------------------------------------------------------
// Helper: build a proposal with known fields
// ---------------------------------------------------------------------------

fn make_proposal(
  id: String,
  channel_id: String,
  message_id: String,
  reply_to: process.Subject(brain_tools.ProposalResult),
) -> brain_tools.PendingProposal {
  brain_tools.PendingProposal(
    id: id,
    path: "/tmp/aura-task7-test.txt",
    content: "hello",
    description: "test proposal",
    channel_id: channel_id,
    message_id: message_id,
    tier: 1,
    requested_at_ms: time.now_ms(),
    reply_to: reply_to,
  )
}

fn make_shell_approval(
  id: String,
  channel_id: String,
  message_id: String,
  reply_to: process.Subject(brain_tools.ProposalResult),
) -> brain_tools.PendingShellApproval {
  brain_tools.PendingShellApproval(
    id: id,
    command: "echo hello",
    reason: "test approval",
    channel_id: channel_id,
    message_id: message_id,
    requested_at_ms: time.now_ms(),
    reply_to: reply_to,
  )
}

fn stored_shell_approval(
  approval: brain_tools.PendingShellApproval,
) -> db.StoredShellApproval {
  db.StoredShellApproval(
    id: approval.id,
    channel_id: approval.channel_id,
    message_id: approval.message_id,
    command: approval.command,
    reason: approval.reason,
    status: "pending",
    requested_at_ms: approval.requested_at_ms,
    updated_at_ms: approval.requested_at_ms,
  )
}

// ---------------------------------------------------------------------------
// Test 1: RegisterProposal stores in state (pure transition test)
// ---------------------------------------------------------------------------

pub fn register_proposal_stored_in_channel_actor_test() {
  let state = channel_actor.initial_state_for_test("ch1")
  let reply_to = process.new_subject()
  let proposal = make_proposal("p1", "ch1", "m1", reply_to)

  let #(new_state, _effects) =
    channel_actor.transition(state, channel_actor.RegisterProposal(proposal))

  new_state.pending_proposals
  |> should.equal([proposal])
}

// ---------------------------------------------------------------------------
// Test 2: RegisterShellApproval stores in state (pure transition test)
// ---------------------------------------------------------------------------

pub fn register_shell_approval_stored_in_channel_actor_test() {
  let state = channel_actor.initial_state_for_test("ch1")
  let reply_to = process.new_subject()
  let approval = make_shell_approval("s1", "ch1", "m1", reply_to)

  let #(new_state, _effects) =
    channel_actor.transition(
      state,
      channel_actor.RegisterShellApproval(approval),
    )

  new_state.pending_shell_approvals
  |> should.equal([approval])
}

pub fn cancel_restarted_shell_approvals_emits_cancel_effect_test() {
  let state = channel_actor.initial_state_for_test("ch1")

  let #(new_state, effects) =
    channel_actor.transition(state, channel_actor.CancelRestartedShellApprovals)

  new_state.pending_shell_approvals |> should.equal([])
  effects |> should.equal([channel_actor.CancelPendingShellApprovals])
}

// ---------------------------------------------------------------------------
// Test 3: RegisterProposal supersedes an existing one, sends Expired to old
// ---------------------------------------------------------------------------

pub fn register_proposal_supersedes_existing_test() {
  let state = channel_actor.initial_state_for_test("ch1")
  let old_reply = process.new_subject()
  let old_proposal = make_proposal("p-old", "ch1", "m-old", old_reply)

  // Register first proposal
  let #(state_after_first, _) =
    channel_actor.transition(
      state,
      channel_actor.RegisterProposal(old_proposal),
    )

  // Register second proposal for same channel — should supersede
  let new_reply = process.new_subject()
  let new_proposal = make_proposal("p-new", "ch1", "m-new", new_reply)

  let #(state_after_second, effects) =
    channel_actor.transition(
      state_after_first,
      channel_actor.RegisterProposal(new_proposal),
    )

  // Old reply_to should have received Expired
  let assert Ok(result) = process.receive(old_reply, 1000)
  result |> should.equal(brain_tools.Expired)

  // New proposal is now the only one
  state_after_second.pending_proposals
  |> should.equal([new_proposal])

  // An effect was emitted to edit the old message (DiscordEdit "~~Superseded~~")
  let has_edit =
    effects
    |> list.any(fn(e) {
      case e {
        channel_actor.DiscordEdit("m-old", "~~Superseded~~") -> True
        _ -> False
      }
    })
  has_edit |> should.be_true
}

pub fn register_shell_approval_supersedes_existing_and_persists_status_test() {
  let state = channel_actor.initial_state_for_test("ch1")
  let old_reply = process.new_subject()
  let old_approval = make_shell_approval("s-old", "ch1", "m-old", old_reply)
  let #(state_after_first, _) =
    channel_actor.transition(
      state,
      channel_actor.RegisterShellApproval(old_approval),
    )

  let new_reply = process.new_subject()
  let new_approval = make_shell_approval("s-new", "ch1", "m-new", new_reply)
  let #(state_after_second, effects) =
    channel_actor.transition(
      state_after_first,
      channel_actor.RegisterShellApproval(new_approval),
    )

  let assert Ok(result) = process.receive(old_reply, 1000)
  result |> should.equal(brain_tools.Expired)
  state_after_second.pending_shell_approvals |> should.equal([new_approval])

  effects
  |> list.any(fn(e) {
    case e {
      channel_actor.PersistShellApprovalStatus("s-old", "superseded") -> True
      _ -> False
    }
  })
  |> should.be_true
}

// ---------------------------------------------------------------------------
// Test 4: HandleInteractionResolve "reject" on proposal sends Rejected
// (uses handle_message so the effect interpreter runs and sends to reply_to)
// ---------------------------------------------------------------------------

pub fn handle_interaction_resolve_reject_proposal_sends_rejected_test() {
  let state = channel_actor.initial_state_for_test("ch1")
  let reply_to = process.new_subject()
  let proposal = make_proposal("p1", "ch1", "m1", reply_to)

  // Register proposal directly in state
  let state_with_proposal =
    channel_actor.ChannelState(..state, pending_proposals: [proposal])

  // Call handle_message (runs transition + interpreter) to process the rejection
  let _next =
    channel_actor.handle_message(
      state_with_proposal,
      channel_actor.HandleInteractionResolve("reject", "p1"),
    )

  // Interpreter should have sent Rejected to reply_to
  let assert Ok(result) = process.receive(reply_to, 1000)
  result |> should.equal(brain_tools.Rejected)
}

// ---------------------------------------------------------------------------
// Test 5: HandleInteractionResolve "reject" on shell approval sends Rejected
// ---------------------------------------------------------------------------

pub fn handle_interaction_resolve_reject_shell_approval_sends_rejected_test() {
  let state = channel_actor.initial_state_for_test("ch1")
  let assert Ok(db_subject) = db.start(":memory:")
  let state =
    channel_actor.ChannelState(
      ..state,
      tool_ctx: brain_tools.ToolContext(
        ..state.tool_ctx,
        db_subject: db_subject,
      ),
    )
  let reply_to = process.new_subject()
  let approval = make_shell_approval("s1", "ch1", "m1", reply_to)
  let assert Ok(_) =
    db.save_shell_approval(db_subject, stored_shell_approval(approval))

  let state_with_approval =
    channel_actor.ChannelState(..state, pending_shell_approvals: [approval])

  let _next =
    channel_actor.handle_message(
      state_with_approval,
      channel_actor.HandleInteractionResolve("reject", "s1"),
    )

  let assert Ok(result) = process.receive(reply_to, 1000)
  result |> should.equal(brain_tools.Rejected)
  db.load_pending_shell_approvals_for_channel(db_subject, "ch1")
  |> should.be_ok
  |> should.equal([])
  process.send(db_subject, db.Shutdown)
}

// ---------------------------------------------------------------------------
// Test 6: HandleInteractionResolve "approve" on shell approval sends Approved
// ---------------------------------------------------------------------------

pub fn handle_interaction_resolve_approve_shell_approval_sends_approved_test() {
  let state = channel_actor.initial_state_for_test("ch1")
  let assert Ok(db_subject) = db.start(":memory:")
  let state =
    channel_actor.ChannelState(
      ..state,
      tool_ctx: brain_tools.ToolContext(
        ..state.tool_ctx,
        db_subject: db_subject,
      ),
    )
  let reply_to = process.new_subject()
  let approval = make_shell_approval("s1", "ch1", "m1", reply_to)
  let assert Ok(_) =
    db.save_shell_approval(db_subject, stored_shell_approval(approval))

  let state_with_approval =
    channel_actor.ChannelState(..state, pending_shell_approvals: [approval])

  let _next =
    channel_actor.handle_message(
      state_with_approval,
      channel_actor.HandleInteractionResolve("approve", "s1"),
    )

  let assert Ok(result) = process.receive(reply_to, 1000)
  result |> should.equal(brain_tools.Approved)
  db.load_pending_shell_approvals_for_channel(db_subject, "ch1")
  |> should.be_ok
  |> should.equal([])
  process.send(db_subject, db.Shutdown)
}

pub fn handle_interaction_approve_without_pending_db_row_rejects_test() {
  let state = channel_actor.initial_state_for_test("ch1")
  let assert Ok(db_subject) = db.start(":memory:")
  let state =
    channel_actor.ChannelState(
      ..state,
      tool_ctx: brain_tools.ToolContext(
        ..state.tool_ctx,
        db_subject: db_subject,
      ),
    )
  let reply_to = process.new_subject()
  let approval = make_shell_approval("s1", "ch1", "m1", reply_to)

  let state_with_approval =
    channel_actor.ChannelState(..state, pending_shell_approvals: [approval])

  let _next =
    channel_actor.handle_message(
      state_with_approval,
      channel_actor.HandleInteractionResolve("approve", "s1"),
    )

  let assert Ok(result) = process.receive(reply_to, 1000)
  result |> should.equal(brain_tools.Rejected)
  process.send(db_subject, db.Shutdown)
}

// ---------------------------------------------------------------------------
// Test 7: HandleInteractionResolve on expired proposal sends Expired
// ---------------------------------------------------------------------------

pub fn handle_interaction_resolve_expired_proposal_sends_expired_test() {
  let state = channel_actor.initial_state_for_test("ch1")
  let reply_to = process.new_subject()
  // Create an expired proposal: requested_at_ms far in the past
  let expired_proposal =
    brain_tools.PendingProposal(
      id: "p-expired",
      path: "/tmp/test.txt",
      content: "content",
      description: "desc",
      channel_id: "ch1",
      message_id: "m-expired",
      tier: 1,
      requested_at_ms: time.now_ms() - 1_000_000,
      // 1000 seconds ago (> 15 min)
      reply_to: reply_to,
    )

  let state_with_proposal =
    channel_actor.ChannelState(..state, pending_proposals: [expired_proposal])

  let _next =
    channel_actor.handle_message(
      state_with_proposal,
      channel_actor.HandleInteractionResolve("approve", "p-expired"),
    )

  let assert Ok(result) = process.receive(reply_to, 1000)
  result |> should.equal(brain_tools.Expired)
}

// ---------------------------------------------------------------------------
// Test 8: HandleInteractionResolve with unknown approval_id — transition check
// ---------------------------------------------------------------------------

pub fn handle_interaction_resolve_unknown_id_is_noop_test() {
  let state = channel_actor.initial_state_for_test("ch1")

  let #(new_state, effects) =
    channel_actor.transition(
      state,
      channel_actor.HandleInteractionResolve("approve", "nonexistent"),
    )

  // State unchanged, no effects
  new_state.pending_proposals |> should.equal([])
  new_state.pending_shell_approvals |> should.equal([])
  effects |> should.equal([])
}

// ---------------------------------------------------------------------------
// Test 9: HandleInteractionResolve removes proposal from state (transition)
// ---------------------------------------------------------------------------

pub fn handle_interaction_resolve_removes_proposal_from_state_test() {
  let state = channel_actor.initial_state_for_test("ch1")
  let reply_to = process.new_subject()
  let proposal = make_proposal("p1", "ch1", "m1", reply_to)

  let #(state_with_proposal, _) =
    channel_actor.transition(state, channel_actor.RegisterProposal(proposal))

  let #(new_state, effects) =
    channel_actor.transition(
      state_with_proposal,
      channel_actor.HandleInteractionResolve("reject", "p1"),
    )

  // Proposal removed from state
  new_state.pending_proposals |> should.equal([])

  // ResolveProposal effect emitted
  let has_resolve =
    effects
    |> list.any(fn(e) {
      case e {
        channel_actor.ResolveProposal(_, "reject") -> True
        _ -> False
      }
    })
  has_resolve |> should.be_true
}

// ---------------------------------------------------------------------------
// Test 10: 3-part custom_id parse — pure parse test
// ---------------------------------------------------------------------------

pub fn three_part_custom_id_parse_test() {
  // This tests the string parsing logic directly
  let custom_id = "approve:ch1:p1"
  let parts = string.split(custom_id, ":")
  parts |> should.equal(["approve", "ch1", "p1"])

  let custom_id2 = "reject:my-channel:sh123"
  let parts2 = string.split(custom_id2, ":")
  parts2 |> should.equal(["reject", "my-channel", "sh123"])

  // Old 2-part format should NOT match 3-part pattern
  let old_format = "approve:p1"
  let old_parts = string.split(old_format, ":")
  // 2 parts, not 3
  list.length(old_parts) |> should.equal(2)
}
