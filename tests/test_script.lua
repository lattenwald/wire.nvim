local script = require("wire.script")
local eq = MiniTest.expect.equality

local function run(fn)
  return script.run_test({}, "t", fn)
end

local T = MiniTest.new_set()

T["contains matches literal text"] = function()
  eq(
    run(function(t)
      t.contains("x a.b% y", "a.b%")
    end).ok,
    true
  )
  eq(
    run(function(t)
      t.contains("axb", "a.b")
    end).ok,
    false
  )
end

T["eq compares tables by value"] = function()
  eq(
    run(function(t)
      t.eq({ a = 1 }, { a = 1 })
    end).ok,
    true
  )
end

return T
