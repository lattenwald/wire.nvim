local H = require("tests.helpers")
local eq = MiniTest.expect.equality

local function client_of(buf)
  return vim.lsp.get_clients({ bufnr = buf, name = "wire" })[1]
end

local function attach(buf)
  vim.api.nvim_win_set_buf(0, buf)
  vim.lsp.enable("wire")
  vim.wait(2000, function()
    return client_of(buf) ~= nil
  end)
  return assert(client_of(buf), "wire did not attach")
end

local function request(buf, method, params)
  local r = vim.lsp.buf_request_sync(buf, method, params, 2000)[client_of(buf).id]
  assert(not r.err, r.err and r.err.message)
  return r.result
end

local function request_at(buf, row, text, method)
  local col = vim.api.nvim_buf_get_lines(buf, row - 1, row, false)[1]:find(text, 1, true)
  vim.api.nvim_win_set_cursor(0, { row, col - 1 })
  local params = vim.lsp.util.make_position_params(0, client_of(buf).offset_encoding)
  return request(buf, method, params)
end

local function definition(buf, row, text)
  return vim.tbl_map(function(l)
    return ("%s:%d"):format(vim.fs.basename(vim.uri_to_fname(l.uri)), l.range.start.line + 1)
  end, request_at(buf, row, text, "textDocument/definition"))
end

local function hover(buf, row, text)
  return request_at(buf, row, text, "textDocument/hover").contents.value
end

local T = MiniTest.new_set({
  hooks = {
    post_case = function()
      vim.lsp.enable("wire", false)
      for _, c in ipairs(vim.lsp.get_clients({ name = "wire" })) do
        c:stop(true)
      end
      vim.cmd("silent! %bwipeout!")
    end,
  },
})

T["enabling attaches to an .http buffer that is already open, as after a lazy load"] = function()
  local buf = H.http_buf(H.tmpdir() .. "/r.http", { "### a", "GET http://h.invalid/" })
  eq(vim.bo[buf].filetype, "http")
  eq(attach(buf).offset_encoding, "utf-8")
end

T["symbols: file variables, then each section with its variables"] = function()
  local buf = H.http_buf(H.tmpdir() .. "/r.http", {
    "@base = http://h.invalid",
    "### list",
    "@page = 2",
    "GET {{base}}/items?page={{page}}",
    "###",
    "DELETE {{base}}/items/1",
  })
  attach(buf)
  local function flat(symbols)
    return vim.tbl_map(function(s)
      return { s.name, s.range.start.line + 1, s.range["end"].line + 1, s.children and flat(s.children) }
    end, symbols)
  end
  local symbols = request(buf, "textDocument/documentSymbol", { textDocument = { uri = vim.uri_from_bufnr(buf) } })
  eq(flat(symbols), {
    { "@base", 1, 1 },
    { "list", 2, 4, { { "@page", 3, 3 } } },
    { "DELETE {{base}}/items/1", 5, 6, {} },
  })
end

T["definition and hover pick what a send would: section, file, then environment"] = function()
  local root = H.tmpdir()
  H.write(
    root .. "/http-client.env.json",
    '{\n  "$shared": { "v": "shared", "tok": "public-shared", "only": "s" },\n  "dev": {\n    "v": "dev",\n    "tok": "public",\n    "key": "plain-key"\n  }\n}\n'
  )
  H.write(
    root .. "/http-client.private.env.json",
    '{\n  "$shared": { "key": "pv-shared-1" },\n  "dev": { "tok": "pv-secret-9" }\n}\n'
  )
  local buf = H.http_buf(root .. "/r.http", {
    "@id = file",
    "### a",
    "@id = section",
    "GET http://h.invalid/{{id}}/{{v}}/é/{{tok}}/{{key}}/{{only}}",
    "###",
    "GET http://h.invalid/{{id}}",
  })
  attach(buf)
  eq(definition(buf, 4, "{{id}}"), { "r.http:3" })
  eq(definition(buf, 6, "{{id}}"), { "r.http:1" })
  eq(definition(buf, 4, "{{v}}"), { "http-client.env.json:4" })
  eq(definition(buf, 4, "{{tok}}"), { "http-client.private.env.json:3" })
  eq(hover(buf, 4, "{{id}}"), "`{{id}}`: section variable\n```\nsection\n```")
  eq(hover(buf, 4, "{{tok}}"), "`{{tok}}`: environment `dev`, http-client.private.env.json\n```\n••••\n```")
  eq(hover(buf, 4, "{{only}}"), "`{{only}}`: environment `dev` (`$shared`), http-client.env.json\n```\ns\n```")
  -- private in $shared, so masked on send although the public file overrides it
  eq(hover(buf, 4, "{{key}}"), "`{{key}}`: environment `dev`, http-client.env.json\n```\n••••\n```")
