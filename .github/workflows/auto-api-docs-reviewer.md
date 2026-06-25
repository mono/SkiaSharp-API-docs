---
description: "On-demand API documentation review — audits EXISTING mdoc XML for a scope (default the text/font slice), fixes CRITICAL + obsolete-example findings by editing the XML directly, and opens a PR. Doubles as the CI exercise of per-sub-agent model routing."

# -- Triggers ----------------------------------------------------------
# Dispatch-only: this is the periodic/on-demand REVIEW dual of the daily
# auto-api-docs-writer (which only fills `To be added.` placeholders). Review
# operates on already-filled docs, so there is no stub-regeneration job here.
on:
  workflow_dispatch:
    inputs:
      skiasharp_branch:
        description: "SkiaSharp branch to use for the skill, scripts, source x-ref, and binding build"
        required: false
        default: "main"
        type: string
      scope:
        description: "Review scope selector (docs-tool.ps1 grammar): group:text, type:SKFont, ns:HarfBuzzSharp, all, changed, match:font"
        required: false
        default: "group:text"
        type: string

# -- Checkout ----------------------------------------------------------
# Primary: this docs repo (its committed SkiaSharpAPI/*.xml is what we review).
# SkiaSharp is cloned in pre-agent-steps for the skill + C# source + binding.
# fetch-depth: 1 is sufficient — `validate` compares each edited file against the
# checked-out HEAD (the working-tree fallback in docs-tool.ps1), not origin/main.
checkout:
  - fetch-depth: 1
timeout-minutes: 120
concurrency:
  group: auto-api-docs-reviewer
  cancel-in-progress: true

# -- Agent tools -------------------------------------------------------
tools:
  github:
    toolsets: [repos]
    allowed-repos: ["mono/skiasharp", "mono/skiasharp-api-docs"]
    min-integrity: none
  bash: ["*"]
  edit:

# -- Network allowlist -------------------------------------------------
network:
  allowed:
    - defaults
    - github
    - dotnet

# -- Permissions -------------------------------------------------------
permissions:
  contents: read

# -- Safe outputs ------------------------------------------------------
safe-outputs:
  create-pull-request:
    draft: false
    base-branch: main
    preserve-branch-name: true
    recreate-ref: true

# -- Pre-agent steps (host) -------------------------------------------
pre-agent-steps:
  - name: Record review scope
    env:
      REVIEW_SCOPE: ${{ inputs.scope || 'group:text' }}
    run: |
      printf '%s' "${REVIEW_SCOPE}" > review-scope.txt
      echo "Review scope: $(cat review-scope.txt)"

  - name: Clone SkiaSharp (shallow, with submodules)
    env:
      SKIASHARP_BRANCH: ${{ inputs.skiasharp_branch || 'main' }}
    run: |
      git clone --depth 1 --branch "$SKIASHARP_BRANCH" \
        --recurse-submodules --shallow-submodules \
        https://github.com/mono/SkiaSharp.git skiasharp
      mkdir -p skiasharp/docs
      ln -sfn "$(pwd)/SkiaSharpAPI" skiasharp/docs/SkiaSharpAPI
      cd skiasharp && dotnet tool restore

  # Build the managed binding so reviewer-examples can compile-check snippets
  # against a real SkiaSharp.dll. C#-only — externals-download fetches prebuilt
  # natives (no native changes here). Non-fatal: a build hiccup must not sink the
  # review, since the reviewer also verifies examples by reading source.
  - name: Bootstrap SkiaSharp binding for snippet checks
    continue-on-error: true
    run: |
      cd skiasharp
      dotnet cake --target=externals-download
      dotnet build binding/SkiaSharp/SkiaSharp.csproj -c Release

# -- Post-agent steps (host) ------------------------------------------
# Format docs AFTER the agent edits the XML in place. Runs on host outside the
# sandbox so it has full access to the SkiaSharp cake scripts.
post-steps:
  - name: Format docs
    run: cd skiasharp && dotnet cake --target=docs-format-docs
---

# Auto API Docs Reviewer

You are the **orchestrator** for the `review` workflow — the dual of the writer. The writer fills blanks;
**you audit and improve docs that are already filled** for a scope, fix the high-severity issues, and open a
PR. Read these first, then drive the phases below:

- `skiasharp/.agents/skills/api-docs/SKILL.md` — the router.
- `skiasharp/.agents/skills/api-docs/workflows/review.md` — the review pipeline **and the per-role model table**.
- `skiasharp/.agents/skills/api-docs/workflows/scope-resolution.md` — how the scope selector resolves to files.
- `skiasharp/.agents/skills/api-docs/workflows/validation.md` — the post-edit gates.

