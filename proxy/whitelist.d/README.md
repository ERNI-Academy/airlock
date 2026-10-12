# Whitelist blocks

`proxy/squid.conf` holds **no domains**. It holds the policy (default-deny) and one
line that reads `/etc/squid/extra-whitelist.txt`. Everything a sandbox is allowed to
reach comes from that one file, and `bin/airlock` composes it per project out of the
blocks in this directory:

    <control dir>/whitelist.txt  =  blocks for the project's STACK (or its COMPONENTS=)
                                 +  the block for its HARNESS
                                 +  the project's own WHITELIST= entries

So a .NET project running Claude Code no longer gets npm, PyPI, Maven, NuGet,
models.dev and the GitHub download hosts "because some other project needed them".

## Maps (`bin/lib/airlock-kit.sh`: `kit_stack_blocks` / `bin/lib/airlock-whitelist.sh`: `harness_block`)

A stack's blocks are **derived from the components it installs**, as declared in the
repo-root `airlock.json` — one table, the same one that decides what gets built into
the image: `node` → `stack-node`, `python` → `stack-python`, `java` → `stack-java`,
`dotnet` → `stack-dotnet` (`angular` resolves through npm, so `stack-node` covers it).
With the shipped `airlock.json` that comes out as:

| STACK | components | blocks |
|-------|-----------|--------|
| `base` | node, python | `stack-node` `stack-python` |
| `java-angular` | node, python, java, angular | `stack-node` `stack-python` `stack-java` |
| `dotnet` | node, dotnet | `stack-node` `stack-dotnet` |
| `node` | node | `stack-node` |

A stack added to `airlock.json` gets its blocks without touching any code. A project
that sets `COMPONENTS=` in its config gets the blocks of THOSE components instead of
its stack's — the same override the image build follows, so the two cannot disagree.

| HARNESS | block |
|---------|-------|
| `opencode` | `harness-opencode` |
| `claude` | `harness-claude` |
| `codex` | `harness-codex` |
| `copilot` | `harness-copilot` |

## Format

Squid `dstdomain` file format: one domain per line, `#` comments and blank lines
allowed. A leading dot means "this domain and all its subdomains"; no dot means the
exact host. No IPs, ports, paths or wildcards — for HTTPS the proxy only ever sees
the hostname.

Squid refuses to start on a duplicate entry, and warns on an entry that is already
covered by a broader one (`github.com` under `.github.com`). `airlock` de-duplicates
and drops covered entries while composing, so blocks may overlap freely.

## Adding a domain

When a real run is blocked (`airlock denied`), put the domain in the project's own
`WHITELIST=` (`airlock config --edit`) — or, if every project on that stack or harness
needs it, in the matching block here.

## `proxy/extra-whitelist.txt`

The list raw `bin/harness` callers (no project config) get: a copy of `stack-node.txt` +
`stack-python.txt`, i.e. what `STACK=base` needs. `airlock` never reads it.