end

T["with no environment selected, definition lists every one and hover shows no value"] = function()
  local root = H.tmpdir()
  H.write(root .. "/http-client.env.json", '{\n  "dev": { "base": "d" },\n  "prod": { "base": "p" }\n}\n')
  local buf = H.http_buf(root .. "/r.http", { "### a", "GET {{base}}/x" })
  attach(buf)
  eq(definition(buf, 2, "{{base}}"), { "http-client.env.json:2", "http-client.env.json:3" })
  eq(hover(buf, 2, "{{base}}"), "`{{base}}`: no environment selected (`:Wire env`); defined in `dev`, `prod`")
end

T["a script variable wins hover; definition goes to the definition it shadows"] = function()
  local buf = H.http_buf(H.tmpdir() .. "/r.http", { "@token = initial", "### a", "GET http://h.invalid/{{token}}" })
  require("wire.context").script_vars(buf).token = "from-login"
  attach(buf)
  eq(
    hover(buf, 3, "{{token}}"),
    "`{{token}}`: script variable from an earlier send (`:Wire reset` clears it)\n```\nfrom-login\n```"
  )
  eq(definition(buf, 3, "{{token}}"), { "r.http:1" })
end

T["definition on a script line opens the script file"] = function()
  local root = H.tmpdir()
  H.write(root .. "/scripts/check.lua", "")
  local buf = H.http_buf(root .. "/r.http", { "### a", "GET http://h.invalid/", "", "> scripts/check.lua" })
  attach(buf)
  eq(definition(buf, 4, "check"), { "check.lua:1" })
end

T["the yank code action renders the request into the register"] = function()
  local buf = H.http_buf(H.tmpdir() .. "/r.http", { "@id = 7", "### a", "GET http://h.invalid/{{id}}" })
  local client = attach(buf)
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  eq(request(buf, "textDocument/codeAction", vim.lsp.util.make_range_params(0, "utf-8")), {})
  vim.api.nvim_win_set_cursor(0, { 3, 0 })
  local actions = request(buf, "textDocument/codeAction", vim.lsp.util.make_range_params(0, "utf-8"))
  local yank = vim.iter(actions):find(function(a)
    return a.command == "wire.yank"
  end)
  vim.fn.setreg('"', "")
  client:exec_cmd(yank, { bufnr = buf })
  vim.wait(2000, function()
    return vim.fn.getreg('"') ~= ""
  end)
  MiniTest.expect.no_equality(vim.fn.getreg('"'):find('url = "http://h.invalid/7"', 1, true), nil)
end

T["code actions: none for a kind filter, refused once the buffer changed"] = function()
  local buf = H.http_buf(H.tmpdir() .. "/r.http", { "### a", "GET http://h.invalid/" })
  attach(buf)
  vim.api.nvim_win_set_cursor(0, { 2, 0 })
  local params = vim.lsp.util.make_range_params(0, "utf-8")
  params.context = { only = { "source.fixAll" }, diagnostics = {} }
  eq(request(buf, "textDocument/codeAction", params), {})
  params.context = { diagnostics = {} }
  local send = request(buf, "textDocument/codeAction", params)[1]
  vim.api.nvim_buf_set_lines(buf, 0, 0, false, { "### above" })
  for _, args in ipairs({ send.arguments, {} }) do
    local r = vim.lsp.buf_request_sync(
      buf,
      "workspace/executeCommand",
      { command = send.command, arguments = args },
      2000
    )[client_of(buf).id]
    eq(r.err.message, "the buffer changed since the action was offered; ask for actions again")
  end
end

