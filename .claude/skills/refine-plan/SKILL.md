---
name: refine-plan
description: Audits an ExecPlan for structural completeness, self-containment, milestone quality, dead references, contradictions, ambiguities, and fragile anchors. Returns a structured report quoting specific lines. Triggers on: refine plan, review plan, audit plan, check plan, plan review.
user-invocable: true
allowed-tools: Read, Grep, Glob
---

# ExecPlan Refinement

Audit an ExecPlan for consistency, completeness, and executability by a stateless agent.

## Input

Accept one of:

- A file path to an ExecPlan (read it first)
- A `$ARGUMENTS` reference (treat as file path)
- An ExecPlan pasted inline

If no input is provided, list files in `docs/exec-plans/` and ask which plan to audit.

## Analysis

Read the ExecPlan fully, then work through each check. For every finding, quote the specific line or section. Skip checks that produce no findings.

### Structural completeness

Verify these mandatory sections exist and are non-empty:

- Purpose / Big Picture
- Progress (must use checkboxes)
- Surprises & Discoveries
- Decision Log
- Outcomes & Retrospective
- Context and Orientation
- Milestones (at least one)
- Overall Validation
- Idempotence and Recovery
- Interfaces and Dependencies

Sections containing only placeholder text ("To be filled", "TBD") count as empty if the Progress section shows completed work. A plan with zero progress may have placeholder living sections — that is expected.

### Self-containment

Flag any of:

- References to conversations, threads, or context not embedded in the plan ("as discussed", "per our conversation", "see the slack thread")
- References to prior ExecPlans that are not checked into the repo (verify with Glob)
- Undefined jargon — domain-specific terms used without a plain-language definition nearby
- "As defined previously" or "see above" when the referenced content is not actually above
- Assumptions about what the reader already knows about the repo beyond what the Context section provides

### Milestone quality

For each milestone, verify:

- **Scope** exists and describes what will exist after that did not exist before
- **Steps** exist with full repo-relative file paths and concrete edits (not "update the relevant files")
- **Acceptance criteria** exist and are phrased as observable behavior ("run X, observe Y"), not internal attributes ("added struct Z")
- **Verification commands** exist and name specific commands or reference `/verify-milestone`
- **Rollback** exists

Flag milestones that are too large to implement in a single focused session (heuristic: touches more than 8 files or spans more than 3 packages).

### Dead references

Use Glob to check that every repo-relative file path mentioned in the plan exists on disk. Use Grep to spot-check function names, type names, and module names referenced in Steps sections. Report paths and symbols that do not exist.

### Fragile references

Flag references to specific line numbers (e.g., "line 134", "after line 56"). These drift as the codebase changes. Suggest using surrounding-context anchors instead ("after the `resolveOutputAmounts` field in `OpDef`").

### Contradictions

Check for:

- Steps in one milestone that contradict steps in another
- Acceptance criteria that contradict the Purpose section
- Progress checkmarks that contradict the actual milestone descriptions
- Decision Log entries that conflict with the plan's current approach

### Ambiguities

Flag:

- Steps with vague scope ("update the relevant files", "adjust as needed", "handle edge cases")
- Undefined quantifiers ("some", "a few", "several")
- Acceptance criteria that cannot be mechanically verified
- Unclear scope boundaries between milestones — two milestones that could plausibly both own the same change

### Stale state

Check for inconsistencies between the living sections and the plan state:

- Progress shows completed milestones but Surprises/Decision Log/Outcomes are still placeholder
- Progress checkmarks that reference milestones or steps that don't exist in the plan
- Timestamps in Progress that are out of chronological order

## Output

Return exactly this structure, omitting sections with no findings:

```
## Structural Completeness
- [findings or "All mandatory sections present"]

## Self-Containment
- [findings or "Plan is self-contained"]

## Milestone Quality
- [findings per milestone or "All milestones well-formed"]

## Dead References
- [findings or "All paths and symbols verified"]

## Fragile References
- [findings or "No line-number anchors found"]

## Contradictions
- [findings or "None found"]

## Ambiguities
- [findings or "None found"]

## Stale State
- [findings or "Living sections consistent with progress"]

## Summary
[One paragraph: is this plan ready for implementation by a stateless agent? If not, what are the blocking issues vs nice-to-fix issues?]
```

## Rules

- Quote the specific lines or sections for every finding
- Distinguish blocking issues (plan cannot be executed as-is) from advisory issues (could be better)
- Do not rewrite the plan — report findings and let the user decide how to revise
- If the plan is clean, say so — do not invent problems to justify the audit
- For dead references, only flag paths you actually checked with Glob/Grep — do not guess