The docs repo is the **primary checkout**; its committed `SkiaSharpAPI/*.xml` is what you review. There is
**no extract/merge JSON step** — you edit the mdoc XML directly; safety comes from the structural validator.

## Why this run matters (it is also an eval)

This workflow is the first real CI exercise of **per-sub-agent model routing**. You MUST launch every
sub-agent via the `task` tool with an explicit `model`, and you MUST report — in stdout and in the PR body —
which model you requested for each role and whether the sandbox honored it. See "Routing report" below.

## Model routing

You run on the default `engine.model` (cheap orchestrator). You do **not** review or write docs yourself.
Launch every sub-agent **via the `task` tool with an explicit `model`**, reading the per-role value from the
table in `workflows/review.md` and each agent file's `Model:` header:

| Sub-agent | Model |
|---|---|
| reviewer-factual | `gpt-5.5` (eval bake-off winner) |
| reviewer-examples | `claude-opus-4.6` |
| reviewer-quality | `claude-sonnet-4.6` |
| review-synthesizer | `claude-sonnet-4.6` |
| writer (fix step) | `claude-opus-4.6` |

If the sandbox does **not** honor per-sub-agent `model` (it errors, or forces the parent model), proceed on
`engine.model` for all roles and record that in the Routing report and PR body — **do not abort**.

## Scope environment

`docs-tool.ps1` lives in the SkiaSharp clone, so by default it looks for docs under `skiasharp/docs`. Here the
**docs repo is the primary checkout**, so point the tool at it by exporting these on every `docs-tool.ps1`
call (they make `resolve-scope`, `lint`, and `validate` use the docs repo for git baselines/diffs while source
lookups still use the SkiaSharp clone):

```bash
DOCS_GIT_ROOT="$GITHUB_WORKSPACE" DOCS_DIR="$GITHUB_WORKSPACE/SkiaSharpAPI"
```

The review scope selector is in `review-scope.txt` at the workspace root (default `group:text`).

## Execution order

1. **Resolve scope.** Read the selector and resolve it to an explicit file list (fuzzy selectors need
   `-Confirm:$false` in CI). The text/font slice is ~16 files — one batch; for larger scopes, shard into
   ~25–40-file batches.
   ```bash
   SCOPE="$(cat review-scope.txt)"
   cd skiasharp && DOCS_GIT_ROOT="$GITHUB_WORKSPACE" DOCS_DIR="$GITHUB_WORKSPACE/SkiaSharpAPI" \
     pwsh .agents/skills/api-docs/scripts/docs-tool.ps1 resolve-scope "$SCOPE" -Confirm:$false && cd ..
   ```

2. **Lint (deterministic, no model).** Run the linter over the resolved files to catch objective defects.
   ```bash
   cd skiasharp && DOCS_GIT_ROOT="$GITHUB_WORKSPACE" DOCS_DIR="$GITHUB_WORKSPACE/SkiaSharpAPI" \
     pwsh .agents/skills/api-docs/scripts/docs-tool.ps1 lint "$SCOPE" && cd ..
   ```

3. **Review (three reviewers in parallel).** Launch `reviewer-factual`, `reviewer-examples`, and
   `reviewer-quality` via the `task` tool, each with its assigned model, on the resolved file list. They
   **report only** (one `SEVERITY | class | file | docId | message` line each). Then feed the linter output +
   all three reviewers' findings to `review-synthesizer` to dedupe/normalize.

4. **Fix (gated, this run).** Edit the XML directly to resolve, in priority order: (a) all **CRITICAL**
   findings, (b) **obsolete-in-example** findings (the text/font slice has legacy `paint.TextSize` /
   `TextAlign` / `DrawText(string,x,y,paint)` examples — migrate them to `SKFont`), (c) where a central type is
   example-poor (e.g. `SKFont`, `SKTypeface`, `SKPaint`), add one correct, compiling example, porting the
   `SKCanvas`/`SKShader` quality bar. Launch the **writer** sub-agent for the edits. **Budget:** if you pass
   ~60 minutes, stop fixing, validate what you have, and open the PR — a smaller validated PR beats none.

