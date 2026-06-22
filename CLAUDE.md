# micewriter-hub — Claude Code guidance

This repo is the architecture/design hub for the mIceWriter ecosystem.
This checkout is rooted on the **v2 / main** release line.

## Environment

This is a WSL2 Linux environment — use bash for shell commands.

## Build & Test

Tools are installed natively: use `cargo` for Rust (engine) components, `mvn` for Java (SDK) components. After code changes, build and verify all tests pass before committing.

## Git Workflow

For multi-repo git operations across the micewriter* repos, use a single batched/scripted approach rather than spawning many parallel git pulls (parallel SSH-agent setup is slow and hangs).

Standard close-out workflow: commit meaningful changes, ensure `.claude/` is gitignored, and push. Skip binary/build artifacts.

## Two release lines are active

The ecosystem maintains two parallel lines across six sibling repos:

- **v1 (per-pod sidecar)** — `v1` branch of every `micewriter-*` repo; sibling worktrees at `../micewriter-*-v1/`. Currently deployed to the k3s cluster.
- **v2 (per-table pipelines)** — `main` branch of every `micewriter-*` repo; canonical paths `../micewriter-*/`. Architecture in `docs/per-table-pipelines.md`.

Neither line is frozen. Before making changes, confirm which line is in scope. Default to this checkout's line; ask the user if the request is ambiguous (e.g. "change the engine flush logic" — v1 or v2?).

## Cross-repo work

Both lines are on disk simultaneously, so v1 ↔ v2 comparison and porting do not require `git checkout`. Read both versions of a file directly via their full paths.

For breadth-first cross-repo research, spawn **Explore subagents** (up to 3 in parallel). Do not use subagents for sustained implementation in a component — open a separate Claude Code session at the component's worktree (`../micewriter-<X>/` for v2, `../micewriter-<X>-v1/` for v1) and iterate there.

## Sibling repos (paths relative to this file)

| Component | v2 (main) | v1 |
|---|---|---|
| Rust sidecar | `../micewriter-engine` | `../micewriter-engine-v1` |
| Java SDK | `../micewriter-sdk-java` | `../micewriter-sdk-java-v1` |
| K8s injector | `../micewriter-k8s-injector` | `../micewriter-k8s-injector-v1` |
| Local data lake | `../micewriter-local-infra` | `../micewriter-local-infra-v1` |
| Reference app | `../micewriter-sandbox` | `../micewriter-sandbox-v1` |

Cluster config (single line): `../k3sonhyperv`.

## Migration / split context

- `docs/v1-to-v2-migration.md` — split rationale.
- `docs/per-table-pipelines.md` — v2 architecture.
- `micewriter-k8s-injector` is v1-only by design; its `main` branch carries a sunset banner.
