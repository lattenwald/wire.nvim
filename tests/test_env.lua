local env = require("wire.env")
local project = require("wire.project")
local H = require("tests.helpers")
local eq = MiniTest.expect.equality

local T = MiniTest.new_set()

T["private over public, environment over $shared, $defaultHeaders per header"] = function()
  local root = H.tmpdir()
  H.trust(H.write(
    root .. "/http-client.env.json",
    [[{
      "$shared": { "host": "shared-host", "$defaultHeaders": { "Accept": "a/shared", "X-A": "shared" } },
      "dev": { "token": "public-token", "$defaultHeaders": { "X-A": "dev" } }
    }]]
  ))
  H.trust(H.write(root .. "/http-client.private.env.json", [[{ "dev": { "token": "private-token" } }]]))
  local res = env.load(root)
  eq(res.envs.dev.vars, { host = "shared-host", token = "private-token" })
  eq(res.envs.dev.default_headers, { Accept = "a/shared", ["X-A"] = "dev" })
end

T["only object keys without $ are environments; a single one is current"] = function()
  local root = H.tmpdir()
  H.trust(
    H.write(root .. "/http-client.env.json", [[{ "$schema": "x", "$shared": { "a": "1" }, "prod": [], "dev": {} }]])
  )
  local res = env.load(root)
  eq(res.names, { "dev" })
  eq(env.current(root, res.names), "dev")
end

T["an untrusted env file contributes nothing"] = function()
  local root = H.tmpdir()
  local path = H.write(root .. "/http-client.env.json", [[{ "dev": { "k": "v" } }]])
  local res, untrusted = env.load(root)
  eq(res.names, {})
  eq(untrusted, { path })
end

T["the nearest directory with any project file is the root"] = function()
  local root = H.tmpdir()
  H.write(root .. "/http-client.lua", "return {}")
  H.write(root .. "/sub/http-client.env.json", "{}")
  eq(project.find_root(root .. "/sub"), root .. "/sub")
end

T["saving a project file from Neovim trusts it"] = function()
  local root = H.tmpdir()
  local path = H.write(root .. "/http-client.lua", "return {}\n")
  project.setup_auto_trust(vim.api.nvim_create_augroup("wire_test_trust", {}))
  vim.cmd.edit(path)
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "return { v = 1 }" })
  vim.cmd.write()
  eq(project.read_trusted(path), "return { v = 1 }\n")
  vim.cmd.bwipeout()
end

return T
