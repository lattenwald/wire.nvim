local helpers = require("wire.helpers")
local H = require("tests.helpers")
local eq = MiniTest.expect.equality

local T = MiniTest.new_set()

T["import overrides http-client.lua, which overrides a global file"] = function()
  local root = H.tmpdir()
  local global = H.write(root .. "/global.lua", 'return { a = "global", b = "global", c = "global" }')
  H.trust(H.write(root .. "/http-client.lua", 'return { b = "project", c = "project" }'))
  local merged = helpers.load_all({
    global = { global },
    root = root,
    imports = { { kind = "inline", code = 'return { c = "import" }', line = 1 } },
    base_dir = root,
    file = "t.http",
    read_import = require("wire.project").read_file,
  })
  eq({ merged.a, merged.b, merged.c }, { "global", "project", "import" })
end

T["an untrusted http-client.lua is not executed"] = function()
  local root = H.tmpdir()
  local sentinel = root .. "/sentinel"
  local path = H.write(root .. "/http-client.lua", ("vim.fn.writefile({}, %q)\nreturn {}"):format(sentinel))
  local _, untrusted = helpers.load_all({ root = root, base_dir = root, file = "t.http" })
  eq(H.exists(sentinel), false)
  eq(untrusted, { path })
end

T["changed content is loaded again"] = function()
  local root = H.tmpdir()
  local path = root .. "/http-client.lua"
  local function load()
    return helpers.load_all({ root = root, base_dir = root, file = "t.http" })
  end
  H.trust(H.write(path, "return { v = 1 }"))
  eq(load().v, 1)
  H.trust(H.write(path, "return { v = 2 }"))
  eq(load().v, 2)
end

return T
