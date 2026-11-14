# Bootstrap record

Repository: junction-2026/project
Role: parent repository (feature issues, integration harness, releases)
Bootstrapped: 2026-11-14T01:06:16Z by `junctionctl bootstrap`

## Bootstrap policy exception

This initial commit was pushed directly to the default branch by the
orchestrator bot, before any ruleset existed on this repository (docs/08
"Bootstrap only once by hand", step 5). The only other direct write the
policy allows is `junctionctl sync-templates -apply`, which brings the
orchestrator-managed files (validate-openspec.sh, repo-ci, the integration
harness) up to date with the templates. Every other change, including CI
changes, goes through an OpenSpec change, a pull request, repo-ci and the
orchestrator merge gate.

Seeded from templates: common, project, openspec-only.
OpenSpec: local root referencing store `project-contracts`.
