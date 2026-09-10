---
name: "codex-model-providers"
description: "Add a third-party model to Codex CLI — \"add <model> to codex\", profile config errors: provider block, separate profile file, env key, one-shot verify."
---

# Codex CLI Model Providers

Wire a third-party model (Z.AI GLM, other OpenAI-compatible endpoints) into Codex CLI and verify it end-to-end.

## When to use

- User asks to add a model or provider to Codex CLI ("add glm 5.3 to codex").
- A `--profile` invocation fails with a "legacy profile" config error.

## Procedure (verified on codex-cli 0.153.4)

1. Inspect existing state first: read `~/.codex/config.toml` (or `$CODEX_HOME/config.toml`) and list `~/.codex/*.config.toml`. A provider block or profile file may already exist; reuse it instead of duplicating.
2. Ensure the provider block exists in `config.toml`, replacing ids and URLs with the target service's values:

   ```toml
   [model_providers.zai]
   name = "Z.AI GLM"
   base_url = "https://api.z.ai/api/v1"   # serves the Responses API
   wire_api = "responses"
   env_key = "GLM_API_KEY"                 # env var holding the API key
   ```

   Done when `config.toml` contains the block.
3. Create the profile as its own file `~/.codex/<profile>.config.toml` (e.g. `glm53.config.toml`):

   ```toml
   model = "glm-5.3"
   model_provider = "zai"
   ```

   Never add a `[profiles.<name>]` table to `config.toml`: 0.153+ treats it as legacy and refuses to load the config until those settings live in the separate file. Done when the file exists with both keys.
4. Ensure the `env_key` variable is exported in the user's shell (e.g. `~/.zshenv`); confirm it is set without printing its value.
5. Smoke-test one-shot — Codex requires a git repo, and agent shells may not inherit `.zshenv`:

   ```sh
   T=$(mktemp -d) && cd "$T" && git init -q && \
   zsh -c 'source ~/.zshenv 2>/dev/null; codex --profile glm53 exec --sandbox read-only "Reply with exactly: OK"'
   ```

   Success: the header shows the target model and the output ends with the literal `OK`.
6. Treat `warning: Model metadata for '<model>' not found. Defaulting to fallback metadata` as expected for third-party models; it does not block the call.
7. Report usage: `codex --profile <profile>` (interactive) or `codex --profile <profile> exec "<task>"`. The default `model =` in `config.toml` is unchanged; profiles are opt-in.
