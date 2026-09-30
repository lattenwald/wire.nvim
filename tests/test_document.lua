local document = require("wire.document")
local eq = MiniTest.expect.equality

local T = MiniTest.new_set()

T["preamble < is a helper import, section < is a pre-script"] = function()
  local doc = document.parse({
    "< ./helpers.lua",
    "",
    "### A",
    "< ./pre.lua",
    "GET http://h/a",
  })
  eq(doc.preamble.imports, { { kind = "file", path = "./helpers.lua", line = 1, last = 1 } })
  eq(doc.sections[1].pre, { { kind = "file", path = "./pre.lua", line = 4, last = 4 } })
end

T["body drops a trailing comment; a lone # keeps the next line"] = function()
  local doc = document.parse({
    "### A",
    "POST http://h/a",
    "Content-Type: application/json",
    "",
    "{",
    '  "a": 1',
    "}",
    "",
    "# note",
    "",
    "### B",
    "#",
    "GET http://h/b",
  })
  eq(doc.sections[1].request.body, '{\n  "a": 1\n}')
  eq(doc.sections[2].request.url, "http://h/b")
end

T[">{% without a space ends the body and starts a post script"] = function()
  local doc = document.parse({
    "### A",
    "POST http://h/a",
    "",
    "{}",
    ">{% vars.id = 1 %}",
  })
  eq(doc.sections[1].request.body, "{}")
  eq(#doc.sections[1].post, 1)
end

T["one-line and multi-line inline scripts give the same code"] = function()
  local doc = document.parse({
    "### A",
    "GET http://h/a",
    "",
    "> {% log(response.status) %}",
    "### B",
    "GET http://h/b",
    "",
    "> {%",
    "log(response.status)",
    "%}",
  })
  eq(vim.trim(doc.sections[1].post[1].code), "log(response.status)")
  eq(vim.trim(doc.sections[2].post[1].code), "log(response.status)")
end

T["misplaced lines are parse errors at their line"] = function()
  local doc = document.parse({
    "### A",
    "POST http://h/a",
    "",
    "{}",
    "GET http://h/x",
    "### B",
    "GET http://h/b",
    "not a header",
    "### C",
    "> {% x() %}",
    "GET http://h/c",
  })
  local function lines(sec)
    return vim.tbl_map(function(e)
      return e.line
    end, sec.errors)
  end
  eq(lines(doc.sections[1]), { 5 })
  eq(lines(doc.sections[2]), { 8 })
  eq(lines(doc.sections[3]), { 10 })
end

return T
