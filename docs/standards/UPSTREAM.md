# Upstream and Second-Development Standards — MyProject

- Domain: engineering

> Define protected upstream/open-source boundaries here. If the project has no embedded upstream
> source, state that explicitly instead of inventing a protected path.

## Boundary declaration

- Protected upstream roots: **TODO or not applicable**
- Allowed extension/adaptor/overlay paths: **TODO or not applicable**
- Direct upstream edits: **forbidden without an approved exception | allowed by project policy**
- Upstream synchronization strategy: **TODO or not applicable**

## Exceptional change contract

- `[eng-upstream-001] [hard]` A protected upstream write requires the matching exceptional approval,
  exact patch surface, reason, rollback plan, upstream-sync impact, and verification commands.
- `[eng-upstream-002] [hard]` An exception authorizes only its declared paths and does not weaken
  unrelated engineering or design rules.
