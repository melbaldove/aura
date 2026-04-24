# Cognitive Capacity Literature

Updated 2026-04-24

Status: living reference list for the cognitive-capacity and manager-agent
architecture. Use this note as provenance for
`docs/PRODUCT_PRINCIPLES.md` and `docs/architecture/cognitive-capacity.md`.

## Lens

Aura's thesis is that a long-running assistant should preserve and compound the
user's cognitive capacity. The brain acts as a metacognitive manager agent:
integrations provide evidence, flares do object-level work, and the brain
coordinates planning, verification, attention, authority, and gap resolution.

The literature considered here is useful when it helps answer one of these
questions:

- How do bounded humans and bounded AI systems fail under cognitive load?
- How should systems decide when to interrupt, defer, ask, or act?
- How should a manager agent coordinate humans and AI workers?
- How can agents reduce planning and verification burden?
- How should trust, explanation, correction, and authority be calibrated?
- How do people organize work around activities, concerns, and sensemaking
  rather than applications?

## Primary Anchors

### Cognitive Load And Bounded Agents

[Overloaded minds and machines: a cognitive load framework for human-AI symbiosis](https://link.springer.com/article/10.1007/s10462-026-11510-z)

Why it matters: This is the closest fit to Aura's cognitive-capacity thesis. It
compares human working memory and model context windows as bounded workspaces,
then highlights shared coping strategies such as chunking, offloading, and
structuring. Its most important point for Aura is the divergence around human
metacognition: humans monitor effort, overload, confidence, stress, and
subjective thresholds, while current AI systems usually require external
scaffolding to detect overload and change strategy.

Aura implication: implement metacognition at the system level. Flares do
object-level work; the brain monitors planning quality, verification quality,
uncertainty, authority, and user load.

### Manager Agents And Human-AI Teams

[Orchestrating Human-AI Teams: The Manager Agent as a Unifying Research Challenge](https://arxiv.org/abs/2510.02557)

Why it matters: Frames a manager agent as the orchestrator of dynamic teams of
human and AI workers. This is close to Aura's brain/flare split, though Aura's
objective is sharper: preserve cognitive capacity and compress planning and
verification into high-leverage judgment points.

Aura implication: the brain should be treated as a manager agent, not just a
router. It should maintain task graph state, assign work, monitor progress,
handle handoffs, and resolve gaps.

[The agentic shift: Making human-AI coordination work by addressing two critical junctures](https://www.sciencedirect.com/science/article/pii/S0007681325002010)

Why it matters: Identifies two coordination breakpoints for human-AI work:
directional alignment and information integrity. This maps well onto Aura's
planning and verification burden.

Aura implication: planning is directional alignment; verification is information
integrity. The brain should explicitly manage both, instead of only increasing
agent execution throughput.

[Quantifying the Expectation-Realisation Gap for Agentic AI Systems](https://arxiv.org/abs/2602.20292)

Why it matters: Reviews cases where agentic AI productivity expectations exceed
realized outcomes. It names workflow integration friction and verification
burden as major causes.

Aura implication: do not count agent output as progress until it is integrated,
verified, and useful. Aura should measure and reduce human oversight cost, not
only agent execution time.

## Attention And Interruption

[Attention-Sensitive Alerting](https://arxiv.org/abs/1301.6707)

Why it matters: Early formal work on deciding whether and when to alert based
on message value, user attention, and deferral cost. It is email-centric, but
the decision-theoretic frame is still valuable.

Aura implication: attention judgments should consider both the value of
surfacing and the cost of interrupting.

[Principles of Mixed-Initiative User Interfaces](https://www.microsoft.com/en-us/research/wp-content/uploads/2016/11/chi99horvitz.pdf)

Why it matters: Useful for uncertainty, timing, user goals, and mixed
automation/direct manipulation. But its premise is an AI feature inside a user
interface, not a 2026 user orchestrating agents.

Aura implication: keep the cost/benefit and uncertainty ideas; do not inherit
the older assumption that the user is merely receiving assistance from one
application feature.

[Oasis: A Framework for Linking Notification Delivery to the Perceptual Structure of Goal-Directed Tasks](https://www.researchgate.net/publication/220286367_Oasis_A_Framework_for_Linking_Notification_Delivery_to_the_Perceptual_Structure_of_Goal-Directed_Tasks)

Why it matters: Shows that interruption timing can be tied to task structure and
breakpoints. This is stronger than "important means interrupt now."

Aura implication: `surface_now`, `digest_later`, and `defer_until_condition`
should eventually consider user task boundaries and concern state, not only
event importance.

[The Cost of Interrupted Work: More Speed and Stress](https://www.ics.uci.edu/~gmark/chi08-mark.pdf)

Why it matters: Empirical grounding that interrupted people may compensate by
working faster, but pay with stress, frustration, time pressure, and effort.

Aura implication: avoid optimizing for apparent responsiveness. Hidden load
matters.

## Concerns, Activities, And Personal Information

[Activity-Centric Computing Systems](https://cacm.acm.org/research/activity-centric-computing-systems/)

Why it matters: Reviews work that organizes computing around human activities
that cut across applications, devices, resources, and collaborators. This is
close to Aura's `Concern` object, though "concern" is broader than activity.

Aura implication: concerns should group resources across Gmail, Linear, Jira,
Calendar, Git, CI, and future sources. Applications are evidence feeds, not the
unit of user work.

[Keeping Found Things Found: The Study and Practice of Personal Information Management](https://www.sciencedirect.com/book/9780123708663/keeping-found-things-found)

Why it matters: Personal information management studies how people keep,
organize, retrieve, and reuse personal information across roles and tasks.

Aura implication: concerns, memory, and evidence logs should reduce the user's
retrieval and re-briefing burden.

## Sensemaking, Planning, And Verification

[The Cost Structure of Sensemaking](https://www.markstefik.com/wp-content/uploads/2014/04/1993-Sensemaking-long-Stefik-Russell.pdf)

Why it matters: Sensemaking is framed as searching for representations and
encoding information to answer task-specific questions. Different
representations change the cost of cognition.

Aura implication: verified claims, proof packets, concern summaries, and
attention judgments are cost-reducing representations. Aura should not merely
produce more text.

[AI Chains: Transparent and Controllable Human-AI Interaction by Chaining Large Language Model Prompts](https://arxiv.org/abs/2110.01691)

Why it matters: Shows that decomposed LLM chains can improve transparency,
control, collaboration, expectation calibration, and debugging through
intermediate results.

Aura implication: planning and verification should produce inspectable
intermediate claims and checks, not opaque final answers.

[PromptChainer: Chaining Large Language Model Prompts through Visual Programming](https://arxiv.org/abs/2203.06566)

Why it matters: Extends the chain idea to authoring, debugging, and transforming
intermediate outputs at multiple granularities.

Aura implication: flares and brain handbacks need structured intermediate
states so the manager can verify, correct, or redirect work.

[Selenite: Scaffolding Online Sensemaking with Comprehensive Overviews Elicited from Large Language Models](https://doi.org/10.1145/3613904.3642149)

Why it matters: Uses LLM-generated overviews and criteria to jumpstart
sensemaking in unfamiliar domains.

Aura implication: Aura should help the user choose and understand problem
spaces, not just execute tasks. Summaries should include criteria, tradeoffs,
and options that support taste and problem selection.

## Human-AI Interaction, Control, And Trust

[Guidelines for Human-AI Interaction](https://www.erichorvitz.com/Guidelines_Human_AI_Interaction.pdf)

Why it matters: Useful checklist for expectations, contextual behavior,
correction, explanation, and adaptation over time. The caveat is important: it
was built for AI products/features, not a manager agent coordinating other
agents.

Aura implication: retain correction paths, explanations, uncertainty, and
expectation setting. Do not treat the guideline set as sufficient for
agent-orchestration cognitive load.

[People + AI Guidebook](https://pair.withgoogle.com/guidebook-v2/)

Why it matters: Practical design guidance around mental models, feedback,
explainability, data quality, and graceful failure.

Aura implication: learned preferences and proactive behavior need user-visible
correction and mental-model support.

[Human-Centered Artificial Intelligence: Reliable, Safe & Trustworthy](https://arxiv.org/abs/2002.04087)

Why it matters: Argues for high automation with high human control, rather than
choosing one extreme.

Aura implication: the tier model and authority requirements should enable high
routine automation while preserving human control over taste, risk, values, and
irreversible actions.

[Trust in Automation: Designing for Appropriate Reliance](https://journals.sagepub.com/doi/10.1518/hfes.46.1.50_30392)

Why it matters: The goal is calibrated trust: neither misuse nor disuse of
automation.

Aura implication: Aura should optimize appropriate reliance. Explanations,
confidence, verification status, and correction paths are part of the product,
not polish.

## Open Research Threads For Aura

- What is the smallest useful `Concern` model that spans people, tickets,
  branches, calendar events, projects, and learning frontiers?
- How should Aura represent the user's current cognitive posture without
  over-instrumenting or over-asking?
- Which planning and verification burdens can flares reliably reduce, and which
  must remain human judgment?
- How should the brain detect that a flare lacks the tool, context, confidence,
  or verification path to continue?
- What proof packet shape best lets the user verify agent work quickly?
- How should attention judgments be evaluated: fewer interruptions, faster
  recovery, better problem selection, lower verification burden, or all of
  these?
