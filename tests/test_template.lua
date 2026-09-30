local H = require("tests.helpers")
local template = require("wire.template")
local eq = MiniTest.expect.equality

local ctx = H.ctx

local T = MiniTest.new_set()

T["JSON mode escapes inside strings only"] = function()
  local c = ctx({ doc_vars = { v = 'a"b', port = "8080" } })
  local body = [[{"a": "{{v}}", "p": {{port}}, "q": "x\"{{v}}", "w": "C:\\", "r": {{port}}, "e": "{%= '"' %}{{v}}"}]]
  local want = [[{"a": "a\"b", "p": 8080, "q": "x\"a\"b", "w": "C:\\", "r": 8080, "e": "\"a\"b"}]]
  eq(template.render(c, body, { json = true }), want)
end

T["expression results are not rendered again; render() does"] = function()
  local c = ctx({
    helpers = {
      file = function()
        return "Hello, {{userName}}."
      end,
    },
  })
  c:begin_section({ userName = "Ada" })
  eq(template.render(c, '{%= file("p.txt") %}'), "Hello, {{userName}}.")
  eq(template.render(c, '{%= render(file("p.txt")) %}'), "Hello, Ada.")
end

T["JSON mode follows Content-Type first, then the body's first character"] = function()
  eq(template.is_json("text/plain", '{"a": 1}'), false)
  eq(template.is_json("application/vnd.api+json; charset=utf-8", "x"), true)
  eq(template.is_json("", ' {"a": 1}'), true)
  eq(template.is_json(nil, "a=1"), false)
end

return T
