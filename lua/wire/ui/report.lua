local M = {}

local marks = vim.api.nvim_create_namespace("wire.marks")

local function line_of(r)
  if not vim.api.nvim_buf_is_valid(r.buf) then
    return "?"
  end
  local pos = vim.api.nvim_buf_get_extmark_by_id(r.buf, marks, r.mark, {})
  return pos[1] and tostring(pos[1] + 1) or "?"
end

function M.build(results)
  local lines, rows, passed = {}, {}, 0
  local function add(text, r)
    lines[#lines + 1] = text
    rows[#lines] = r
  end
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
    local status = r.outcome == "ok" and tostring(r.response.status) or r.outcome
    local duration = r.response and ("%.2f s"):format(r.response.time) or "-"
    add(
      ("%s %5s  %-40s %-16s %8s  %d/%d"):format(
        r.failed and "✘" or "✔",
        line_of(r),
        r.section_name,
        status,
        duration,
        ok,
        #r.tests
      ),
      r
    )
    for _, t in ipairs(r.tests) do
      if not t.ok then
        add("        " .. t.name, r)
        for _, m in ipairs(t.messages) do
          for _, l in ipairs(vim.split(m, "\n", { plain = true })) do
            add("          " .. l, r)
          end
        end
      end
    end
    if r.error then
      add("        " .. r.error:match("^[^\n]*"), r)
    end
  end
  add("", nil)
  add(("%d/%d passed"):format(passed, #results), nil)
  return lines, rows
end

return M
