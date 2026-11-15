# VEIL

VEIL analyses a piece of text, a social media post or a web page for propaganda and manipulation techniques. It
explains what it found in plain language and shows where the topic is covered around the world.

Live: **https://stiriri.dev**

This is the parent repository of the `junction-2026` organization. It holds:
- the feature issues;
- the cross-repository integration harness;
- the release and deploy pipeline.

The application code lives in the component repositories below.

## What it does

1. **Submit** pasted text or a link to a Bluesky post, a Mastodon post or a web page. VEIL fetches the content and
   normalises it.
2. **Analyse.** A set of independent analyzers runs in parallel. Their progress streams live to the browser.
   - **Translation:** translates the text to English for the models that need it.
   - **Propaganda detection:** a classifier that labels the whole text.
   - **Techniques:** classifiers score known manipulation techniques (loaded language, bandwagon, appeal to fear,
     straw man…) and mark the phrases that carry them.
   - **LLM techniques:** a language model reviews the text and explains each finding.
   - **Topic and claim extraction:** feeds the next three analyzers.
     - **News search:** finds related coverage.
     - **Fact checks:** looks up the claims in Google Fact Check Tools.
     - **Wikipedia:** looks up background on the topics.
   - **Source info:** matches the page and the related coverage against an outlet table (country, outlet), then
     **country association** works out which countries the content is about.
   - **Text statistics** and, where configured, **bot / generated-text detection**.
3. **Final assessment.** A finalizer weighs all results into a verdict: *detected*, *not detected* or *uncertain*,
   with a confidence score and a short explanation for the reader.

## Pages

- **Analyze:** submit text or a link, choose analyzers, or try example statements.
- **Results:** the verdict, techniques with highlighted phrases, fact checks, related coverage and sources. Model
  explanations can be translated into the interface language.
- **Explore:** a global map of analyses with detected techniques, by country, and a per-analysis map of where the
  topic was covered.
- **History:** previous analyses.
- **Ask VEIL:** chat with an assistant about a finished analysis.

The interface is available in English, French, German, Finnish, Russian and Arabic (right-to-left).

## Repositories

| Repository | Contents |
| --- | --- |
| [`backend`](https://github.com/junction-2026/backend) | Go HTTP server: job API, analyzer engine and registry, scrapers, finalizer, map API, job history (SQLite) |
| [`frontend`](https://github.com/junction-2026/frontend) | React + TypeScript + Vite web app |
| [`shared-specs`](https://github.com/junction-2026/shared-specs) | OpenSpec contracts shared by backend and frontend (job API, events, map API…) |
| `project` (this one) | Feature issues, integration harness, release manifests and deploy scripts |

Each component repository has a README with run instructions and configuration.

## How the project is built

Changes are spec-driven with [OpenSpec](https://github.com/Fission-AI/OpenSpec):
- **Spec first:** every change carries `openspec/changes/<id>/` (proposal, tasks, delta specs) and is validated
  in CI.
- **Shared contracts:** contracts between backend and frontend are agreed in `shared-specs` before
  implementation.

Most work is planned, implemented and reviewed by AI coding agents through the Junction orchestrator:
1. **Request:** a feature request becomes a parent issue here.
2. **Plan:** the orchestrator plans it into tasks in the component repositories.
3. **Approve:** humans approve the plan and the specs.
4. **Implement and review:** agents open and review the pull requests.
5. **Merge:** validated groups of PRs are tested together and merged.

### This repository

| Path | Purpose |
| --- | --- |
| `.github/ISSUE_TEMPLATE/feature.yml` | Feature issue template |
| `.github/workflows/ci.yml` | `repo-ci`: OpenSpec validation |
| `.github/workflows/integration.yml` | Integration suites for a candidate set of component PRs |
| `.github/workflows/deploy.yml` | Deploys a published release (digest-pinned images) |
| `integration/` | Test harness (`compose.yaml`) and suite definitions (`test-suites.yaml`) |
| `scripts/` | `validate-openspec.sh`, release-manifest validation, deploy, smoke test and report |

Rules for contributors are in [`CLAUDE.md`](CLAUDE.md):
- run `scripts/validate-openspec.sh` before pushing;
- never push to `main`.

## Releases and deployment

- **Release:** a release is an immutable manifest of digest-pinned backend and frontend images.
- **Deploy:** publishing a release runs `deploy.yml`, which deploys it with Docker Compose and marks it healthy
  only after the smoke test passes.
- **Rollback:** if the smoke test fails, the previous healthy release's app images are restored automatically
  and the deploy fails. An older release can only be deployed by an explicit operator rollback (`deploy.yml`
  dispatched with `rollback=true`). Rollback covers app images only: databases are never restored automatically,
  though an operator can pass `restore_state` to restore named state snapshots.
