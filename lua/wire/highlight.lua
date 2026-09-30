local M = {}

local INJECTIONS = [[
((comment) @injection.content
  (#set! injection.language "comment"))

((json_body) @injection.content
  (#set! injection.language "json"))

((xml_body) @injection.content
  (#set! injection.language "xml"))

((graphql_data) @injection.content
  (#set! injection.language "graphql"))

((script) @injection.content
  (#offset! @injection.content 0 2 0 -2)
  (#set! injection.language "lua"))
]]

local function decorate_line(ns, buf, row)
  local line = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ""
  local pos = 1
  while true do
    local s = line:find("{%=", pos, true)
    if not s then
      return
    end
    local e = line:find("%}", s + 3, true)
    local stop = e and e + 1 or #line
    vim.api.nvim_buf_set_extmark(buf, ns, row, s - 1, {
      end_col = stop,
      hl_group = "WireExpression",
      ephemeral = true,
      priority = 150,
    })
    pos = stop + 1
  end
end

function M.setup()
  vim.api.nvim_set_hl(0, "WireExpression", { link = "Special", default = true })
  if vim.treesitter.language.add("http") then
    vim.treesitter.query.set("http", "injections", INJECTIONS)
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if
        vim.api.nvim_buf_is_loaded(buf)
        and vim.bo[buf].filetype == "http"
        and vim.treesitter.highlighter.active[buf]
      then
        vim.treesitter.stop(buf)
        vim.treesitter.start(buf)
      end
    end
  end
  local ns = vim.api.nvim_create_namespace("wire.expression")
  vim.api.nvim_set_decoration_provider(ns, {
    on_win = function(_, _, buf)
      return vim.bo[buf].filetype == "http"
    end,
    on_line = function(_, _, buf, row)
      decorate_line(ns, buf, row)
    end,
  })
end

return M