5. **Validate (MUST pass before the PR).** This is the gate that makes direct editing safe:
   ```bash
   cd skiasharp && DOCS_GIT_ROOT="$GITHUB_WORKSPACE" DOCS_DIR="$GITHUB_WORKSPACE/SkiaSharpAPI" \
     pwsh .agents/skills/api-docs/scripts/docs-tool.ps1 validate "$SCOPE" && cd ..
   ```
   It asserts each changed file is well-formed, has unchanged signature counts, and changed **only** inside
   `<Docs>`. Do **not** run `docs-format-docs` — formatting runs automatically as a post-step.

6. **Routing report (ALWAYS).** Print to stdout a block delimited exactly like this, filled in from what the
   `task` tool actually did, so the run is auditable even if no fixes were made:
   ```
   === ROUTING REPORT ===
   reviewer-factual    | requested: gpt-5.5          | honored: <yes|no|fallback> | note: ...
   reviewer-examples   | requested: claude-opus-4.6  | honored: <yes|no|fallback> | note: ...
   reviewer-quality    | requested: claude-sonnet-4.6| honored: <yes|no|fallback> | note: ...
   review-synthesizer  | requested: claude-sonnet-4.6| honored: <yes|no|fallback> | note: ...
   writer              | requested: claude-opus-4.6  | honored: <yes|no|fallback> | note: ...
   === END ROUTING REPORT ===
   ```
   Base "honored" on observable evidence: whether the `task` call accepted the `model` parameter, any
   model-not-supported error the sandbox surfaced, and any self-reported model from the sub-agent. If you had
   to fall back to a single model for all roles, say so explicitly.

7. **Commit and PR.** If step 4 produced edits:
   ```bash
   git checkout -b automation/review-api-docs
   git add SkiaSharpAPI/
   git commit -m "Review and improve API documentation (scope: <scope>)"
   ```
   Then use the `create_pull_request` tool:
   - Branch: `automation/review-api-docs`
   - Title: `Review and improve API documentation (<scope>)`
   - Body: include (a) the scope reviewed and file count, (b) the **Routing report** block verbatim, (c) a
     short **Findings summary** (counts by severity + the synthesizer's machine `FINDING |` block), and (d)
     what you fixed vs deferred.

   If step 4 produced **no** edits (nothing CRITICAL/obsolete to fix), call the `noop` tool — but still print
   the Routing report and Findings summary to stdout first so the eval is observable in the run logs.

## Critical rules

- **Edit the mdoc XML directly.** Touch only `<Docs>` content — never `MemberSignature`/`TypeSignature`,
  attributes, or generated files (`index.xml`, `ns-*.xml`, `_filter.xml`, `FrameworksIndex/`). The structural
  validator enforces this; a failure means you edited outside `<Docs>`.
- **Step 5 (validate) MUST pass before the PR.** If you skip it, a malformed or surface-changing edit can ship.
- **Sub-agents must NOT spawn their own sub-agents.** Each agent does all its work directly — nested sub-agents
  hit the depth limit and time out.
- **Do NOT run `docs-format-docs`** — formatting runs automatically as a post-step.
- **Every code example you add or change must compile** against the real `SkiaSharp.dll` (bootstrapped in a
  pre-step) and use **no obsolete members** (see `references/obsolete-api-map.md`). A non-compiling example is
  worse than none.
- **NEVER end a turn without a tool call while waiting for agents.** When you launch a background agent, you
  MUST call `read_agent` with `wait: true` in the SAME response. Outputting "waiting" and ending the turn
  terminates the session and loses all work.
  - **Single agent:** `task(background)` + `read_agent(id, wait=true)` in the same response.
  - **Multiple agents:** launch all, then `read_agent` the first with `wait: true`; when it returns, read the
    next, and so on. Keep an active `read_agent` call at all times until all agents complete.
  - **FORBIDDEN:** launching agents → "Waiting for them to complete" → ending the turn. This KILLS the session.
- **COMPLETION GATE:** Your session is NOT complete until you have called `create_pull_request` or `noop`, and
  you have printed the Routing report. If you think you're done but did neither, retrace your steps and finish.

## Path differences from SKILL.md

Because this workflow runs from the docs repo (not SkiaSharp), paths differ:

| SKILL.md reference | Actual path in this workflow |
|---|---|
| `docs/SkiaSharpAPI/` | `SkiaSharpAPI/` (repo root) |
| `.agents/skills/api-docs/` | `skiasharp/.agents/skills/api-docs/` |
| `binding/SkiaSharp/` | `skiasharp/binding/SkiaSharp/` |
| `binding/HarfBuzzSharp/` | `skiasharp/binding/HarfBuzzSharp/` |
| `samples/Gallery/Shared/Samples/` | `skiasharp/samples/Gallery/Shared/Samples/` |
