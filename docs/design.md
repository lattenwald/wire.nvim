# wire.nvim — design

## 1. Why

kulala.nvim's request engine, kulala-core, went closed in September 2026: releases now
download from `core.kulala.app` behind a license token with no published terms, and the
source stops at 0.37 (last public commit `772a506`, 2026-08-18).

wire.nvim is a small, self-owned `.http` client covering the common workflow: send the
request at the cursor, send all, a scratchpad, environment selection, and Lua scripting
with tests. It is easy to read, easy to extend with plain Lua, and
without kulala-core's quirks (WASM sandbox, variable double-escaping, pre-flight rows,
magic shared-block names).

## 2. Goals and non-goals

Goals:

- One extension mechanism: Lua. No built-in resolvers; `file` and friends are user
  helpers.
- Response window modelled on kulala's (summary, tabs, history, inline icons).
- Resolved secrets never reach the process list, and are masked in all text wire generates.
  Response data (body, response headers) is shown as received.

Non-goals (not planned; add only when there is a need):

- JavaScript scripts, `{{$uuid}}`-style dynamic variables, `{{req.response…}}` chaining
  syntax, GraphQL, gRPC, WebSocket, multipart and form-urlencoded bodies, external body
  files (`< ./body.json` as a body), cookie jar, following redirects, persisted history,
  concurrent sends, request import/export, OpenAPI.

## 3. Dependencies

