# wire.nvim

A small `.http` client for Neovim: send the request at the cursor or the whole file, a
scratchpad, environments, and Lua scripting with tests. The design is in
[docs/design.md](docs/design.md).

## Requirements

- Neovim ≥ 0.12
- `curl` ≥ 7.83

Optional:

- `jq`: JSON bodies are pretty-printed with their key order kept.
- the `json` tree-sitter parser: JSON bodies are highlighted. wire highlights `.http`
  buffers itself and stops tree-sitter's `http` highlighter there.
- a markdown renderer such as
  [render-markdown.nvim](https://github.com/MeanderingProgrammer/render-markdown.nvim): the
  Report tab is a markdown table, drawn with borders by a renderer and readable as aligned
  plain text without one.

## Installation

`setup()` must be called: it adds the autocmds for highlighting, project discovery and
trusting env and helper files you save. Run `:checkhealth wire` afterwards.

### [lazy.nvim](https://github.com/folke/lazy.nvim)

```lua
{
  "lattenwald/wire.nvim",
  ft = "http",
  cmd = "Wire",
  opts = {},
  keys = {
    { "<leader>Rs", "<cmd>Wire send<cr>", desc = "Send request" },
    { "<leader>Ra", "<cmd>Wire all<cr>", desc = "Send all requests" },
    { "<leader>Rb", "<cmd>Wire scratch<cr>", desc = "Scratchpad" },
    { "<leader>Re", "<cmd>Wire env<cr>", desc = "Select environment" },
    { "<leader>Rc", "<cmd>Wire cancel<cr>", desc = "Cancel run" },
    { "<leader>Ro", "<cmd>Wire open<cr>", desc = "Open response window" },
  },
}
```

### [vim.pack](https://neovim.io/doc/user/pack.html#vim.pack)

```lua
vim.pack.add({ "https://github.com/lattenwald/wire.nvim" })
require("wire").setup({})

vim.keymap.set("n", "<leader>Rs", "<cmd>Wire send<cr>", { desc = "Send request" })
vim.keymap.set("n", "<leader>Ra", "<cmd>Wire all<cr>", { desc = "Send all requests" })
vim.keymap.set("n", "<leader>Rb", "<cmd>Wire scratch<cr>", { desc = "Scratchpad" })
vim.keymap.set("n", "<leader>Re", "<cmd>Wire env<cr>", { desc = "Select environment" })
vim.keymap.set("n", "<leader>Rc", "<cmd>Wire cancel<cr>", { desc = "Cancel run" })
vim.keymap.set("n", "<leader>Ro", "<cmd>Wire open<cr>", { desc = "Open response window" })
```

wire defines no global mappings; the keys above are a suggestion.

## Configuration

```lua
require("wire").setup({
  helpers = {},  -- global helper files, loaded before each project's http-client.lua
  timeout = nil, -- overall limit per request in seconds; nil = none (connect timeout is 10 s)
})
```

`:Wire send|all|cancel|open|env|scratch|reset`. Statusline: `require("wire").env()`.
Full documentation: `:help wire`.

## The dialect

```http
< ./helpers.lua
@base = https://api.example.com

### Create item
POST {{base}}/items
Authorization: Bearer {{token}}
Content-Type: application/json

{"name": "{{name}}", "at": "{%= os.date('!%Y-%m-%dT%H:%M:%SZ') %}"}

> {%
vars.id = response.json.id
test("created", function(t)
  t.eq(response.status, 201)
end)
%}
```

- `###` starts a request; the text after it is its name. Lines before the first `###` hold
  document variables (`@x = v`) and helper imports (`< ./file.lua`).
- `{{name}}` resolves section variables, then script variables (`vars.X = v`), document
  variables, the selected environment, and the process environment.
- `{%= expr %}` inserts the value of a one-line Lua expression. Its result is never
  rendered again; wrap text in `render(s)` to resolve `{{…}}` inside it.
- Inside a JSON body (by `Content-Type`, or a body starting with `{` or `[`), values inside
  string literals are JSON-escaped.
- `< ./pre.lua` / `< {% %}` in a request run before it; `> ./post.lua` / `> {% %}` after it,
  with `request`, `response`, `test(name, fn)` and `t.ok / t.eq / t.contains / t.match`.

## Helpers and environments

Helpers are Lua tables of functions: global files from `setup`, `http-client.lua` in the
project directory, then preamble imports. `http-client.env.json` and
`http-client.private.env.json` hold environments; values are templates. Discovered project
files go through Neovim's `:trust`; files you save from Neovim are trusted automatically.

## Migrating from kulala

- `$kulalaDefaultHeaders` → `$defaultHeaders`.
- `@x = file(...)` → `@x = {%= render(file(...)) %}`, with `vars.NAME` for nested names.
- `KULALA_SHARED_EACH` blocks go away; JavaScript `> {% %}` blocks become Lua tests.
- Give every request its own `###` line.

## Development

`make test` runs the mini.test suite headless against a loopback server
(`tests/server.py`, needs `python3`). `make lint` checks formatting and lints.
