# Cognitive Capacity Design Stress Test

Updated 2026-04-24

Status: adversarial review note. The typed cognitive-ontology plan failed this
stress test and has been replaced by the minimal-harness/text-policy direction
in `docs/architecture/cognitive-capacity.md`.

## Rejected Direction

The earlier design introduced code-level objects for concern matches, proposed
concerns, semantic claims, attention judgments, work dispositions, authority
requirements, gap events, and learned preferences.

That was too much structure too early. It risked turning Aura into a
human-designed symbolic cognition engine, which violates the Bitter Lesson
principle now recorded in `docs/ENGINEERING.md`.

## Accepted Correction

The executable architecture is now:

```text
AuraEvent
-> persisted event
-> evidence/context builder
-> ordinary text policies
-> ordinary markdown concern files
-> model decision envelope
-> validator / authority gate
-> decision log
-> replay evaluation
```

Code owns reliability. Text files own policy and active concern context. The
model owns interpretation. Replay decides whether additional structure is
needed.

## Stress-Test Claims

### 1. Does This Preserve Cognitive Capacity?

Yes, if proactive surfacing remains disabled until replay shows that decisions
reduce interruptions, missed important events, planning burden, or verification
burden.

Risk: without replay, Aura can become an interrupt generator with better prose.

### 2. Does This Respect The Bitter Lesson?

Mostly. It avoids a hand-built cognitive ontology and uses model judgment over
context. The remaining risk is evidence extraction growing into source-specific
semantic policy. Extraction must stay provenance-oriented.

### 3. Is Policy Inspectable?

Yes. Attention, authority, work, learning, and world-state behavior should be
stored in markdown files. The user can read, edit, disable, or revert behavior
without learning a schema.

### 4. Can It Generalize Across Sources?

Yes, because integrations only provide events and evidence. Source-specific
fields are context, not policy. The model interprets them under text policies
and concern files.

### 5. What Must Not Ship?

- Typed concern store before text concerns fail replay.
- Claim/action/gap taxonomies added by intuition.
- Proactive notifications before replay evaluation.
- Source-specific routing matrices.
- Learned preferences that cannot explain provenance and correction path.

## Remaining Risks

- The first live worker still only logs `context_ready`; it is not cognition.
- Model decision quality is untested until replay exists.
- Candidate concern-file selection can become a hidden router if not evaluated.
- Policy files can grow messy; if they do, structure should be extracted from
  repeated replay failures, not invented upfront.
