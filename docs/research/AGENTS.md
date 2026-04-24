# AGENTS.md

Updated 2026-04-24

## Module Intent

`docs/research/` stores literature notes, market scans, exploratory synthesis,
and design research that may inform product principles, architecture notes, or
ADRs. Research notes are allowed to be provisional, but they should make source
quality and relevance clear.

## Local Guidance

- Prefer primary papers, official project pages, publisher pages, and arXiv/OpenReview records.
- Record why a source matters to Aura, not just its title and URL.
- Separate "what this source claims" from "how Aura uses it."
- Preserve skepticism and limits. If a source has an outdated premise, say so.
- Link from architecture notes or ADRs back to the relevant research note rather
  than duplicating literature summaries.

## Pitfalls

- Do not let product-adjacent blog posts replace research sources when the
  research source exists.
- Do not overfit Aura's architecture to any single paper's vocabulary.
- Do not cite broad human-AI guidelines as if they solve agent orchestration;
  most were written for AI features inside applications, not manager agents.

## Open Questions

- Which research notes should become curated bibliographies versus historical
  brainstorming records?
- Should accepted literature anchors also be surfaced through `man aura-*`
  pages for runtime reference?
