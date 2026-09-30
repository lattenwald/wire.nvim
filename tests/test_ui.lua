local response = require("wire.ui.response")
local eq = MiniTest.expect.equality

local T = MiniTest.new_set()

T["[ and ] step through history and stop at its ends"] = function()
  local a, b, c = { id = "a" }, { id = "b" }, { id = "c" }
  response.push(a)
  response.push(b)
  response.push(c)
  eq(response.prev(), b)
  eq(response.prev(), a)
  eq(response.prev(), a)
  eq(response.next(), b)
  response.push({ id = "d" })
  eq(response.next().id, "d")
end

return T
