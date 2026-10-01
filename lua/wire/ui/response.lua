local report = require("wire.ui.report")
local run = require("wire.run")
local tools = require("wire.tools")

local M = {}

local HISTORY = 50
local MAX_BODY = 1024 * 1024
local TABS = {
  { key = "B", id = "body", label = "Body" },
  { key = "H", id = "headers", label = "Headers" },
  { key = "A", id = "all", label = "All" },
  { key = "V", id = "verbose", label = "Verbose" },
  { key = "O", id = "output", label = "Script Output" },
  { key = "R", id = "report", label = "Report" },
}

local ns = vim.api.nvim_create_namespace("wire.summary")
local history, viewed = {}, 0
local state = { tab = "body" }

local function kind(headers)
  local ct = (headers["content-type"] or ""):lower()
  for _, k in ipairs({ "json", "xml", "html", "javascript" }) do
    if ct:find(k, 1, true) then
      return k
    end
  end
  if ct == "" or ct:find("^text/") then
    return "text"
  end
  return "binary"
end

local function ensure_jq(res)
  if res.pretty or res.jq_running then
    return
  end
  if not tools.usable("jq") then
    res.pretty = res.response.body
    return
  end
  res.jq_running = true
  vim.system({ "jq", "." }, { stdin = res.response.body, text = true }, function(r)
    vim.schedule(function()
      res.jq_running = false
      res.pretty = r.code == 0 and r.stdout or res.response.body
      if history[viewed] == res then
        M.render()
      end
    end)
  end)
end

