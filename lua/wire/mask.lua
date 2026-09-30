local M = {}

local MIN = 4
local MASK = "••••"
local AUTO = {
  authorization = true,
  ["proxy-authorization"] = true,
  cookie = true,
  ["x-api-key"] = true,
  ["api-key"] = true,
}

local values, sorted = {}, nil

local function add(v)
  if not values[v] then
    values[v] = true
    sorted = nil
  end
end

function M.register(v)
  if type(v) ~= "string" or #v < MIN then
    return
  end
  add(v)
  local ok, encoded = pcall(vim.json.encode, v)
  if ok then
    add(encoded:sub(2, -2))
  end
end

function M.register_header(name, value)
  local n = name:lower()
  if not AUTO[n] then
    return
  end
  M.register(value)
  if n == "authorization" or n == "proxy-authorization" then
    M.register(value:match("^%S+%s+(.+)$"))
  end
end

function M.apply(s)
  if not sorted then
    sorted = vim.tbl_keys(values)
    table.sort(sorted, function(a, b)
      return #a > #b
    end)
  end
  for _, v in ipairs(sorted) do
    if s:find(v, 1, true) then
      s = s:gsub(vim.pesc(v), MASK)
    end
  end
  return s
end

return M
