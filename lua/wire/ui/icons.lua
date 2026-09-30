local M = {}

local ns = vim.api.nvim_create_namespace("wire.icons")

function M.running(buf, row)
  vim.api.nvim_buf_clear_namespace(buf, ns, row, row + 1)
  return vim.api.nvim_buf_set_extmark(buf, ns, row, 0, { virt_text = { { "⏳", "Comment" } } })
end

function M.done(buf, id, res)
  local pos = vim.api.nvim_buf_get_extmark_by_id(buf, ns, id, {})
  if not pos[1] then
    return
  end
  local failed = 0
  for _, t in ipairs(res.tests) do
    if not t.ok then
      failed = failed + 1
    end
  end
  local text
  if res.outcome == "ok" and failed > 0 then
    text = ("✘ %d · %d failed"):format(res.response.status, failed)
  elseif res.outcome == "ok" then
    text = ("✔ %d · %.2f s"):format(res.response.status, res.response.time)
  elseif res.outcome == "transport_error" then
    text = "✘ " .. res.error:match("^[^\n]*")
  else
    text = "✘ " .. res.outcome
  end
  vim.api.nvim_buf_set_extmark(buf, ns, pos[1], 0, {
    id = id,
    virt_text = { { text, res.failed and "DiagnosticError" or "DiagnosticOk" } },
  })
end

return M
