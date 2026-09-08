# General Engineering Standards — MyProject

- Domain: engineering

> Project-specific engineering rules and observed repository facts. Only applicable sections are
> loaded into a Task Pack; explicit hard rules remain blocking for every covered path.

## Required project constraints

- Record only requirements explicitly approved for this project, such as a required toolchain,
  compatibility floor, deployment target, or prohibited dependency.
- **No additional project-specific constraint has been recorded yet.**

## Observed repository baseline

- `.` → role `xy-apple`; stacks: platform:apple; evidence: Quotio.xcodeproj/project.pbxproj
  - Discovered verification commands: ["xcodebuild", "-scheme", "Quotio", "build"]

These observations guide routing and verification; they are not upgrade targets or project rules.

## Verification policy

- `[eng-verification-001] [hard]` Use only verification commands justified by checked-in evidence
  and carried in the discovered project profile.
- `[eng-verification-002] [hard]` Every implementation Writer returns real build/test evidence
  through `xy-build-verify` before PM handoff.

## Environment and secrets

- `[eng-secrets-001] [hard]` Never commit secrets, credentials, private keys, tokens, or raw private
  data; use the project-approved environment or secret manager.
- Required environment variables and safe local defaults: **TODO**

## Contracts and changes

- Current project and feature index: `docs/PROJECT.md`
- Detailed feature contracts: `docs/features/`
- Breaking contract changes use the Full workflow and return cross-module routing to the PM.

## Project-specific rules

Add enforceable rules with a stable lowercase ID and explicit severity. Use `hard` only for a true
blocking contract; use `advisory` for a preferred practice whose justified deviation may still pass.

Replace this guidance with real, approved project rules; do not create placeholder rule IDs.
