local M = {}

local function is_blank(l)
  return l:match("^%s*$") ~= nil
end

local function is_comment(l)
  return l:match("^%s*#") ~= nil or l:match("^%s*//") ~= nil
end

M.is_comment = is_comment

local function parse_var(l)
  local name, value = l:match("^@([%w_.$-]+)%s*=%s*(.-)%s*$")
  if name then
    return { name = name, value = value }
  end
end

local function parse_request_line(l)
  return l:match("^(%u+)%s+(%S.-)%s*$")
end

local function parse_header(l)
  return l:match("^([%w!#$%%&'*+.^_`|~-]+)%s*:%s*(.-)%s*$")
end

local function looks_like_request(l)
  return l:match("^%u+%s+https?://") ~= nil or l:match("^%u+%s+{{") ~= nil
end

local function add_error(owner, line, msg)
  table.insert(owner.errors, { line = line, msg = msg })
end

local function read_script(lines, i, to)
  local rest = vim.trim(lines[i]:sub(2))
  if rest:sub(1, 2) ~= "{%" then
    return { kind = "file", path = rest, line = i, last = i }, i + 1
  end
  local first = rest:sub(3)
  if vim.trim(first):sub(-2) == "%}" then
    return { kind = "inline", code = vim.trim(first):sub(1, -3), line = i, last = i }, i + 1
  end
  local code = { first }
  for j = i + 1, to do
    if vim.trim(lines[j]):sub(-2) == "%}" then
      code[#code + 1] = (lines[j]:gsub("%%}%s*$", ""))
      return { kind = "inline", code = table.concat(code, "\n"), line = i, last = j }, j + 1
    end
    code[#code + 1] = lines[j]
  end
  return nil, nil, "unclosed {% block"
end

local function parse_lead(lines, i, to, owner, scripts)
  while i <= to do
    local l = lines[i]
    local var = parse_var(l)
    if is_blank(l) or is_comment(l) then
      i = i + 1
    elseif var then
      var.line = i
      table.insert(owner.vars, var)
      i = i + 1
    elseif l:sub(1, 1) == "<" then
      local s, nxt, err = read_script(lines, i, to)
      if not s then
        return add_error(owner, i, err)
      end
      table.insert(scripts, s)
      i = nxt
    else
      return i
    end
  end
end

local function parse_preamble(lines, to, pre)
  local i = parse_lead(lines, 1, to, pre, pre.imports)
  while i do
    local msg = parse_request_line(lines[i]) and "put ### before the request" or "unexpected line in the preamble"
    add_error(pre, i, msg)
    i = parse_lead(lines, i + 1, to, pre, pre.imports)
  end
end

local function parse_head(lines, from, to, sec)
  local i = parse_lead(lines, from, to, sec, sec.pre)
  if not i then
    return
  end
  local l = lines[i]
  if l:sub(1, 1) == ">" then
    return add_error(sec, i, "post script before the request line")
  end
  local method, url = parse_request_line(l)
  if not method then
    return add_error(sec, i, "expected a request line")
  end
  sec.request = { method = method, url = url, line = i, headers = {} }
  return i + 1
end

local function parse_section(lines, from, to, sec)
  local i = parse_head(lines, from, to, sec)
  if not i then
    return
  end
  local req = sec.request
  while i <= to and lines[i]:match("^%s+%S") and not is_comment(lines[i]) do
    req.url = req.url .. vim.trim(lines[i])
    i = i + 1
  end
  req.last = i - 1
  req.url = req.url:gsub("%s+HTTP/[%d.]+$", "")

  local state, body = "headers", {}
  while i <= to do
    local l = lines[i]
    if state == "headers" then
      if is_blank(l) then
        state = "body"
        req.body_line = i + 1
      elseif not is_comment(l) then
        local name, value = parse_header(l)
        if not name then
          return add_error(sec, i, "expected a header or a blank line")
        end
        table.insert(req.headers, { name = name, value = value, line = i })
      end
      i = i + 1
    elseif state == "body" then
      if l:match("^>%s") or l:match("^>{%%") then
        state = "post"
      elseif looks_like_request(l) then
        return add_error(sec, i, "put ### before the request")
      else
        body[#body + 1] = l
        i = i + 1
      end
    elseif is_blank(l) or is_comment(l) then
      i = i + 1
    elseif l:sub(1, 1) == ">" then
      local s, nxt, err = read_script(lines, i, to)
      if not s then
        return add_error(sec, i, err)
      end
      table.insert(sec.post, s)
      i = nxt
    else
      return add_error(sec, i, "unexpected line after the post scripts")
    end
  end

  while #body > 0 and (is_blank(body[#body]) or is_comment(body[#body])) do
    body[#body] = nil
  end
  for _, l in ipairs(body) do
    if not is_blank(l) then
      if l:match("^<%s") then
        return add_error(sec, req.line, "external body files are not supported")
      end
      break
    end
  end
  if #body > 0 then
    req.body = table.concat(body, "\n")
  end
end

-- sections share no parse state; the highlighter parses each on its own
function M.section_starts(lines)
  local starts = {}
  for i, l in ipairs(lines) do
    if l:sub(1, 3) == "###" then
      starts[#starts + 1] = i
    end
  end
  return starts
end

function M.parse(lines)
  local starts = M.section_starts(lines)
  local doc = { preamble = { vars = {}, imports = {}, errors = {} }, sections = {} }
  parse_preamble(lines, (starts[1] or #lines + 1) - 1, doc.preamble)
  for k, s in ipairs(starts) do
    local last = (starts[k + 1] or #lines + 1) - 1
    local sec = {
      name = vim.trim((lines[s]:gsub("^#+", ""))),
      line = s,
      last = last,
      vars = {},
      pre = {},
      post = {},
      errors = {},
    }
    parse_section(lines, s + 1, last, sec)
    if sec.name == "" and sec.request then
      sec.name = sec.request.method .. " " .. sec.request.url
    end
    doc.sections[#doc.sections + 1] = sec
  end
  return doc
end

function M.vars_map(list)
  local m = {}
  for _, v in ipairs(list) do
    m[v.name] = v.value
  end
  return m
end

function M.section_at(doc, row)
  for _, sec in ipairs(doc.sections) do
    if row >= sec.line and row <= sec.last then
      return sec
    end
  end
end

return M
