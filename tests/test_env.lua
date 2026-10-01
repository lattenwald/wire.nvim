local config = require("wire.config")
local env = require("wire.env")
local project = require("wire.project")
local H = require("tests.helpers")
local eq = MiniTest.expect.equality

local home = vim.env.HOME

local T = MiniTest.new_set({
  hooks = {
    post_case = function()
      vim.env.HOME = home
      config.setup({})
    end,
  },
})

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

T["unknown $ keys are reported per file; $schema, $shared and $defaultHeaders are not"] = function()
  local root = H.tmpdir()
  H.trust(H.write(
    root .. "/http-client.env.json",
    [[{
      "$schema": "x",
      "$other": {},
      "$shared": { "$defaultHeaders": {}, "$sharedTypo": {} },
      "dev": { "$defaultHeaders": {}, "$kulalaDefaultHeaders": {} }
    }]]
  ))
  H.trust(H.write(root .. "/http-client.private.env.json", [[{ "dev": { "$secretHeaders": {} } }]]))
  local res = env.load(root)
  eq(res.warnings, {
    "http-client.env.json: $other: unknown key",
    "http-client.env.json: $shared: unknown key $sharedTypo",
    "http-client.env.json: dev: unknown key $kulalaDefaultHeaders",
    "http-client.private.env.json: dev: unknown key $secretHeaders",
  })
end

T["an untrusted env file contributes nothing"] = function()
  local root = H.tmpdir()
  local path = H.write(root .. "/http-client.env.json", [[{ "dev": { "k": "v" } }]])
  local res, untrusted = env.load(root)
  eq(res.names, {})
  eq(untrusted, { path })
end

T["a sibling sharing a trusted dir's name prefix still needs :trust"] = function()
  local root = H.tmpdir()
  local path = H.write(root .. "-other/http-client.lua", "return {}")
  config.setup({ trusted_dirs = { root } })
  eq({ project.read_trusted(path) }, { nil, "untrusted" })
end

T["trusted_dirs { '/' } trusts every file"] = function()
  local path = H.write(H.tmpdir() .. "/http-client.lua", "return {}")
  config.setup({ trusted_dirs = { "/" } })
  eq(project.read_trusted(path), "return {}")
end

T["trusted_dirs expands ~"] = function()
  vim.env.HOME = H.tmpdir()
  local path = H.write(vim.env.HOME .. "/p/http-client.lua", "return {}")
  config.setup({ trusted_dirs = { "~/p/" } })
  eq(project.read_trusted(path), "return {}")
end

T["an empty or relative trusted_dirs entry fails setup and trusts nothing"] = function()
  local path = H.write(H.tmpdir() .. "/http-client.lua", "return {}")
  for _, dir in ipairs({ "", "work" }) do
    MiniTest.expect.error(function()
      config.setup({ trusted_dirs = { dir } })
    end)
    eq({ project.read_trusted(path) }, { nil, "untrusted" })
  end
end

T["the nearest directory with any project file is the root"] = function()
  local root = H.tmpdir()
  H.write(root .. "/http-client.lua", "return {}")
  H.write(root .. "/sub/http-client.env.json", "{}")
  eq(project.find_root(root .. "/sub"), root .. "/sub")
end

local function save_in_nvim(path, line)
  project.setup_auto_trust(vim.api.nvim_create_augroup("wire_test_trust", {}))
  vim.cmd.edit(path)
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { line })
  vim.cmd.write()
  vim.cmd.bwipeout()
end

T["saving a project file from Neovim trusts it"] = function()
  local path = H.write(H.tmpdir() .. "/http-client.lua", "return {}\n")
  save_in_nvim(path, "return { v = 1 }")
  eq(project.read_trusted(path), "return { v = 1 }\n")
end

T["saving a project file read without a final newline trusts it"] = function()
  local path = H.write(H.tmpdir() .. "/http-client.env.json", "{}")
  save_in_nvim(path, [[{ "dev": {} }]])
  eq(project.read_trusted(path), '{ "dev": {} }\n')
end

return T
