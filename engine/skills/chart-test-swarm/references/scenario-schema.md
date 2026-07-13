# Scenario schema reference

The canonical JSON Schema lives at `engine/templates/scenario.schema.json`
in the bundled engine (a copy of the original at
`engine/templates/scenario.schema.json` in the repo root).

See also `docs/scenario-authoring.md` in the canonical engine repo for
the human-readable walk-through with examples.

## Provenance field (`generated_by`)

Scenarios produced by this skill MUST set:

```yaml
generated_by:
  by: chart-test-swarm-skill
  integration: <name>              # e.g. cert-manager
  at: <ISO-8601 UTC>
  skill_version: "0.1.0"
```

The dashboard filters / tags scenarios by `generated_by.by` so
hand-authored scenarios and skill-generated ones can be distinguished.

## Lifecycle of a generated scenario

1. **Skill writes it** with `generated_by: { by: chart-test-swarm-skill, … }`
2. **User edits it by hand** to refine / harden. As soon as a human edits
   it, drop the `generated_by` block (or set `by: hand-authored`). Don't
   pretend the LLM "owns" code the human has revised.
3. **User promotes it** by changing tags from `[nightly,
   customer-replica]` to include `pr-subset`. Skill doesn't auto-promote.