T["an unnamed .http buffer gets no client"] = function()
  vim.cmd.enew()
  local buf = vim.api.nvim_get_current_buf()
  vim.bo[buf].filetype = "http"
  vim.lsp.enable("wire")
  vim.wait(100)
  eq(#vim.lsp.get_clients({ bufnr = buf }), 0)
end

T["a process variable wins over an unselected environment, for definition too"] = function()
  local root = H.tmpdir()
  H.write(root .. "/http-client.env.json", '{ "dev": { "WIRE_T_PROC": "d" }, "prod": { "WIRE_T_PROC": "p" } }')
  local buf = H.http_buf(root .. "/r.http", { "### a", "GET http://h.invalid/{{WIRE_T_PROC}}" })
  vim.env.WIRE_T_PROC = "x"
  attach(buf)
  eq(definition(buf, 2, "{{WIRE_T_PROC}}"), {})
  eq(hover(buf, 2, "{{WIRE_T_PROC}}"), "`{{WIRE_T_PROC}}`: process environment variable")
  vim.env.WIRE_T_PROC = nil
end

T["an escaped env key is spanned as written"] = function()
  local root = H.tmpdir()
  H.write(root .. "/http-client.env.json", '{ "dev": { "a\\u0062c": "v" } }')
  local buf = H.http_buf(root .. "/r.http", { "### a", "GET http://h.invalid/{{abc}}" })
  attach(buf)
  local r = request_at(buf, 2, "{{abc}}", "textDocument/definition")[1].range
  eq({ r.start.character, r["end"].character }, { 11, 21 })
end

T["hover names an env file that fails to parse"] = function()
  local root = H.tmpdir()
  H.write(root .. "/http-client.env.json", '{ "dev": { "base": "d", } }')
  local buf = H.http_buf(root .. "/r.http", { "### a", "GET {{base}}/x" })
  attach(buf)
  MiniTest.expect.no_equality(hover(buf, 2, "{{base}}"):find("env files not read: " .. root, 1, true), nil)
end

T["hover ignores {{name}} in Lua script blocks"] = function()
  local buf = H.http_buf(H.tmpdir() .. "/r.http", {
    "@x = 1",
    "### a",
    "GET http://h.invalid/",
    "",
    "> {%",
    'vars.y = "{{x}}"',
    "%}",
  })
  attach(buf)
  eq(request_at(buf, 6, "{{x}}", "textDocument/hover"), nil)
end

T["a value holding a code fence gets a longer one"] = function()
  local buf = H.http_buf(H.tmpdir() .. "/r.http", { "@x = a```b", "### a", "GET http://h.invalid/{{x}}" })
  attach(buf)
  eq(hover(buf, 3, "{{x}}"), "`{{x}}`: file variable\n````\na```b\n````")
end

T["only the code actions run as commands"] = function()
  local buf = H.http_buf(H.tmpdir() .. "/r.http", { "### a", "GET http://h.invalid/" })
  attach(buf)
  local params = { command = "wire.setup", arguments = { vim.uri_from_bufnr(buf), 2 } }
  local r = vim.lsp.buf_request_sync(buf, "workspace/executeCommand", params, 2000)[client_of(buf).id]
  eq(r.err.message, "unknown command: wire.setup")
end

T["the API functions ignore callback arguments"] = function()
  local buf = H.http_buf(H.tmpdir() .. "/r.http", { "### a", "GET http://h.invalid/x" })
  vim.api.nvim_win_set_buf(0, buf)
  vim.api.nvim_win_set_cursor(0, { 2, 0 })
  vim.fn.setreg('"', "")
  require("wire").yank({ buf = buf, event = "User" })
  MiniTest.expect.no_equality(vim.fn.getreg('"'):find('url = "http://h.invalid/x"', 1, true), nil)
end

T["a closed server refuses requests"] = function()
  local server = require("wire.lsp").server({ on_exit = function() end })
  server.notify("exit")
  eq(server.request("initialize", {}, function() end), false)
end

T["a stopped client goes away"] = function()
  local buf = H.http_buf(H.tmpdir() .. "/r.http", { "### a" })
  attach(buf):stop()
  eq(
    vim.wait(2000, function()
      return client_of(buf) == nil
    end),
    true
  )
end

return T
