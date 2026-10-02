# wire.nvim

A small `.http` client for Neovim. The design is in [docs/design.md](docs/design.md).

- Send the request at the cursor or the whole file, from a project or a scratchpad.
- The JetBrains `.http` dialect and `http-client.env.json` environments.
- Lua throughout: `{%= expr %}` in templates, helper files, and pre/post scripts with tests.
- A response window with the body (JSON pretty-printed), headers, the request as sent,
  script output and a per-run report; failures go to the quickfix list.
- A timing breakdown of each request: DNS, connect, TLS, server wait, download and
  `Server-Timing`.
- Secrets masked everywhere wire shows them; project files gated by `:trust`.
- Copy a request as a `curl` command, from the `.http` buffer or the response window.
- An optional built-in language server: sections in `gO` and pickers, go to a variable's
  definition, hover for its value, code actions to send or yank.

## Requirements

- Neovim ≥ 0.12
- `curl` ≥ 7.83

Optional:

- `jq` ≥ 1.7: JSON bodies are pretty-printed with their key order kept. Older jq rounds
  large integers, so wire shows the body as received.
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
  -- optional: the language server
  init = function()
    vim.lsp.enable("wire")
  end,
  keys = {
    { "<leader>Rs", "<cmd>Wire send<cr>", desc = "Send request" },
    { "<leader>Ra", "<cmd>Wire all<cr>", desc = "Send all requests" },
    { "<leader>Rb", "<cmd>Wire scratch<cr>", desc = "Scratchpad" },
    { "<leader>Re", "<cmd>Wire env<cr>", desc = "Select environment" },
    { "<leader>Rc", "<cmd>Wire cancel<cr>", desc = "Cancel run" },
    { "<leader>Ro", "<cmd>Wire open<cr>", desc = "Open response window" },
    { "<leader>Ry", "<cmd>Wire yank<cr>", desc = "Yank request as curl" },
  },
}
```

### [vim.pack](https://neovim.io/doc/user/pack.html#vim.pack)

```lua
vim.pack.add({ "https://github.com/lattenwald/wire.nvim" })
require("wire").setup({})
vim.lsp.enable("wire") -- optional: the language server

vim.keymap.set("n", "<leader>Rs", "<cmd>Wire send<cr>", { desc = "Send request" })
vim.keymap.set("n", "<leader>Ra", "<cmd>Wire all<cr>", { desc = "Send all requests" })
vim.keymap.set("n", "<leader>Rb", "<cmd>Wire scratch<cr>", { desc = "Scratchpad" })
vim.keymap.set("n", "<leader>Re", "<cmd>Wire env<cr>", { desc = "Select environment" })
vim.keymap.set("n", "<leader>Rc", "<cmd>Wire cancel<cr>", { desc = "Cancel run" })
vim.keymap.set("n", "<leader>Ro", "<cmd>Wire open<cr>", { desc = "Open response window" })
vim.keymap.set("n", "<leader>Ry", "<cmd>Wire yank<cr>", { desc = "Yank request as curl" })
```

wire defines no global mappings; the keys above are a suggestion.

### Versions

Releases are tagged `vX.Y.Z` following [semver](https://semver.org), with changes listed
in [CHANGELOG.md](CHANGELOG.md); the `stable` tag marks the latest release. Before 1.0 a
breaking change bumps the minor version. `main` gets every change first; to stay on
releases, add `version = "*"` to the lazy.nvim spec, or pass
`{ src = "https://github.com/lattenwald/wire.nvim", version = vim.version.range("*") }`
to `vim.pack.add`.

## Configuration

Defaults, with examples commented out:

```lua
require("wire").setup({
  -- global helper files, loaded before each project's http-client.lua
  helpers = {},
  -- helpers = { "~/.config/wire/helpers.lua" },

  -- overall limit per request in seconds; nil = none (connect timeout is always 10 s)
  timeout = nil,
  -- timeout = 30,

  -- absolute dirs whose project files skip :trust; { "/" } trusts every file
  trusted_dirs = {},
  -- trusted_dirs = { "~/projects" },

  -- secrets show as •••• (private env values, secret(), and these request headers);
  -- name only the headers you change; false masks nothing
  mask = {
    headers = {
      authorization = true,
      ["proxy-authorization"] = true,
      cookie = true,
      ["x-api-key"] = true,
      ["api-key"] = true,
    },
  },
  -- mask = { headers = { Cookie = false } },          -- show cookies
  -- mask = { headers = { ["X-Auth-Token"] = true } }, -- also mask a custom header
  -- mask = false,                                     -- show everything
})
```

Secrets are masked in everything wire displays; response bodies and headers are shown as
received.

`:Wire send|all|cancel|open|env|scratch|reset|yank`. Full documentation: `:help wire`.

### Statusline

`require("wire").env()` returns the environment of the current `.http` buffer, or of the
result shown in the response window; `nil` when there is none. It does no I/O.

```lua
-- 'statusline'
vim.o.statusline = [[%f %=%{luaeval("require'wire'.env() or ''")} ]]

-- lualine
require("lualine").setup({
  sections = {
    lualine_x = { function() return require("wire").env() or "" end },
  },
})
```

### Language server

wire ships an in-process language server for `.http` files, off until
`vim.lsp.enable("wire")` (see [Installation](#installation)). It lists sections and
variables as symbols, jumps from `{{name}}` to its definition (section, file or env file),
shows where a value comes from on hover, and offers send and yank as code actions. See
`:help wire-lsp`.

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
files go through Neovim's `:trust`; files you save from Neovim are trusted automatically,
and files under `trusted_dirs` are not gated (their `http-client.lua` runs on send).

## Migrating from kulala

- `$kulalaDefaultHeaders` → `$defaultHeaders`.
- `@x = file(...)` → `@x = {%= render(file(...)) %}`, with `vars.NAME` for nested names.
- `KULALA_SHARED_EACH` blocks go away; JavaScript `> {% %}` blocks become Lua tests.
- Give every request its own `###` line.

## Development

`make test` runs the mini.test suite headless against a loopback server
(`tests/server.py`, needs `python3`). `make lint` checks formatting and lints.

## Inspired by

- [kulala.nvim](https://github.com/dont-be-evil-company/kulala.nvim): the response window
  and inline result icons.
- [JetBrains HTTP Client](https://www.jetbrains.com/help/idea/http-client-in-product-code-editor.html):
  the `.http` dialect, `http-client.env.json` environments, and `> {% %}` test scripts.
- [VS Code REST Client](https://github.com/Huachao/vscode-restclient): `@name = value` file
  variables.

## License

[MIT](LICENSE)
