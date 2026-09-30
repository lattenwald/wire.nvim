local context = require("wire.context")
local H = require("tests.helpers")
local eq = MiniTest.expect.equality

local server

local function paths()
  return vim.tbl_map(function(r)
    return r.path
  end, server.requests())
end

local T = MiniTest.new_set({
  hooks = {
    pre_once = function()
      server = H.server()
    end,
    pre_case = function()
      server.clear()
    end,
    post_once = function()
      server.stop()
    end,
  },
})

T["a parse error or a broken script anywhere refuses the whole run"] = function()
  local dir = H.tmpdir()
  local cases = {
    { "### ok", "GET " .. server.url .. "/ok", "### bad", "GET " .. server.url .. "/bad", "not a header" },
    {
      "### ok",
      "GET " .. server.url .. "/ok",
      "### bad",
      "GET " .. server.url .. "/bad",
      "",
      "> {% this is not lua %}",
    },
  }
  for i, lines in ipairs(cases) do
    local buf = H.http_buf(dir .. "/r" .. i .. ".http", lines)
    local _, done = H.run(buf, "all")
    eq(done, false)
  end
  eq(server.requests(), {})
end

T["a script variable reaches the next section; an abort stops the run"] = function()
  local buf = H.http_buf(H.tmpdir() .. "/r.http", {
    "@base = " .. server.url,
    "### one",
    "GET {{base}}/one",
    "",
    '> {% vars.token = "v" .. response.status %}',
    "### two",
    "GET {{base}}/two/{{token}}",
    "### three",
    "GET {{base}}/three/{{missing}}",
    "### four",
    "GET {{base}}/four",
  })
  local results = H.run(buf, "all")
  eq(paths(), { "/one", "/two/v200" })
  eq(
    vim.tbl_map(function(r)
      return r.outcome
    end, results),
    { "ok", "ok", "aborted" }
  )
end

T["JSON mode sees a Content-Type that only $defaultHeaders sets"] = function()
  local root = H.tmpdir()
  H.trust(
    H.write(root .. "/http-client.env.json", [[{ "dev": { "$defaultHeaders": { "Content-Type": "text/plain" } } }]])
  )
  local buf = H.http_buf(root .. "/r.http", {
    '@v = a"b',
    "### one",
    "POST " .. server.url .. "/one",
    "",
    '{"k": "{{v}}"}',
  })
  H.run(buf, "all")
  eq(vim.base64.decode(server.requests()[1].body), '{"k": "a"b"}')
end

T["private env values and auth headers are masked in Verbose and logs"] = function()
  local root = H.tmpdir()
  H.trust(
    H.write(
      root .. "/http-client.env.json",
      [[{ "dev": { "tok": "tk-9f8e7d-555", "$defaultHeaders": { "Authorization": "Bearer {{tok}}" } } }]]
    )
  )
  H.trust(H.write(root .. "/http-client.private.env.json", [[{ "dev": { "key": "{%= 'pv-' .. 'secret-9' %}" } }]]))
  local buf = H.http_buf(root .. "/r.http", {
    "### one",
    "GET " .. server.url .. "/one",
    "X-Other: {{key}}",
    "",
    "> {% log(vars.tok) %}",
  })
  local results = H.run(buf, "all")
  local r = results[1]
  eq(r.verbose:find("pv-secret-9", 1, true), nil)
  eq(r.verbose:find("tk-9f8e7d-555", 1, true), nil)
  eq(r.logs:find("tk-9f8e7d-555", 1, true), nil)
end

T["script variables outlive a run, not a reset"] = function()
  local buf = H.http_buf(H.tmpdir() .. "/r.http", {
    "### set",
    "GET " .. server.url .. "/set",
    "",
    '> {% vars.sv = "one" %}',
    "### use",
    "GET " .. server.url .. "/use/{{sv}}",
  })
  H.run(buf, "cursor", 1)
  H.run(buf, "cursor", 5)
  context.clear_script_vars(buf)
  H.run(buf, "cursor", 5)
  eq(paths(), { "/set", "/use/one" })
end

T["an environment switch clears every buffer of the project"] = function()
  local root, other = H.tmpdir(), H.tmpdir()
  local a = H.http_buf(root .. "/a.http", { "### x", "GET http://h/x" })
  local b = H.http_buf(root .. "/b.http", { "### x", "GET http://h/x" })
  local c = H.http_buf(other .. "/c.http", { "### x", "GET http://h/x" })
  for _, buf in ipairs({ a, b, c }) do
    vim.b[buf].wire_project_dir = buf == c and other or root
    context.script_vars(buf).t = "1"
  end
  context.clear_project_vars(root)
  eq({ context.script_vars(a).t, context.script_vars(b).t, context.script_vars(c).t }, { nil, nil, "1" })
