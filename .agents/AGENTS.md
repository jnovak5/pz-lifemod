# Agent Behavioral Rules for AuroraLife

- **Sync Script Execution**: NEVER run the `sync-to-release.ps1` script autonomously or proactively. ONLY run the sync script when the user explicitly commands it.
- **Git Operations**: NEVER automatically commit or push changes to git. ONLY run `git commit` and `git push` when the user explicitly commands it.
- **Active Development**: Do NOT update files in the `AuroraLife` directory during active development. ALL edits and new features must be applied exclusively to the `AuroraLifeLocal` directory. `AuroraLife` is the release build and must only be updated manually or via the sync script when the user is ready.
