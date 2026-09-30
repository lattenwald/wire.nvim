local project = require("wire.project")

local M = {}

function M.check()
  local h = vim.health
  h.start("wire")
  if vim.fn.executable("curl") == 1 then
    local out = vim.system({ "curl", "--version" }, { text = true }):wait().stdout or ""
    h.ok("curl " .. (out:match("^curl (%S+)") or "(unknown version)"))
  else
    h.error("curl not found")
  end
  if vim.fn.executable("jq") == 1 then
    h.ok("jq found")
  else
    h.warn("jq not found: JSON bodies are shown as received")
  end
  if vim.treesitter.language.add("http") then
    h.ok("http tree-sitter parser found")
  else
    h.warn("http tree-sitter parser not found: no highlighting")
  end
  local buf = vim.api.nvim_get_current_buf()
  if vim.bo[buf].filetype ~= "http" then
    return
  end
  local base, root = project.refresh(buf)
  h.info("base directory: " .. base)
  if not root then
    return h.info("no project directory")
  end
  local found = vim.tbl_filter(function(f)
    return vim.uv.fs_stat(root .. "/" .. f) ~= nil
  end, project.markers)
  h.info(("project directory: %s (%s)"):format(root, table.concat(found, ", ")))
end

return M
