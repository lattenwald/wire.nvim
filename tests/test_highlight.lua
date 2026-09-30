local highlight = require("wire.highlight")
local eq = MiniTest.expect.equality

local function groups_at(spans, row, col)
  local out = {}
  for _, s in ipairs(spans) do
    local after_start = row > s.row or (row == s.row and col >= s.col)
    local before_end = row < s.end_row or (row == s.end_row and col < s.end_col)
    if after_start and before_end then
      out[s.group] = true
    end
  end
  return out
end

local T = MiniTest.new_set()

T["a lone # and @blank = do not derail the request line or the JSON body"] = function()
  local spans, regions = highlight.classify({
    "@blank =",
    "",
    "### Create",
    "# creates an item",
    "#",
    "",
    "POST {{base}}/x",
    "",
    "{",
    '  "kind": "demo"',
    "}",
  })
  eq(groups_at(spans, 0, 0).WireVariable, true)
  eq(groups_at(spans, 6, 0).WireMethod, true)
  eq(regions, { { lang = "json", row = 8, col = 0, text = '{\n  "kind": "demo"\n}' } })
end

T["a line the parser rejects is marked as an error"] = function()
  local spans = highlight.classify({ "### a", "GET http://h/x", "not a header" })
  eq(groups_at(spans, 2, 0).WireError, true)
end

T["Lua captures of a one-line script land on the code's columns"] = function()
  local spans = highlight.spans({ "### a", "GET http://h/x", "", "> {% vars.x = 1 %}" })
  local at = vim.tbl_filter(function(s)
    return s.row == 3 and s.group:match("%.lua$")
  end, spans)
  local starts = vim.tbl_map(function(s)
    return s.col .. "-" .. s.end_col
  end, at)
  eq(vim.list_contains(starts, "5-9"), true)
end

T["wire stops a tree-sitter highlighter another handler started"] = function()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "### a", "GET http://h/x" })
  vim.bo[buf].filetype = "http"
  vim.treesitter.start(buf, "lua")
  highlight.enable(buf)
  vim.wait(1000, function()
    return vim.treesitter.highlighter.active[buf] == nil
  end)
  eq(vim.treesitter.highlighter.active[buf], nil)
end

T["a JSON Content-Type from the environment's defaults makes the body a JSON region"] = function()
  local lines = { "### a", "POST http://h/x", "", '"{{payload}}"' }
  local _, without = highlight.classify(lines)
  local _, with = highlight.classify(lines, { ["content-type"] = "application/json" })
  eq(without, {})
  eq(with, { { lang = "json", row = 3, col = 0, text = '"{{payload}}"' } })
end

T["a templated Content-Type is not trusted; the body decides"] = function()
  local lines = { "### a", "POST http://h/x", "Content-Type: {{ct}}", "", "{}" }
  local _, regions = highlight.classify(lines, { ["Content-Type"] = "text/plain" })
  eq(#regions, 1)
end

local function marks(buf)
  return vim.api.nvim_buf_get_extmarks(buf, vim.api.nvim_create_namespace("wire.highlight"), 0, -1, {})
end

T["a special buffer with filetype http, like the Headers tab, is left alone"] = function()
  require("wire").setup({})
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "HTTP 200", "content-type: application/json" })
  vim.bo[buf].filetype = "http"
  vim.wait(100)
  eq(marks(buf), {})
end

T["highlights are cleared once the buffer's filetype is no longer http"] = function()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "### a", "GET http://h/x" })
  vim.bo[buf].filetype = "http"
  highlight.enable(buf)
  vim.bo[buf].filetype = "json"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "{", '  "a": 1', "}" })
  vim.wait(100)
  eq(marks(buf), {})
end

return T