local function body_lines(res)
  local r = res.response
  if not r then
    return {}, "text"
  end
  local k = kind(r.headers)
  if k == "binary" then
    return { ("binary, %d bytes"):format(#r.body) }, "text"
  end
  local text = r.body
  if k == "json" then
    ensure_jq(res)
    text = res.pretty or text
  end
  local lines = vim.split(text:sub(1, MAX_BODY), "\n", { plain = true })
  if #text > MAX_BODY then
    lines[#lines + 1] = ("… %d bytes in total"):format(#text)
  end
  return lines, k
end

local function header_lines(res)
  return res.response and run.response_head(res.response) or {}
end

local function output_lines(res)
  local out = res.logs ~= "" and vim.split(res.logs, "\n", { plain = true }) or {}
  for _, t in ipairs(res.tests) do
    if t.script_error then
      vim.list_extend(out, vim.split(t.messages[1], "\n", { plain = true }))
    end
  end
  if res.outcome == "aborted" then
    vim.list_extend(out, vim.split(res.error, "\n", { plain = true }))
  end
  return out
end

local function content(res)
  state.rows = nil
  if state.tab == "body" then
    return body_lines(res)
  elseif state.tab == "headers" then
    return header_lines(res), "http"
  elseif state.tab == "all" then
    local lines = header_lines(res)
    lines[#lines + 1] = ""
    return vim.list_extend(lines, (body_lines(res))), "text"
  elseif state.tab == "verbose" then
    return vim.split(res.verbose, "\n", { plain = true }), "text"
  elseif state.tab == "output" then
    return output_lines(res), "text"
  end
  local same_run = vim.tbl_filter(function(r)
    return r.run == res.run
  end, history)
  local lines
  lines, state.rows = report.build(same_run)
  return lines, "markdown"
end

local function winbar()
  local parts = {}
  for i, t in ipairs(TABS) do
    local hl = t.id == state.tab and "%#TabLineSel#" or "%#TabLine#"
    parts[#parts + 1] = ("%s%%%d@v:lua.wire_tab_click@ %s (%s) %%X"):format(hl, i, t.label, t.key)
  end
  parts[#parts + 1] = ("%%#TabLineFill#  [%d/%d]"):format(viewed, #history)
  return table.concat(parts)
end

local function visible()
  return state.win and vim.api.nvim_win_is_valid(state.win)
end

function M.render()
  local res = history[viewed]
  if not (visible() and res) then
    return
  end
  local lines, ft = content(res)
  local buf = state.buf
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = ft or "text"
  vim.b[buf].wire_env = res.env_name
  vim.wo[state.win].winbar = winbar()
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  local hl = res.failed and "DiagnosticError" or "DiagnosticOk"
  vim.api.nvim_buf_set_extmark(buf, ns, 0, 0, {
    virt_lines = vim.tbl_map(function(l)
      return { { l, hl } }
    end, vim.list_extend({ ("Result: %d/%d  %s"):format(viewed, #history, res.summary[1]) }, res.summary, 2)),
    virt_lines_above = true,
  })
  -- virt_lines above line 1 show only through topfill
  vim.api.nvim_win_call(state.win, function()
    vim.fn.winrestview({ topline = 1, topfill = #res.summary })
  end)
end

local function show_tab(id)
  state.tab = id
  M.render()
end

_G.wire_tab_click = function(i)
  show_tab(TABS[i].id)
end

function M.prev()
  if viewed > 1 then
    viewed = viewed - 1
  end
  M.render()
  return history[viewed]
end

function M.next()
  if viewed < #history then
    viewed = viewed + 1
  end
  M.render()
  return history[viewed]
end

function M.push(res)
  table.insert(history, res)
  if #history > HISTORY then
    local old = table.remove(history, 1)
    run.forget(old.buf, old.mark)
  end
  viewed = #history
end

local function close()
  if visible() then
    vim.api.nvim_win_close(state.win, true)
  end
end

local function jump()
  local r = state.rows and state.rows[vim.api.nvim_win_get_cursor(0)[1]]
  local row = r and run.mark_row(r)
  if not row then
    return
  end
  local win = vim.fn.win_findbuf(r.buf)[1]
  if win then
    vim.api.nvim_set_current_win(win)
  else
    vim.cmd.wincmd("p")
    vim.api.nvim_win_set_buf(0, r.buf)
  end
  vim.api.nvim_win_set_cursor(0, { row + 1, 0 })
end

local function yank()
  local res = history[viewed]
  if not (res and res.request) then
    return
  end
  vim.fn.setreg(vim.v.register, require("wire.transport").yank_text(res.request))
  vim.notify("wire: curl command yanked (unmasked)")
end

local keys_help

local function key_list()
  local list = {}
  for _, t in ipairs(TABS) do
    list[#list + 1] = {
      t.key,
      t.label .. " tab",
      function()
        show_tab(t.id)
      end,
    }
  end
  return vim.list_extend(list, {
    { "[", "previous result", M.prev },
    { "]", "next result", M.next },
    { "<CR>", "jump to the section under the cursor (Report tab)", jump },
    { "<C-c>", "cancel the active run", run.cancel },
    { "Y", "yank the request as a curl command (unmasked)", yank },
    { "q", "close the window", close },
    { "g?", "show these keys", keys_help },
  })
end

keys_help = function()
  local lines = {}
  for _, k in ipairs(key_list()) do
    lines[#lines + 1] = (" %-6s %s "):format(k[1], k[2])
  end
  local width = 0
  for _, l in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(l))
  end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = "wipe"
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "win",
    row = 1,
    col = 1,
    width = width,
    height = #lines,
    style = "minimal",
    border = "rounded",
    title = " wire keys ",
    title_pos = "center",
  })
  local function close_help()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end
  for _, lhs in ipairs({ "q", "<Esc>", "g?" }) do
    vim.keymap.set("n", lhs, close_help, { buffer = buf, nowait = true, silent = true })
  end
  vim.api.nvim_create_autocmd("WinLeave", { buffer = buf, once = true, callback = close_help })
end

local function set_keys(buf)
  for _, k in ipairs(key_list()) do
    vim.keymap.set("n", k[1], k[3], { buffer = buf, nowait = true, silent = true, desc = "wire: " .. k[2] })
  end
end

local function ensure_window()
  if visible() then
    return false
  end
  if not (state.buf and vim.api.nvim_buf_is_valid(state.buf)) then
    state.buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(state.buf, "wire://response")
    vim.bo[state.buf].bufhidden = "hide"
    vim.b[state.buf].wire_response = true
    set_keys(state.buf)
  end
  state.win = vim.api.nvim_open_win(state.buf, false, { split = "right", win = -1 })
  return true
end

function M.show_result(res)
  if ensure_window() then
    state.tab = "body"
  end
  if res.outcome == "aborted" then
    state.tab = "output"
  elseif vim.iter(res.tests):any(function(t)
    return not t.ok
  end) then
    state.tab = "report"
  end
  M.render()
end

function M.open()
  if #history == 0 then
    return vim.notify("wire: no results yet")
  end
  viewed = #history
  ensure_window()
  M.render()
end

return M