- Neovim ≥ 0.12 (developed on 0.12.5).
- The `json` tree-sitter parser (installed by nvim-treesitter) — optional, for highlighting
  JSON bodies (§9.4); the `lua` parser ships with Neovim. The stock `http` parser
  ([rest-nvim/tree-sitter-http](https://github.com/rest-nvim/tree-sitter-http)) is not used:
  it silently misparses shapes (a lone `#` line swallows the next
  line, a comment after a blank line turns later `###` sections into a body, a long header
  comment splits the preamble, `@blank =` is an error), and only the last yields an error
  node. kulala's `kulala_http` grammar also misparses `@blank =` and drops the next `###`.
  wire reads and highlights the buffer with its own line parser (§4.1, §9.4).
- `curl` ≥ 7.83 (for `-w '%{header_json}'`; developed against 8.18).
- `jq` ≥ 1.7 — optional, for order-preserving JSON pretty-printing. jq 1.6 turns large
  integers into doubles (`1234567890123456789` → `1234567890123456800`), so with an older jq
  the body is shown as received.

Neovim's `vim.net.request()` is not used: it is GET-only, returns only the body, hard-codes
`--fail` (drops 4xx/5xx bodies) and `--retry 3` (resends POSTs). It wraps `curl` too.

## 4. The `.http` dialect

### 4.1 Structure

wire reads the buffer's lines (`nvim_buf_get_lines`) with its own line parser, so the
snapshot (§7.1) always matches the text, even right after an edit.

- A line starting with `###` starts a **section**, which runs to the next such line. The
  text after the leading `#` characters, trimmed, is the request name; a section without a
  name is called `METHOD url`.
- The **preamble** is everything before the first `###` line: blank lines, comments,
  document variables and helper imports (§5) only. A request line in the preamble refuses
  the run with "put `###` before the request".
- Outside a body, a **comment** is any other line whose first non-blank characters are `#`
  or `//`, including an empty `#`. Comments never affect the next line. Directive comments (`# @name value`) are
  ignored.
- `@name = value` declares a variable. In the preamble it is a **document variable**; inside
  a section it is a **section variable** (§4.2). The value is the rest of the line, trimmed;
  `@blank =` gives the empty string.
- A section is read in this order:
  1. **Head**: blank lines, comments, section variables and pre-request scripts (`<`, §4.6).
  2. **Request line**: `METHOD url [HTTP/x]`, where `METHOD` is upper-case letters. The
     `HTTP/x` token is accepted and ignored; curl negotiates the protocol. Following
     indented, non-blank lines continue the URL and are joined with their leading
     whitespace removed.
  3. **Headers**: `Name: value` lines up to the first blank line; comments among them are
     skipped.
  4. **Body**: the lines after that blank line, verbatim, up to the first line starting
     with `> ` or `>{%`, or the end of the section. Trailing blank and comment lines are dropped, and
     the body ends without a final newline. A body whose first line starts with `< ` (an
     external body file) refuses the run as "not supported".
  5. **Post-response scripts** (`>`, §4.6), with blank lines and comments between them.
- Any other line refuses the run with its line number: a non-header line among the headers,
  a head line that is not a request line, a `>` script before the request line, or a line
  after the post scripts. A body line that looks like a request line (`METHOD http…` or
  `METHOD {{…`) also refuses the run with "put `###` before the request", so two requests in
  one section are never merged.
- A section without a request line (for example an old `KULALA_SHARED_EACH` block) is
  skipped by "send all" and cannot be sent on its own.
- The section at the cursor is the one containing the cursor row.
- Bodies are sent as text (escaping: §4.4). GraphQL and multipart bodies are not detected;
  they are sent as text like any other body.

### 4.2 Variables: `{{name}}`

`{{name}}` may appear in variable values, the URL, header values, the body, and environment
file values. A placeholder is `{{`, optional spaces, a name of `[A-Za-z0-9_.$-]+`, optional
spaces, `}}`; a dot is part of the name, not a path. Any other `{{` is literal text.

Resolution order, first hit wins:

1. Section variables: a section's own `@x` always wins.
2. Script variables: values set by scripts with `vars.X = v`. They are kept per `.http`
   buffer for the Neovim session, so a login request's token feeds requests sent later on
   their own. `:Wire reset` clears them for the buffer. Switching environment clears them
   for every buffer of that project directory.
3. Document variables.
4. The selected environment (§6).
5. Process environment (`vim.env`).

Only text written in the `.http` file and the env files is a template: section, document
and environment values are rendered on first use, recursively. Script variables and process
environment values are literal and never rendered, so response data stored with
`vars.X = v` cannot run `{%= %}` or pull in other variables; `render()` (§4.5) is the
explicit way to template such a string.

Every placeholder resolves in the scope of the section being sent, including those inside
document and environment values: a document variable containing `{{zone}}` gets each
section's own `@zone`. Each variable is rendered at most once per section (memoized); the
memo is cleared at the start of each section and whenever a script sets a variable. A cycle
(`a → b → a`) aborts and reports the chain.

`vars.X = v` stores a string as is, a number or boolean via `tostring`, unsets the
variable on `nil`, and errors on any other type (including `vim.NIL`).

An unresolved `{{name}}` aborts. If no environment is selected, the error adds a hint to
select one.

### 4.3 Lua in templates: `{%= expr %}`

`{%= expr %}` evaluates a Lua **expression** and substitutes its value. It is valid wherever
`{{name}}` is. The stock grammar treats it as plain text everywhere unless the expression
contains `{{` (verified); `{{= … }}` was rejected because that grammar turns any `{{` not
followed by an identifier into an `ERROR` node.

- The expression is compiled as `return <expr>`; statements are not allowed. Anything longer
  belongs in a helper.
- An expression is on one line. The first `%}` ends it, so `%}` cannot appear inside it,
  even in a string.
- Result conversion: string → as is; number or boolean → `tostring`; `nil` or any other type
  aborts ("expression returned nil"). Return `""` for an empty value; call `vim.json.encode`
  explicitly to embed a table.
- A result is inserted as is and **never rendered again**: `{{…}}` inside it stays literal
  (so `{%= "{{x}}" %}` writes a literal `{{x}}`). To resolve placeholders in text a helper
  produced, such as a template file containing `{{userName}}`, pass it through
  `render(s)` (§4.5).
- Evaluation is **lazy**: an expression in a variable's value runs only when the request
  being sent uses that variable, directly or through other variables.
- An expression inline in a URL, header or body runs once per occurrence per send.
- Evaluation order between expressions is not specified; expressions should not depend on
  each other's side effects.
- Errors abort, reported with file, line and the Lua traceback into the helper.

### 4.4 Substitution and escaping

- The body is rendered in **JSON mode** when the request's `Content-Type` is
  `application/json` or `*/*+json`, or, without a `Content-Type`, when the body's first
  non-blank character is `{` or `[`. The `Content-Type` is the merged value after header
  layering (§7.3, so `$defaultHeaders` counts); the media type before `;` is compared
  case-insensitively, and an empty value counts as absent. Headers are therefore rendered
  and merged before the body.
- In JSON mode, a value that lands inside a JSON string literal is escaped with
  `vim.json.encode(value):sub(2, -2)`; outside a string literal it is inserted raw, so
  `"port": {{port}}` works. The renderer tracks string state over the literal template
  text only; placeholders are atomic, so quotes inside `{%= … %}` do not count. Inside a
  string, a backslash escapes the next character (so both `\"` and `"C:\\"` are handled).
- Everywhere else (URL, headers, non-JSON bodies) values are inserted raw. There is no
  automatic URL encoding; use `vim.uri_encode` in an expression when needed.
- Scripts and helpers always produce **raw** values; there is no double-escaping to avoid.

### 4.5 The Lua environment

Expressions, scripts and helper files all run in one environment. Name lookup, first hit
wins:

1. The context API below.
2. Helpers (§5), later layers overriding earlier ones.
3. Lua globals (`_G`: `vim`, `os`, `string`, …).

Variables are never bare names: `vars.NAME` (or `vars["kebab-name"]`). A variable called
`file` or `string` therefore never shadows a helper or a Lua global. A name found in none of
the three layers raises "unknown name 'X' (variables are vars.X)", so a `{{X}}` or bare `X`
written inside Lua fails at once instead of reading as `nil`. The environment is shared by
every send, so assigning a global is an error ("cannot assign global 'X': use local X, or
vars.X to keep a value"); otherwise a stray `token = …` would shadow helpers and the unknown
name error for the rest of the session.

Helper names resolve at call time against the merged helper table of the send in progress,
so a cached global helper file sees each project's own helpers.

wire binds the current send's context around every call into user code (expression, script,
helper), so the context names always refer to the send in progress. Code at the top level of
a helper file runs at load time, outside any send; a context name used there raises the same
error as `ctx()`. Code in a plain Lua module (loaded with `require`) reaches the same API
through `require("wire").ctx()`, which errors outside a send.

| Name | Where | Meaning |
|---|---|---|
| `vars` | everywhere | `vars.X` resolves through §4.2 and returns a string, or `nil` when no level defines X (so `vars.X or "default"` works); a rendering failure raises. In scripts, `vars.X = v` sets a script variable (level 2 of §4.2). |
| `dir` | everywhere | The base directory (§5.1). |
| `secret(s)` | everywhere | Registers `s` for masking (§8) and returns `s` unchanged. |
| `render(s)` | everywhere | Renders the string `s` as a template (§4.2–4.3) in the current request's scope and returns the result. |
| `log(...)` | everywhere | Appends to the Script Output tab. |
| `request` | post scripts | The request as sent: `name`, `method`, `url`, `headers` (including `$defaultHeaders`), `body`. |
| `response` | post scripts | `status` (number), `headers`, `body` (raw string), `json` (the decoded body, or `nil` if it is not valid JSON). |
| `test(name, fn)` | post scripts | Runs `fn(t)` as a named test (§4.7). |

`request.headers` and `response.headers` are both tables keyed by lower-cased name; for a
repeated header the last value wins.

### 4.6 Scripts

- An inline script starts with `{%` on the `<` or `>` line and ends at the first line that
  ends with `%}`; the code is the text between them. One-line (`> {% log(response.status) %}`)
  and multi-line blocks are both valid.
- `< ./file.lua` or `< {% … %}` inside a section is a **pre-request script**. Pre scripts
  run in source order before any template of the request is rendered. They see `vars`, not
  `request`: they shape the request only through variables.
- `> ./file.lua` or `> {% … %}` is a **post-response script**. Post scripts run after a
  response arrives, in source order, and may set script variables for later requests.
- `<` in the **preamble** means something else: it imports helpers (§5).
- Paths are relative to the base directory (§5.1). A script file must end in `.lua`.
- Scripts are the user's own code: they run with the full `vim` API.
- Every script of every section in the run is loaded and compiled before the first request
  is sent. A non-`.lua` script file or an inline block that does not compile aborts the run
  before anything goes out.
- An error in a pre script aborts. An error in a post script is recorded as a failed test
  named after the script (an inline block is named `post script (line N)`), with its
  traceback; the response is still shown.

### 4.7 Tests

```lua
test("item is created", function(t)
  local item = response.json
  t.eq(response.status, 201)
  t.ok(not item.name:find("DRAFT", 1, true), "draft returned")
  t.contains(item.name, "widget")
end)
```

- `t.ok(cond, msg)` — passes if `cond` is truthy.
- `t.eq(got, want, msg)` — passes if `vim.deep_equal(got, want)`; the failure shows both
  values with `vim.inspect`.
- `t.contains(s, sub, msg)` — plain substring check (no Lua patterns).
- `t.match(s, pattern, msg)` — Lua pattern check.
- Assertions are soft: a failure is recorded and the test continues, so one run reports
  every failure. A test with at least one failure is failed.
- An `error()` (or Lua `assert`) inside `fn` ends that test as failed, with the traceback.
- The `t` object is passed in, so nothing shadows Lua's own `assert`.

## 5. Helpers and project files

### 5.1 Base and project directories

- The **base directory** of a `.http` buffer is its file's directory. For the scratchpad
  (§9.3) it is the cwd captured each time `:Wire scratch` runs, stored on the buffer. The
  base directory is `dir` in Lua, anchors relative `<` / `>` paths, and starts discovery.
- The **project directory** is the nearest directory, walking up from the base directory,
  that contains any of `http-client.lua`, `http-client.env.json` or
  `http-client.private.env.json`: `vim.fs.root(base, { { …three names… } })`, where the
  nested list gives the names equal priority (a flat list would prefer a farther
  `http-client.lua` over a nearer env file). When the base directory is under `$HOME`, a
  match outside `$HOME` is ignored. All three files are read from the project directory
  only; any of them may be missing.
- Both directories are computed on `FileType http` (and when `:Wire scratch` runs) and
  cached on the buffer, so the statusline (§6) is right before the first send.

### 5.2 Layers

A helper is any value in a helpers table; functions are the common case. Layers, later
overriding earlier by name:

1. **Global**: helper files listed in `setup({ helpers = { "~/…/helpers.lua" } })`.
2. **Project**: `http-client.lua` in the project directory.
3. **Per file**: each `< ./path.lua` or `< {% … %}` in the preamble, in source order.

All three are loaded the same way: a Lua chunk that returns a table, run in the environment
of §4.5.

```lua
local M = {}

function M.file(path)
  return vim.trim(table.concat(vim.fn.readfile(dir .. "/" .. path), "\n"))
end

return M
```

Helpers call each other as plain names, can keep module-level state (caches), and can
`require` modules on the runtimepath.

### 5.3 Trust and caching

- Files wire **discovers** — `http-client.lua` and the two env files — are read through
  `vim.secure.read`, using Neovim's exrc trust database, which is keyed by content. A
  cloned repository therefore cannot run code through files the user did not name.
  - For files, Neovim 0.12 offers only ignore / view / deny; there is no "allow" in the
    prompt. "View" opens the file, where `:trust` allows it. An untrusted file therefore
    aborts the run. The snapshot reads all discovered files before aborting, so one send
    raises every prompt, and the abort names each untrusted file with the fix: `:trust` it
    in the opened window (or `:trust ++remove <file>` if it was denied), then send again.
  - **Auto-trust on save**: `setup()` adds a `BufWritePost` autocmd for `http-client.lua`
    and `http-client*.env.json` that calls `vim.secure.trust({ action = "allow", path })`.
    A file the user saves from Neovim is trusted; a file changed by `git pull` or a clone is
    still gated. Trust is by path, which hashes the file as written: a `bufnr` hash differs
    from the file's when the buffer was read from a file without a final newline, and the
    saved file would still be untrusted.
  - wire compiles the string `vim.secure.read` returned, never a second read of the file.
- Files the `.http` file names itself (`<` / `>` paths) are trusted like the `.http` file,
  which is opened and sent on purpose. The exception is the scratchpad, whose base
  directory is whatever the cwd was: its relative `<` / `>` files go through
  `vim.secure.read` too. Global helper files come from the user's config and are not gated.
- A loaded helper file is cached by its content: while the content is unchanged, the same
  table (and its module-level state) is reused; changed content is loaded again on the next
  run. No restart is needed.

## 6. Environments

- The env files live in the project directory (§5.1). Both are JSON objects. The
  environments are the top-level keys whose values are objects and whose names do not start
  with `$`; `$shared` is merged as below, and anything else (`$schema`, a non-object value
  such as `"prod": []`) is ignored.
- `$` keys other than `$schema` and `$shared` at the top level, and other than
  `$defaultHeaders` inside an environment or `$shared`, are ignored with a warning: each send
  notifies them at WARN level with file and environment (for example a leftover
  `$kulalaDefaultHeaders`), pointing to `:help wire-environments`, and still sends. No
  near-match is guessed.
- One merge rule, deep-merging objects with the later side winning: the private file over
  the public file, then the environment over `$shared`. `$defaultHeaders` therefore merges
  per header.
- Values are templates (§4.2–4.3). Numbers and booleans are used via
  `tostring`; `null`, arrays and objects (other than `$defaultHeaders`) are not variables.
- `$defaultHeaders` (object) adds headers to every request (§7.3). Values are templates.
- `:Wire env` lists environments through `vim.ui.select`, with the current one marked.
  Selections are kept in memory per project directory
  and written to `stdpath("state")/wire/env.json` when they change.
- With no stored selection: a project with exactly one environment uses it; otherwise no
  environment is selected.
- Switching environment clears the script variables of every buffer in the project (§4.2).
- `require("wire").env()` returns the current buffer's environment name for a statusline: the
  environment a send would use, as resolved by the last send, `:Wire env` or env-file save in
  that project, falling back to the stored selection before any of these. It reads that
  cache and the buffer's cached project directory; it does no I/O, since reading an env file
  can raise a trust prompt.
- Saving an env file from Neovim re-reads the project's environments, but only for a project
  already loaded this session: the other env file was trusted then, so the read cannot
  prompt unless that file changed outside Neovim. Env files changed outside Neovim take
  effect at the next send or `:Wire env`.

## 7. Sending

A **run** is a list of sections sent one after another. `:Wire send` is a run of the section
at the cursor; `:Wire all` is a run of every section that has a request, top to bottom.

### 7.1 A run

1. Snapshot: parse the buffer, load the env files and helpers, compile every script of the
   run's sections. The environment is fixed here for the whole run. Refuse the run if the
   preamble or any of the run's sections has a parse error (§4.1), or if an env file,
   helper or script fails to load or is untrusted. Nothing is sent. A refusal creates no
   result; it is reported with `vim.notify` at ERROR level, with file and line.
2. For each section:
   1. Run pre-request scripts.
   2. Render the URL and headers, merge the header layers (§7.3), then render the body
      (§4.2–4.4).
   3. Send it (§7.4).
   4. Run post-response scripts and tests.
   5. Record the result in history; update the window and the section's icon.
3. Script variables (§4.2) set by any script are visible to later sections of the run and to
   later sends from the same buffer.
4. The run stops at the first **abort** (a failure in steps 2.1–2.2) or **transport
   failure**. Failed tests and 4xx/5xx statuses are results and do not stop it.
5. A result **fails** when its outcome is not `ok` or any of its tests failed; the HTTP
   status is shown but never decides pass or fail. When the run ends, `vim.notify` shows a
   summary such as `wire: 14 sent · 12 ✓ · 2 ✗ · 1 aborted · 3 not run`, and the quickfix
   list titled `wire` is replaced (found by its id, so the user's other lists are kept)
   with one entry per failure, pointing at its `###` line. After a green run that list is
   empty.

An abort sends nothing for that section; its error appears in the summary lines (§9.1), in
the Script Output tab (with traceback) and on its icon.

Only one run is active at a time. Starting one, `:Wire env` or `:Wire reset` while busy
notifies and does nothing; `:Wire cancel` (`<C-c>` in the response window) cancels the
active run.

### 7.2 Result

A result is plain data, kept in history:

```
{ run, section_name,
  mark,                 -- extmark on the section's ### line; jumps follow later edits
  outcome = "ok" | "aborted" | "transport_error" | "cancelled",
  request,              -- rendered request, unmasked; only Y (§9.1) reads it
  response,             -- { status, headers, body, timings } when outcome == "ok"
  -- masked text (§8), built when the result is recorded:
  error,                -- message when outcome ~= "ok"
  tests,                -- { name, ok, messages }
  logs, verbose, summary }
```

Contexts, closures and decoded JSON are not kept once the section finishes.

### 7.3 Headers

Header layers, later winning, names compared case-insensitively: curl's own headers, then
`$defaultHeaders`, then the request's headers. `run` merges the layers before the body is
rendered (§7.1); `transport` only serializes the result. A header whose final value is
empty is removed: wire passes it to curl as `Name:`, which also removes curl's own header of
that name. A request with a body and no `Content-Type` removes curl's implicit
`application/x-www-form-urlencoded`. The `{{blank}}` idiom (`@blank =`) for suppressing a
default header keeps working.

### 7.4 Transport

`curl` runs through `vim.system`, asynchronously.

- argv starts with `-q`, so `~/.curlrc` cannot add `--fail`, `--location` or `--retry`.
- **Nothing resolved goes into argv.** The method, URL and headers go into a curl config read
  from stdin (`-K -`). The config always contains `globoff`: otherwise curl expands `[1-2]`
  and `{a,b}` in the URL, sending a POST twice or failing on `filter[x]=y`. The method is
  written as `request = METHOD`, except `HEAD`, which is written as `head` (`-I`): with
  `-X HEAD` curl waits for a body that never comes. The transport writes that config,
  quoting every value with curl's config escapes, and aborts if a header name, header value
  or URL contains CR or LF.
- A non-empty body goes into a `vim.fn.tempname()` file (Neovim's private temp directory)
  and is sent with `--data-binary @file`; an empty body sends no data option at all. A
  `HEAD` with a body aborts. Resolved secrets therefore never appear in `ps` or
  `/proc/<pid>/cmdline`.
- The response body is written with `-o` to a temp file. `-w '%{json}\n%{header_json}'`
  prints status and timings on one line, then the lower-cased response headers (values are
  arrays) of the final response; verified to exclude a `100 Continue`'s headers. The
  body is read into memory (binary-safe) and all temp files are deleted when the section
  finishes, whatever the outcome. For `HEAD` the body is empty and the `-o` file, which
  then holds the header block, is ignored.
- No `--fail` (4xx/5xx bodies are kept), no `--retry`, no `--location` (redirects are shown,
  not followed), no `--compressed`.
- `--connect-timeout 10`. There is no overall timeout by default (some APIs are slow);
  `setup({ timeout = seconds })` adds `--max-time`.
- Cancel kills the process; the result is "cancelled".
- A non-zero curl exit is a transport failure; curl's error text is the result's `error`.

## 8. Secret masking

- One registry of secret values for the Neovim session, never cleared (`:Wire reset`
  included), filled from three sources:
  - `secret(s)` (§4.5);
  - the rendered value of every variable defined in `http-client.private.env.json` (the
    file that exists to hold secrets), registered when it is rendered, so lazy evaluation
    is kept;
  - the rendered values of the request headers `Authorization`, `Proxy-Authorization`,
    `Cookie`, `X-Api-Key` and `Api-Key`, after `$defaultHeaders` are merged. For the two
    `Authorization` headers, the credential after the scheme word (`Bearer`, `Basic`) is
    registered as well, so a bare token is masked too.
- Values shorter than 4 characters are never registered, from any source: masking them would
  blank out unrelated text.
- For each registered value, its JSON-escaped form (`vim.json.encode(v):sub(2, -2)`) is
  registered too when it differs, since that is how the value appears in a JSON body.
- Masking replaces every occurrence of a registered value with `••••`, as plain text and
  longest value first, including inside longer strings (`Bearer <token>`). It applies to all
  text wire generates: the summary lines, the Verbose, Script Output and Report tabs (test
  failure messages included), error messages, quickfix entries and notifications. Each
  result's texts are masked once, when the result is recorded (§7.2); a value registered
  later does not re-mask earlier results.
- Response data (Body and Headers tabs) is shown as received.
- Masking affects display only. The one way to get unmasked text out of wire is `Y` (§9.1).

## 9. User interface

### 9.1 Response window

A reused buffer `wire://response` in a right-hand vertical split. It opens on the first
send and reuses the window while it is visible. Focus stays in the `.http` buffer.
`:Wire open` shows it again on the latest result without sending.

The winbar holds clickable tabs, kulala-style:

```
 Body (B)  Headers (H)  All (A)  Verbose (V)  Script Output (O)  Report (R)   [ ]
```

Above the first line of every tab, virtual lines (`virt_lines_above`) show a summary, green
on success and red on failure. Neovim shows virtual lines above line 1 only through the
window's `topfill`, so every render ends with `winrestview({ topline = 1, topfill = 3 })`.

`Result:` is the result's place in history, drawn at render time so `[`/`]` update it;
`Request:` is its place in its run and appears only when the run sent more than one
request. When the outcome is not `ok`, `Error: <message>` replaces Code and Duration, so the reason
(for example an unresolved variable with the hint to select an environment) is visible on
every tab. `Env:` reads `none` without a selection and `no project` without a project
directory. Scrolling can hide the summary (`topfill` resets); switching tab re-renders it.

The buffer text is the tab's content only, so the body tab has a real filetype (`json`,
`xml`, …), tree-sitter highlighting and folding. It is a view (pretty-printed, capped), not
the received bytes.

| Tab | Key | Content |
|---|---|---|
| Body | `B` | The body, typed by the content-type table below. JSON is pretty-printed with `jq .` (key order kept); without `jq` ≥ 1.7 the raw body is shown. |
| Headers | `H` | Response headers. |
| All | `A` | Response headers, a blank line, then the body as in Body. |
| Verbose | `V` | The request as sent (method, URL, headers, body), then the response status and headers. Masked. |
| Script Output | `O` | `log()` output and script errors with tracebacks. Masked. |
| Report | `R` | The run of the result being viewed, as markdown (filetype `markdown`, columns padded so it also reads unrendered): a `passed/total` line, a table with one row per section (line, name, status, duration, tests passed/total) and a `↳ ✔/✘` row per test, then one heading per failed section with each failed test's messages or the abort error in a fenced block. |

One content-type table maps `Content-Type` to `json`, `xml`, `html`, `javascript`, `text`
or `binary`; the Body tab and the binary rule both use it. A binary body shows
`binary, <size>`. At most 1 MiB of a body is displayed, followed by a line giving the full
size.

`jq` runs asynchronously, once per result, and only when that result's Body or All tab is
shown; its output is kept on the history entry.

Tab on a new result: when the window opens, Body; when it is already visible, the current
tab is kept, so iterating in Verbose stays in Verbose. Either way, a result with a failed
test or script error switches to Report, and an abort switches to Script Output.

Keys in the response window:

| Key | Action |
|---|---|
| `B` `H` `A` `V` `O` `R` | Switch tab |
| `[` / `]` | Previous / next result in history |
| `<CR>` | On a Report row: jump to that section's `###` line |
| `<C-c>` | Cancel the active run |
| `Y` | Yank into `v:register` a runnable, unmasked `curl -K -` command: the transport's own config text with the body inlined as `data-raw` (text bodies only; `data-binary` would read a local file for a body starting with `@`) |
| `q` | Close the window |
| `g?` | List these keys in a float (`q`, `<Esc>` or `g?` closes it); the list and the maps come from one table |

The maps are buffer-local with `nowait`, so `[` and `]` do not wait for Neovim's default
`[q`-style mappings.

History keeps the last 50 results in memory; it is not persisted.

### 9.2 Inline icons

A section's `###` line gets end-of-line virtual text: `⏳` while running, `✔ 200 · 1.84 s` on
success (the result did not fail, §7.1), `✘ 500 · 2 failed`, `✘ aborted`, `✘ cancelled` or
`✘ <curl error>` on failure. An icon stays until its section is sent again; extmarks move
with edits.

### 9.3 Scratchpad

`:Wire scratch` opens `stdpath("data")/wire/scratchpad.http`, a real file that is saved
normally and persists. Its base directory (§5.1) is the cwd at the moment `:Wire scratch`
last ran; the summary's `Env:` field shows which project that gave.

### 9.4 Highlighting

wire highlights `http` buffers from its own line parser (§4.1), so the colours show what a
send will do. The stock grammar's misparses (§3) make valid files render as comments and
URLs.

- Each line is coloured by its role: `###` lines, comments, `@name = value`, the request
  line (method, URL, `HTTP/x`) and URL continuations, headers (name, `:`, value), script
  markers (`<`, `>`, `{%`, `%}`) and script file paths. `{{name}}` and `{%= … %}` are
  highlighted wherever they are substituted; a `{{…}}` inside an expression is not, since
  expressions are not re-rendered (§4.3). A line the parser rejects is underlined as an
  error; the rest of its section stays uncoloured, as the parser stops there.
- Embedded code uses tree-sitter on just its text: the body as JSON when §4.4's JSON mode
  applies, and inline scripts as Lua. Missing parsers mean no colours there. There is no Lua
  highlighting inside `{%= … %}`.
- JSON mode is decided with `template.is_json`, as for a send: the section's own
  `Content-Type` layered over the selected environment's `$defaultHeaders`. The highlighter
  never reads env files (an untrusted one would raise a trust prompt while typing); it uses
  the defaults remembered by the last send, `:Wire env` or env-file save (§6) for that
  project, and recolours the project's buffers when they change (`User WireEnvChanged`).
  Before any of these it
  uses the section's own headers only. A `Content-Type` containing `{{` or `{%=` is not
  evaluated; the body's first character decides.
- Every group is `Wire*`, linked by default to the standard tree-sitter captures
  (`@comment`, `@function.method`, `@string.special.url`, …), so colour schemes apply.
- Highlights come from a decoration provider in namespace `wire.highlight`: during a
  redraw it sets ephemeral extmarks for the rows being drawn only, as Neovim's tree-sitter
  highlighter does. Spans are computed on the first draw after a change (by
  `changedtick`), per section: sections parse independently, so a section whose text is
  unchanged reuses its spans, and an edit re-parses only its own section. Multi-line spans
  are split into one piece per row. After a change the buffer's windows are redrawn once
  per event-loop turn, since Neovim redraws only the edited rows and an edit can recolour
  the rest of its section. At 3,000 lines an edit costs about 1 ms (30 ms when every span
  was an extmark refreshed for the whole buffer).
- wire stops the tree-sitter highlighter on `http` buffers (after other `FileType`
  handlers, which may start it), since both would colour the same text.
- Only file buffers (empty `buftype`) are highlighted: the response window's Headers tab
  also uses filetype `http` and keeps tree-sitter. Highlights are cleared when a buffer's
  filetype changes away from `http`.

### 9.5 Commands and keys

`:Wire send|all|cancel|open|env|scratch|reset`. The plugin defines no global mappings.

### 9.6 Health

`:checkhealth wire` reports `curl` and `jq` with their versions (an error for curl below
7.83, a warning for jq below 1.7), the `json` parser (optional), and the current buffer's base and project directories with the project files
found. Trust status is not shown: `vim.secure` has no public query; `:trust` manages it.

## 10. Configuration

```lua
require("wire").setup({
  helpers = {},  -- global helper files (§5.2)
  timeout = nil, -- seconds; nil = no overall limit
})
```

Fixed values: connect timeout 10 s, history 50 results, 1 MiB of body displayed.

## 11. Architecture

Repository:

```
lua/wire/
  init.lua        setup(), public API: send, send_all, cancel, open, reset, select_env, scratchpad, env, ctx
  config.lua      options
  document.lua    line parser: buffer lines → Document / Section data; section at cursor; parse errors
  project.lua     base and project directories, trusted reads, auto-trust on save
  env.lua         env files, merge, selection
  helpers.lua     helper layers, content cache
  context.lua     per-run state: variable chain, per-section memo, cycles, Lua environment, ctx binding
  template.lua    {{name}} / {%= %} rendering, JSON mode
  script.lua      pre/post scripts, test harness, log
  run.lua         snapshot, per-section pipeline, header merge, stop rules, quickfix/notify
  transport.lua   curl config serialization, temp files, vim.system, cancel
  mask.lua        secret registry, masking
  health.lua      :checkhealth wire
  ui/response.lua window, winbar tabs, summary virt lines, views, history, jq
  ui/report.lua   Report tab
  ui/icons.lua    inline extmarks
  highlight.lua   line-role highlighting, embedded JSON/Lua via tree-sitter
plugin/wire.lua   :Wire command
tests/            mini.test specs, fixtures, server.py
docs/design.md    this document
Makefile          test, lint, format
README.md         usage, dialect, helpers, migration from kulala
```

Dependencies:

- `document`, `project`, `mask`, `transport` depend on nothing in wire.
- `env` and `helpers` → `project`.
- `context` → `env`, `helpers`, `mask` (it registers private values when rendering them);
  `template` and `script` → `context`.
- `run` → `document`, `context`, `template`, `script`, `transport`.
- `ui/*` depend only on results (§7.2).
- `init` wires them together.

Data:

- **Document**: `{ base_dir, project_dir, preamble = { vars, imports }, sections }`.
- **Section**: `{ name, line, vars, pre, post, request = { method, url, headers, body } |
  nil }` — templates are unrendered strings.
- **Rendered request**: `{ name, method, url, headers, body }` — plain strings; `headers`
  is the merged list of `{ name, value }` in original case, which post scripts see as a
  lower-cased map (§4.5).
- **Result**: §7.2.

Only `transport`, `ui/response` (jq) and helpers run processes; everything else is tested
without a network.

## 12. Testing

Framework: [mini.test](https://github.com/echasnovski/mini.nvim/blob/main/readmes/mini-test.md),
bootstrapped by the Makefile into `deps/` (gitignored). `make test` runs everything headless
with `-u tests/minimal_init.lua` and `XDG_{CONFIG,DATA,STATE,CACHE}_HOME` pointing at a temp
directory (with `nvim/` created in the state dir), so the user's config, trust database and
environment selection are never touched. Headless `vim.secure.read` declines untrusted files
without prompting, so untrusted cases need no setup; fixtures that must load are trusted
with `vim.secure.trust({ action = "allow", path = … })`, again after each rewrite.

### 12.1 Rules

1. Every test has a named code change that turns it red, and that change was made once to
   watch the test fail (the red step of TDD). A test that cannot be made to fail is deleted.
2. Expected values are worked out by hand from the fixture, never produced by calling the
   code under test.
3. No display assertions: no screenshots, labels, messages, colours, icons or layout. UI is
   tested only through data it exposes.
4. No tests of dependencies: curl, jq, `vim.json`, `vim.secure`, `vim.fs` are assumed to
   work.
5. Fail-closed tests assert the effect (the server received nothing; the helper's sentinel
   file does not exist), not the error text.
6. No sleeps and no external network. The only server is on loopback; waiting is
   `vim.wait` on a condition with a bound; "slow" means a server that never answers.
7. No coverage targets.
8. Fixtures are synthetic.

### 12.2 Planned tests

| Module | Test | Turns red if… |
|---|---|---|
| document | Preamble `<` becomes a helper import; `<` inside a section becomes a pre-script | Classification ignores position |
| document | A body followed by a blank line and `# note` before the next `###` ends without the note and without a final newline, and the next section keeps its request | Trailing comment lines are kept in the body |
| document | A one-line `> {% … %}` and a multi-line `> {%` … `%}` give the same script text | The block end requires `%}` on its own line |
| document | A request line inside a body, a non-header line among the headers, and a `>` script before the request line each give a parse error at their line | That check is missing |
| highlight | In a preamble with `@blank =` and a section whose comments include a lone `#`, the request line is a method and the body is a JSON region starting at `{` | Highlighting does not follow the line parser, or the body region is off by a row |
| highlight | A line the parser rejects is marked as an error | Error lines are not marked |
| highlight | A one-line `> {% … %}` gets Lua captures at the code's own columns | Embedded captures ignore the column offset |
| highlight | wire stops a tree-sitter highlighter that another handler started on an `http` buffer | Both highlighters stay active |
| run | A run over sections where the last one has a parse error, or a script that does not compile, sends nothing | Validation happens per section instead of in the snapshot |
| template | JSON mode: a value inside `"…"` is escaped, an unquoted `{{port}}` is raw, `\"` inside a string does not end it, after `"C:\\"` the next value is outside the string, and a `{%= %}` containing `"` does not change the string state | String-state tracking is wrong, handles only `\"`, or scans placeholder text |
| template | `{%= file("p.txt") %}` keeps the file's `{{userName}}` literal; `{%= render(file("p.txt")) %}` resolves it from the section variable | Expression results are rendered again |
| template | A body under `Content-Type: text/plain` that starts with `{` is not JSON-escaped | The mode ignores `Content-Type` |
| run | A `{`-body whose `Content-Type: text/plain` comes only from `$defaultHeaders` is sent unescaped | `Content-Type` is read before the header merge |
| context | A request that does not use `{{apiKey}}` never calls its helper | Evaluation is eager |
| context | A document variable containing `{{zone}}` renders differently in two sections that define different `@zone`; within one section it is evaluated once; after a script sets a variable it is evaluated again | Memo per run, missing, or not cleared on `vars.X =` |
| context | Section beats script-set beats document beats environment beats process env | The chain order is wrong |
| context | A script variable set in one send is visible to a later separate send from the same buffer, gone after `:Wire reset`, and gone from another buffer of the same project after an environment switch | Script variables scoped to a run, never cleared, or cleared only in the current buffer |
| context | A script variable holding `{%= error('x') %}{{apiKey}}` is sent verbatim | Script variables are rendered as templates |
| context | `a → b → a` aborts after evaluating `a` once (a stack overflow would also raise, so the test counts evaluations) | Cycle detection is missing |
| context | An expression returning `nil` or a table, or reading an unknown bare name, aborts; the transport is not called | The value is coerced with `tostring`, or unknown names read as `nil` |
| helpers | A per-file import overrides `http-client.lua`, which overrides a global helper file, by name | Merge order is wrong |
| helpers | An untrusted `http-client.lua` is not executed (its sentinel file is not created) | The file is loaded without `vim.secure` |
| helpers | After `http-client.lua`'s content changes (and is re-trusted), the new definition is used | Cache keyed on path only |
| helpers | After `:write` of a changed `http-client.lua` buffer, the next run loads it | Auto-trust on save is missing |
| env | Private overrides public, the environment overrides `$shared`, and `$defaultHeaders` merges per header | Merge order or depth is wrong |
| env | An untrusted env file's `{%= %}` value is not evaluated (its sentinel file is not created) | The env file is read without `vim.secure` |
| mask | A value passed to `secret()` and embedded in `Bearer <secret>` is absent from `result.verbose` | Masking matches whole values only |
| mask | A private env value defined as `{%= … %}` and never passed to `secret()` is absent from `result.verbose` | Private values are registered unrendered, or not at all |
| mask | A secret containing `"`, `\`, a newline, `%` and `-`, sent in a JSON body, is absent from `result.verbose` | Only the raw form is registered, or matching uses Lua patterns |
| mask | An `Authorization: Bearer <token>` supplied only by `$defaultHeaders` is absent from `result.verbose`, and the bare token logged by a post script is absent from `result.logs` | Registration runs before the header merge, or the credential is not registered on its own |
| env | With `$schema`, `$shared` and `"prod": []` beside one object environment, that environment is the only choice and is selected by default | Non-environment keys are listed |
| env | Unknown `$` keys at the top level, in `$shared` and in an environment are reported per file; `$schema`, `$shared` and `$defaultHeaders` are not | Environment-level keys go unchecked, or `$schema` is reported |
| run | A send with an unknown `$` key in the env file notifies a warning naming it and still sends | The warning is dropped |
| script | After a failed `t.eq`, the next assertion in the same test still runs, and the test is failed | Asserts throw |
| script | `t.contains(s, "a.b%")` matches only the literal text | `find` is called without `plain` |
| script | `t.eq({ a = 1 }, { a = 1 })` passes | Compared with `==` |
| transport | The server receives exactly the rendered body bytes, including CRLF, a trailing newline and non-UTF-8 bytes | Body sent with `-d` or re-encoded |
| transport | The curl argv contains no header value and no URL | Headers or URL passed as arguments |
| transport | A URL containing `{a,b}` and `[0]` produces exactly one request, with that path verbatim | `globoff` is missing |
| transport | A header value containing `"`, `\` and `#` arrives byte-exact | Config escaping is wrong |
| transport | A header name (including a `$defaultHeaders` key), header value or URL containing `\n` aborts; the server receives nothing | Config values not validated |
| transport | A body without `Content-Type` arrives without `application/x-www-form-urlencoded`; an empty-valued header removes curl's `Accept` | Empty values dropped instead of passed as `Name:` |
| transport | A 4xx body is kept | `--fail` is added |
| transport | `HEAD` against a server that sends `Content-Length: 10` and no body completes | `HEAD` sent as `request = HEAD` |
| transport | Against a server that never answers, cancel yields "cancelled" and the process is gone | Kill not wired through |
| transport | Against a server that never answers, `timeout = 1` yields a transport failure | `--max-time` not passed |
| run | A variable set by section 1's post script reaches section 2; an abort in section 2 stops section 3 | Vars not carried within a run / abort not stopping |
| ui | `[` and `]` land on the right history entry; quickfix entries point at the failing sections' `###` lines | Index or line mapping is off |
| project | A nearer directory with only an env file beats a farther one with `http-client.lua` | `vim.fs.root` gets a flat list |
| project | After `:write` of a changed `http-client.lua`, it reads as trusted | Auto-trust on save is missing |
| mask | A shorter registered value inside a longer one does not leave the longer one's tail visible | Values are not replaced longest first |
| run | Cancelling `:Wire all` on a hanging request ends the run, sends nothing more, and a second start meanwhile is refused | Cancel does not stop the run or leaves it active |
| run | A post script that throws is a failed test named `post script (line N)`; the response is kept and the next section runs | Post-script errors abort |
| run | Lines inserted above a section during its run move its quickfix entry with it | Lines come from the snapshot, not the extmark |
| run | A scratchpad's relative `<` import that is untrusted is not executed and nothing is sent | Scratchpad imports bypass `vim.secure.read` |
| run | An env file with a JSON syntax error refuses the run | Decode errors are treated as an empty file |

The transport tests use `tests/server.py` (Python standard library, loopback, ephemeral
port). It echoes method, headers and body as JSON, returns a status chosen by the request
path, and can hold a connection open forever. It answers errors in JSON too.

Not tested, deliberately: colours and link targets, summary/Report/winbar formatting, icons, error
wording, `jq` key order, `:checkhealth` output, persistence of the environment selection.

## 13. Design decisions

Each is the simpler option and easy to change:

- §4.1: the `HTTP/x` token is ignored.
- §4.4: no automatic URL encoding.
- §4.6: pre-request scripts shape the request only through variables.
- §5.1: helpers and env files come from one project directory.
- §5.3: only discovered files are trust-gated.
- §7.1: one run at a time; starting another while busy is refused.
- §7.4: redirects are not followed.
- §8: `secret()` registers values instead of wrapping them; private env values and
  auth-style headers are registered automatically.

Also decided: wire reads requests with its own line parser
(§4.1), files saved from Neovim are trusted automatically (§5.3), and `:Wire open` reopens
the response window (§9.1). Smaller choices, each also easy
to change:

- §4.1: a line starting with `> ` ends a body; GraphQL and multipart bodies are sent as
  plain text instead of being refused.
- §4.2: the memo is per section; script variables are literal; an environment switch
  clears script variables project-wide.
- §8: values shorter than 4 characters are never registered, `secret()` included.
- §9.1: a visible response window keeps its tab on a new result unless tests failed or the
  section aborted.

Later: wire highlights from its own line
parser instead of the stock grammar (§9.4).
