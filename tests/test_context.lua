local context = require("wire.context")
local eq = MiniTest.expect.equality

local function ctx(opts)
  opts.script_vars = opts.script_vars or {}
  return context.new(opts)
end

local T = MiniTest.new_set()

T["an unused variable's expression never runs"] = function()
  local called = false
  local c = ctx({
    doc_vars = { apiKey = "{%= key() %}", host = "h" },
    helpers = {
      key = function()
        called = true
        return "k"
      end,
    },
  })
  eq(c:render("{{host}}/x"), "h/x")
  eq(called, false)
end

T["the memo is per section and cleared when a script sets a variable"] = function()
  local n = 0
  local c = ctx({
    doc_vars = { label = "{%= count() %}:{{zone}}" },
    helpers = {
      count = function()
        n = n + 1
        return n
      end,
    },
  })
  c:begin_section({ zone = "eu" })
  eq(c:render("{{label}} {{label}}"), "1:eu 1:eu")
  c:begin_section({ zone = "us" })
  eq(c:render("{{label}}"), "2:us")
  c:set_var("other", "1")
  eq(c:render("{{label}}"), "3:us")
end

T["section, script, document, environment, process env, in that order"] = function()
  vim.env.WIRE_T_X = "process"
  local script_vars = { WIRE_T_X = "script" }
  local c = ctx({
    script_vars = script_vars,
    doc_vars = { WIRE_T_X = "document" },
    env_vars = { WIRE_T_X = "environment" },
  })
  c:begin_section({ WIRE_T_X = "section" })
  eq(c:lookup("WIRE_T_X"), "section")
  c:begin_section({})
  eq(c:lookup("WIRE_T_X"), "script")
  script_vars.WIRE_T_X = nil
  eq(c:lookup("WIRE_T_X"), "document")
  c.doc_vars.WIRE_T_X = nil
  eq(c:lookup("WIRE_T_X"), "environment")
  c.env_vars.WIRE_T_X = nil
  eq(c:lookup("WIRE_T_X"), "process")
end

T["script variables are literal"] = function()
  local c = ctx({ script_vars = { out = "{%= error('x') %}{{apiKey}}" } })
  eq(c:render("{{out}}"), "{%= error('x') %}{{apiKey}}")
end

T["a variable cycle aborts at once"] = function()
  local n = 0
  local c = ctx({
    doc_vars = { a = "{%= count() %}{{b}}", b = "{{a}}" },
    helpers = {
      count = function()
        n = n + 1
        return ""
      end,
    },
  })
  MiniTest.expect.error(function()
    c:render("{{a}}")
  end)
  eq(n, 1)
end

T["nil, a table or an unknown name in an expression aborts"] = function()
  local c = ctx({})
  for _, expr in ipairs({ "{%= nil %}", "{%= {} %}", "{%= tostring(TOKEN) %}" }) do
    MiniTest.expect.error(function()
      c:render(expr)
    end)
  end
end

return T