end

T["an untrusted env file refuses the run and is not evaluated"] = function()
  local root = H.tmpdir()
  local sentinel = root .. "/sentinel"
  H.write(
    root .. "/http-client.env.json",
    ([[{ "dev": { "k": "{%%= vim.fn.writefile({}, %q) .. 'x' %%}" } }]]):format(sentinel)
  )
  local buf = H.http_buf(root .. "/r.http", { "### one", "GET " .. server.url .. "/{{k}}" })
  H.run(buf, "all")
  eq(H.exists(sentinel), false)
  eq(server.requests(), {})
end

T["cancel ends the run; a second run is refused while one is active"] = function()
  local run = require("wire.run")
  local buf = H.http_buf(H.tmpdir() .. "/r.http", {
    "### hang",
    "GET " .. server.url .. "/hang",
    "### after",
    "GET " .. server.url .. "/after",
  })
  local done = false
  local hooks = {
    started = function() end,
    result = function() end,
    finished = function()
      done = true
    end,
  }
  eq(run.start(buf, "all", nil, hooks) ~= nil, true)
  vim.wait(5000, function()
    return #server.requests() == 1
  end)
  eq(run.start(buf, "all", nil, hooks), nil)
  run.cancel()
  vim.wait(5000, function()
    return done
  end)
  eq(run.active, nil)
  eq(paths(), { "/hang" })
end

T["a throwing post script is a failed test and the run goes on"] = function()
  local buf = H.http_buf(H.tmpdir() .. "/r.http", {
    "### one",
    "GET " .. server.url .. "/one",
    "",
    "> {% local x = response.json.missing.field %}",
    "### two",
    "GET " .. server.url .. "/two",
  })
  local results = H.run(buf, "all")
  eq(results[1].outcome, "ok")
  eq(results[1].failed, true)
  eq(results[1].tests[1].name, "post script (line 4)")
  eq(paths(), { "/one", "/two" })
end

T["results follow the ### line when the buffer is edited during a run"] = function()
  local buf = H.http_buf(H.tmpdir() .. "/r.http", {
    "### one",
    "GET " .. server.url .. "/one",
    "",
    '> {% test("fails", function(t) t.ok(false) end) %}',
  })
  local done = false
  require("wire.run").start(buf, "all", nil, {
    started = function()
      vim.api.nvim_buf_set_lines(buf, 0, 0, false, { "# a", "# b", "# c" })
    end,
    result = function() end,
    finished = function()
      done = true
    end,
  })
  vim.wait(5000, function()
    return done
  end)
  eq(vim.fn.getqflist()[1].lnum, 4)
end

T["a scratchpad's relative import is trust-gated"] = function()
  local dir = H.tmpdir()
  local sentinel = dir .. "/sentinel"
  H.write(dir .. "/imp.lua", ("vim.fn.writefile({}, %q)\nreturn {}"):format(sentinel))
  local buf = H.http_buf(dir .. "/scratch.http", { "< ./imp.lua", "### one", "GET " .. server.url .. "/one" })
  vim.b[buf].wire_scratch = true
  H.run(buf, "all")
  eq(H.exists(sentinel), false)
  eq(server.requests(), {})
end

T["a broken env file refuses the run"] = function()
  local root = H.tmpdir()
  H.trust(H.write(root .. "/http-client.env.json", '{ "dev": { "a": 1 '))
  local buf = H.http_buf(root .. "/r.http", { "### one", "GET " .. server.url .. "/one" })
  H.run(buf, "all")
  eq(server.requests(), {})
end

T["quickfix points at the failing section's ### line"] = function()
  local buf = H.http_buf(H.tmpdir() .. "/r.http", {
    "@base = " .. server.url,
    "",
    "### one",
    "GET {{base}}/one",
    "",
    "### two",
    "GET {{base}}/two",
    "",
    '> {% test("fails", function(t) t.eq(1, 2) end) %}',
    "",
    "### three",
    "GET {{base}}/three",
  })
  H.run(buf, "all")
  local items = vim.fn.getqflist({ title = 0, items = 0 })
  eq(items.title, "wire")
  eq(
    vim.tbl_map(function(i)
      return i.lnum
    end, items.items),
    { 6 }
  )
end

return T
