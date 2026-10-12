# dev/opencode-endpoint

The template for `LOCAL_MODEL=endpoint`: any OpenAI-compatible server running on
the host (Ollama, LM Studio, vLLM, llama-server, …), reached through the `llm`
socat pipe at `http://llm:8080/v1`.

Unlike `dev/opencode/` (or a config dir a backends plugin names), this config cannot be a
static file: opencode needs the **model id** and the **API key** inside its JSON,
and `/etc/opencode` is mounted read-only, so the agent cannot be asked to fill
them in. `bin/sandbox-run` therefore renders `opencode.json.tmpl` at launch into
the project's control dir (`~/.airlock/<project>-<hash6>/opencode-endpoint/`) and
points `OPENCODE_DIR` at that directory — outside the sandbox mount, like every
other decision the agent must not get to make.

Placeholders, all filled from the project's config:

| Token | Config key | Default |
|-------|-----------|---------|
| `__LLM_MODEL__`   | `LLM_MODEL`   | required |
| `__LLM_KEY__`     | `LLM_KEY`     | `none` (most local servers need no key, and an empty string makes the provider SDK unhappy) |
| `__LLM_CONTEXT__` | `LLM_CONTEXT` | 131072 |
| `__LLM_OUTPUT__`  | `LLM_OUTPUT`  | 16384 |

Keep the limits at or below what the server was actually launched with.
