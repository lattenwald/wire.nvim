local M = {}

local marks = vim.api.nvim_create_namespace("wire.marks")

local HEAD = { "", "Line", "Request", "Status", "Time", "Tests" }
local RIGHT = { false, true, false, false, true, true }

local function line_of(r)
  if not vim.api.nvim_buf_is_valid(r.buf) then
    return "?"
  end
  local pos = vim.api.nvim_buf_get_extmark_by_id(r.buf, marks, r.mark, {})
  return pos[1] and tostring(pos[1] + 1) or "?"
end

local function cell(s)
  return (s:gsub("\n.*", ""):gsub("|", "\\|"))
end

local function pad(s, width, right)
  local fill = (" "):rep(width - vim.fn.strdisplaywidth(s))
  return right and (fill .. s) or (s .. fill)
end

function M.build(results)
  local rows, owners, passed = { HEAD }, { false }, 0
  for _, r in ipairs(results) do
    local ok = 0
    for _, t in ipairs(r.tests) do
      if t.ok then
        ok = ok + 1
      end
    end
    if not r.failed then
      passed = passed + 1
    end
    rows[#rows + 1] = {
      r.failed and "✘" or "✔",
      line_of(r),
      cell(r.section_name),
      r.outcome == "ok" and tostring(r.response.status) or r.outcome,
      r.response and ("%.2f s"):format(r.response.time) or "-",
      ("%d/%d"):format(ok, #r.tests),
    }
    owners[#rows] = r
    for _, t in ipairs(r.tests) do
      rows[#rows + 1] = { "", "", cell(("↳ %s %s"):format(t.ok and "✔" or "✘", t.name)), "", "", "" }
      owners[#rows] = r
    end
  end

  local widths = {}
  for c = 1, #HEAD do
    widths[c] = 3
    for _, row in ipairs(rows) do
      widths[c] = math.max(widths[c], vim.fn.strdisplaywidth(row[c]))
    end
  end
  local function format(row)
    local cells = {}
    for c, v in ipairs(row) do
      cells[c] = pad(v, widths[c], RIGHT[c])
    end
    return "| " .. table.concat(cells, " | ") .. " |"
  end

  local lines, map = {}, {}
  local function add(text, r)
    lines[#lines + 1] = text
    map[#lines] = r or nil
  end
  add(("**%d/%d passed**"):format(passed, #results))
  add("")
  add(format(rows[1]))
  local rule = {}
  for c = 1, #HEAD do
    rule[c] = RIGHT[c] and (("-"):rep(widths[c] + 1) .. ":") or ("-"):rep(widths[c] + 2)
  end
  add("|" .. table.concat(rule, "|") .. "|")
  for i = 2, #rows do
    add(format(rows[i]), owners[i])
  end

  for _, r in ipairs(results) do
    local failures = vim.tbl_filter(function(t)
      return not t.ok
    end, r.tests)
    if #failures > 0 or r.error then
      add("")
      add(("## ✘ %s (line %s)"):format(r.section_name, line_of(r)), r)
      if r.error then
        add("", r)
        add(("%s:"):format(r.outcome), r)
        add("~~~", r)
        for _, l in ipairs(vim.split(r.error, "\n", { plain = true })) do
          add(l, r)
        end
        add("~~~", r)
      end
      for _, t in ipairs(failures) do
        add("", r)
        add(("✘ %s"):format(t.name), r)
        add("~~~", r)
        for _, m in ipairs(t.messages) do
          for _, l in ipairs(vim.split(m, "\n", { plain = true })) do
            add(l, r)
          end
        end
        add("~~~", r)
      end
    end
  end
  return lines, map
end

return M
