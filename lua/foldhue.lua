local a = vim.api
local ts = vim.treesitter
local ns = vim.api.nvim_create_namespace('foldhue')

local faded_groups = { Folded = 'Folded' }
local default_highlight = 'Folded'
local foldhue = { default_highlight = 'Folded', _enable_default = true, langs = {} }

local function fold_range(winid, lnum)
  lnum = lnum + 1
  return a.nvim_win_call(winid, function()
    local fo = vim.fn.foldclosed(lnum)
    if fo == lnum then
      return { fo - 1, vim.fn.foldclosedend(lnum) - 1 }
    end
  end)
end

local function mark_window(winid, bufnr, top, bot, opts)
  local ft = a.nvim_buf_get_option(bufnr, 'filetype')
  local has_parser = pcall(ts.get_parser, bufnr)
  if not has_parser or not ft or (not foldhue.langs[ft] and not foldhue._enable_default) then
    return
  end
  local success, text, range
  for lnum = top, bot do
    range = fold_range(winid, lnum)
    if range then
      -- node = root:named_descendant_for_range(range[1], 0, range[2], 1)
      success, text = pcall(foldhue.langs[ft] or foldhue.from_captures, bufnr, lnum)
      if success and text then
        opts.virt_text = text
        pcall(a.nvim_buf_set_extmark, bufnr, ns, lnum, 0, opts)
      elseif not success then
        vim.notify_once(('foldhue calculation for buf:%s, ft:"%s" failed.'):format(bufnr, ft))
      end
    end
  end
end

local function on_win(_, winid, bufnr, top, bot)
  local opts = { ephemeral = true, virt_text_pos = 'overlay', hl_mode = 'combine' }
  mark_window(winid, bufnr, top, bot, opts)
end

local bufs = {}
local function focus_lost()
  local opts = { virt_text_pos = 'overlay', hl_mode = 'combine' }
  mark_window(vim.fn.win_getid(), 0, vim.fn.line 'w0', vim.fn.line 'w$', opts)
  bufs[#bufs+1] = a.nvim_get_current_buf()
end

local function focus_gained()
  for _, b in ipairs(bufs) do
    a.nvim_buf_clear_namespace(b, ns, 0, -1)
  end
  bufs = {}
end

function foldhue.fade(hl)
  local rgb = string.format('%0X', hl.foreground)
  local r, g, b = rgb:sub(1, 2), rgb:sub(3, 4), rgb:sub(5, 6)
  local f = (1 - 0.33)
  r, g, b = vim.fn.str2nr(r, 16) * f, vim.fn.str2nr(g, 16) * f, vim.fn.str2nr(b, 16) * f
  hl.foreground = vim.fn.printf('#%x%x%x', math.floor(r + 0.5), math.floor(g + 0.5), math.floor(b + 0.5))
  return hl
end

function foldhue.clear_fade_cache()
  for k in pairs(faded_groups) do
    faded_groups[k] = nil
  end
  faded_groups[default_highlight] = default_highlight
end
foldhue.clear_fade_cache()

setmetatable(faded_groups, {
  __index = function(self, name)
    local exists, hl = pcall(a.nvim_get_hl_by_name, name, true)

    if not exists or hl[true] then
      -- seems to be hl[true] when the group is ':hi-clear'ed
      return faded_groups[default_highlight]
    end

    self[name] = 'Folded' .. name
    a.nvim_set_hl(0, self[name], foldhue.fade(hl))
    return self[name]
  end,
})

local identity = setmetatable({}, { __index = function(_, name) return name end })

function foldhue.from_captures(buf, lnum, opts)
  local captures = {}
  opts = opts or {}
  local line = a.nvim_buf_get_lines(buf, lnum, lnum+1, false)[1]
  -- opts: skip_fade and range
  local range = opts.range or { 1, #line }
  local fade_tbl = opts.skip_fade and identity or faded_groups

  local last = ""
  local hl
  for i=range[1],range[2] do
    hl = vim.treesitter.get_captures_at_pos(buf, lnum, i-1)
    -- {} if none, { low priority, high priority } Grab the last.
    if #hl == 0 then
      hl = { capture = default_highlight }
    else
      hl = hl[#hl]
      hl.capture = '@' .. hl.capture
    end

    -- add up characters
    if hl.capture ~= last then
      captures[#captures+1] = { range = {i, i}, group = hl.capture }
      last = hl.capture
    elseif hl then
      captures[#captures].range[2] = captures[#captures].range[2] + 1
    end
  end

  -- put into the form for extmarks
  local highlights = {}
  for i, capture in ipairs(captures) do
    highlights[i] = {
      line:sub(unpack(capture.range)),
      fade_tbl[capture.group]
    }
  end

  return highlights
end

function foldhue.enable()
  if foldhue._enabled then
    return
  end
  a.nvim_set_decoration_provider(ns, { on_win = on_win })
  foldhue._enabled = true

  a.nvim_create_augroup('foldhue', { clear = true })
  a.nvim_create_autocmd('FocusLost', {
    pattern = '*',
    group = 'foldhue',
    desc = 'Persistent highlights',
    callback = focus_lost
  })
  a.nvim_create_autocmd({ 'FocusGained', 'BufLeave' }, {
    pattern = '*',
    group = 'foldhue',
    desc = 'Remove persistent highlights',
    callback = focus_gained
  })
end

function foldhue.disable()
  a.nvim_set_decoration_provider(ns, {})
  foldhue._enabled = nil
  a.nvim_del_augroup_by_name('foldhue')
  focus_gained()
end

function foldhue.toggle()
  if foldhue._enabled then
    foldhue.disable()
  else
    foldhue.enable()
  end
end

return foldhue
