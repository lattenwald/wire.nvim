local M = {}

local PLACEHOLDER = "{{%s*([%w_.$-]+)%s*}}"
local QUOTE, BACKSLASH = 34, 92

M.PLACEHOLDER = PLACEHOLDER

local function scan(s, st)
  for i = 1, #s do
    local c = s:byte(i)
    if st.in_str then
      if st.esc then
        st.esc = false
      elseif c == BACKSLASH then
        st.esc = true
      elseif c == QUOTE then
        st.in_str = false
      end
    elseif c == QUOTE then
      st.in_str = true
    end
  end
end

function M.render(ctx, text, opts)
  opts = opts or {}
  local where = opts.where or "template"
  local out, pos, st = {}, 1, { in_str = false, esc = false }
  local ps, pe, name, es
  while true do
    if ps ~= false and (not ps or ps < pos) then
      ps, pe, name = text:find(PLACEHOLDER, pos)
      ps = ps or false
    end
    if es ~= false and (not es or es < pos) then
      es = text:find("{%=", pos, true) or false
    end
    local s = (es and (not ps or es < ps)) and es or ps
    if not s then
      break
    end
    local lit = text:sub(pos, s - 1)
    if opts.json then
      scan(lit, st)
    end
    out[#out + 1] = lit
    local value
    if s == es then
      local close = text:find("%}", es + 3, true)
      if not close then
        error(where .. ": unclosed {%=", 0)
      end
      local expr = text:sub(es + 3, close - 1)
      if expr:find("\n", 1, true) then
        error(where .. ": an expression must be on one line", 0)
      end
      value = ctx:eval(vim.trim(expr), where)
      pos = close + 2
    else
      value = ctx:lookup(name)
      if value == nil then
        local hint = ctx.env_unselected and " (no environment selected: :Wire env)" or ""
        error(("%s: unresolved {{%s}}%s"):format(where, name, hint), 0)
      end
      pos = pe + 1
    end
    if opts.json and st.in_str then
      value = vim.json.encode(value):sub(2, -2)
    end
    out[#out + 1] = value
  end
  out[#out + 1] = text:sub(pos)
  return table.concat(out)
end

function M.merge_headers(defaults, own)
  local out, index = {}, {}
  local function put(name, value)
    local k = name:lower()
    if index[k] then
      out[index[k]] = { name = name, value = value }
    else
      out[#out + 1] = { name = name, value = value }
      index[k] = #out
    end
  end
  local names = vim.tbl_keys(defaults)
  table.sort(names)
  for _, name in ipairs(names) do
    put(name, defaults[name])
  end
  for _, h in ipairs(own) do
    put(h.name, h.value)
  end
  return out
end

function M.is_json(content_type, body)
  local mt = content_type and vim.trim(content_type:match("^[^;]*")):lower() or ""
  if mt == "" then
    return body:match("^%s*[%[{]") ~= nil
  end
  return mt == "application/json" or mt:match("^[^/]+/[^/]+%+json$") ~= nil
end

return M
