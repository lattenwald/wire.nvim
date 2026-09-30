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
  if type(v) == "string" and #v >= MIN and not values[v] then
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

local function replace_plain(s, needle)
  local out, pos = {}, 1
  while true do
    local a, b = s:find(needle, pos, true)
    if not a then
      break
    end
    out[#out + 1] = s:sub(pos, a - 1)
    out[#out + 1] = MASK
    pos = b + 1
  end
  out[#out + 1] = s:sub(pos)
  return table.concat(out)
end

function M.apply(s)
  if not sorted then
    sorted = vim.tbl_keys(values)
    table.sort(sorted, function(a, b)
      return #a > #b
    end)
  end
  for _, v in ipairs(sorted) do
    s = replace_plain(s, v)
  end
  return s
end

return M
