local state = require'notes.state'
local database = require'notes.database'
local utils = require'notes.utils'

local prompt = {}
local keymap_fns = {}
local leader_fns = {}

local function close_prompt ()
  if vim.api.nvim_buf_is_valid(state.prompt.buffer) then
    vim.api.nvim_buf_delete(state.prompt.buffer, { force = true })
    vim.cmd'stopinsert'
  end
end

local function write_to_topic (path, index)
  if not path then
    path = state.config.inbox_note
  end
  if not index then
    index = 1
  end
  local lines = vim.api.nvim_buf_get_lines(state.prompt.buffer, 0, -1, false)
  state.undo.prompt_content = {}
  for _, line in ipairs(lines) do
    table.insert(state.undo.prompt_content, line)
  end
  local content = table.concat(lines, '\n')
  local normalized_content = utils.text.normalize(content)
  utils.file.insert_text(normalized_content, path, index)
  state.last_note = path
  state.last_heading_index = index
  close_prompt()
end

local function create_new_topic ()
  local lines = vim.api.nvim_buf_get_lines(state.prompt.buffer, 0, -1, false)
  local id = utils.text.create_note_id()
  local timestamp = utils.text.create_iso_8601_datetime()
  local first_line = lines[1]
  local title_text = first_line:match'^# (.+)' or first_line
  if title_text:match'^%s*$' then
    vim.notify('Cannot create topic with empty title', vim.log.levels.WARN)
    return
  end
  local sanitized_title = title_text:gsub('[^%w%s]', '')
    :match'^%s*(.-)%s*$'
    :gsub('%s+', '-')
    :lower()
  local filename = id .. '-' .. sanitized_title .. '.md'
  local notes_dir = vim.fn.expand(state.config.notes_dir)
  if not notes_dir:match'/$' then
    notes_dir = notes_dir .. '/'
  end
  local file_path = notes_dir .. filename
  local content_lines = {
    '---',
    'id: ' .. id,
    'created: ' .. timestamp,
    'updated: ' .. timestamp,
    'tags: []',
    '---',
    ''
  }
  for _, line in ipairs(lines) do
    table.insert(content_lines, line)
  end
  content_lines = utils.text.format_text(content_lines)
  local file = io.open(file_path, 'w')
  if not file then
    vim.notify('Failed to create new topic file: ' .. file_path, vim.log.levels.ERROR)
    return
  end
  file:write(table.concat(content_lines, '\n') .. '\n')
  file:close()
  database.update_note(file_path)
  state.last_note = file_path
  state.last_heading_index = 1
  close_prompt()
end

local function reset_leader ()
  if state.prompt.leader_active then
    state.prompt.leader_active = false
    local modes = { 'n', 'i', 'v' }
    for _, mode in ipairs(modes) do
      for _, key in ipairs{ 'h', 't', 'd', 'l', 's', 'f', 'i', 'm' } do
        pcall(vim.keymap.del, mode, key, { buffer = state.prompt.buffer })
      end
      for i = 0, 9 do
        pcall(vim.keymap.del, mode, '' .. i, { buffer = state.prompt.buffer })
      end
    end
  end
end

local function set_prompt_type (type)
  if not type then
    return
  end
  if type == 'note' then
    vim.b.note_type = 'note'
    vim.api.nvim_win_set_config(state.prompt.window, { title = 'Note' })
    vim.wo.winhl = 'FloatBorder:@lsp.type.property'
    vim.bo.filetype = 'markdown'
  elseif type == 'topic' then
    vim.b.note_type = 'topic'
    vim.api.nvim_win_set_config(state.prompt.window, { title = 'Topic' })
    vim.wo.winhl = 'FloatBorder:Keyword'
    vim.bo.filetype = 'markdown'
  elseif type == 'todo' then
    vim.b.note_type = 'todo'
    vim.api.nvim_win_set_config(state.prompt.window, { title = 'Todo' })
    vim.wo.winhl = 'FloatBorder:Number'
    vim.bo.filetype = 'markdown'
  end
end

local function determine_prompt_height ()
  local max = vim.o.lines - 10
  local height = vim.fn.line'$'
  if height >= max then
    return max
  end
  local saved_pos = vim.fn.winsaveview()
  local total_virtual_lines = 0
  local wrap_width = vim.api.nvim_win_get_width(0)
  for lnum = 1, vim.fn.line'$' do
    local line_text = vim.fn.getline(lnum)
    local line_width = vim.fn.strdisplaywidth(line_text)
    total_virtual_lines = total_virtual_lines + math.max(1, math.ceil(line_width / wrap_width))
  end
  vim.fn.winrestview(saved_pos)
  return total_virtual_lines
end

local function determine_prompt_width ()
  return math.min(vim.o.columns - 10, 60)
end

local function on_prompt_change ()
  local height = math.min(vim.o.lines - 10, determine_prompt_height())
  vim.api.nvim_win_set_config(state.prompt.window, {
    relative = 'editor',
    height = height,
    row = math.max(1, (math.floor((vim.o.lines - height) / 2) - 2)),
    col = math.floor((vim.o.columns - determine_prompt_width()) / 2),
  })
  local topline = math.max(
    math.min(
      vim.fn.line'.' - math.floor(vim.api.nvim_win_get_height(0) / 2),
      vim.fn.line'$' - vim.api.nvim_win_get_height(0) + 1
    ),
    1
  )
  vim.fn.winrestview{ topline = topline }
  local first_line = vim.api.nvim_buf_get_lines(state.prompt.buffer, 0, 1, false)[1] or ''
  if first_line:match'^# ' then
    set_prompt_type'topic'
  elseif vim.b.note_type == 'topic' and not first_line:match'^# ' then
    set_prompt_type'note'
  end
  if state.prompt.leader_active then
    reset_leader()
  end
end

local function setup_keymaps ()
  local options = { buffer = state.prompt.buffer, noremap = true, silent = true }
  vim.keymap.set({ 'n' }, '<esc>', keymap_fns.close_if_empty, options)
  vim.keymap.set({ 'n', 'x', 'i' }, '<c-s>', keymap_fns.quicksave, options)
  vim.keymap.set({ 'n', 'x', 'i' }, '<c-c>', keymap_fns.close, options)
  vim.keymap.set({ 'n', 'x', 'i' }, '<c-k>', keymap_fns.activate_leader, options)
end

function leader_fns.toggle_topic ()
  local cursor_pos = vim.api.nvim_win_get_cursor(0)
  local lines = vim.api.nvim_buf_get_lines(state.prompt.buffer, 0, -1, false)
  if #lines > 0 then
    if lines[1]:match'^# ' then
      lines[1] = lines[1]:gsub('^# ', '')
    else
      lines[1] = '# ' .. lines[1]
    end
    vim.api.nvim_buf_set_lines(state.prompt.buffer, 0, -1, false, lines)
    if cursor_pos[1] == 1 then
      if lines[1]:match'^# ' then
        cursor_pos[2] = math.min(#lines[1], cursor_pos[2] + 2)
      else
        cursor_pos[2] = math.max(0, cursor_pos[2] - 2)
      end
    end
    vim.api.nvim_win_set_cursor(0, cursor_pos)
  end
  reset_leader()
end

function leader_fns.save_to_bookmark (number)
  if vim.b.note_type ~= 'note' then
    return
  end
  database.with_bookmark(number, function (_, note, heading)
    local notes_dir = vim.fn.expand(state.config.notes_dir)
    if not notes_dir:match'/$' then
      notes_dir = notes_dir .. '/'
    end
    local full_path = notes_dir .. note.filename
    write_to_topic(full_path, heading.index)
  end)
  reset_leader()
end

function leader_fns.save_to_inbox ()
  if vim.b.note_type ~= 'note' then
    return
  end
  local notes_dir = vim.fn.expand(state.config.notes_dir)
  if not notes_dir:match'/$' then
    notes_dir = notes_dir .. '/'
  end
  local inbox = notes_dir .. state.config.inbox_note
  local outline = utils.file.get_outline(inbox)
  write_to_topic(notes_dir .. state.config.inbox_note, #outline.headings)
  reset_leader()
end

function leader_fns.save ()
  if vim.b.note_type ~= 'note' then
    return
  end
  database.find_note(function (selection)
    database.find_heading(selection.path, function (heading_selection)
      write_to_topic(selection.path, heading_selection.heading.index)
    end)
  end)
  reset_leader()
end

function keymap_fns.close_if_empty ()
  local lines = vim.api.nvim_buf_get_lines(state.prompt.buffer, 0, -1, false)
  local content = table.concat(lines, '\n'):match'^%s*(.-)%s*$'
  if content == nil or content == '' then
    close_prompt()
  end
end

function keymap_fns.close ()
  local lines = vim.api.nvim_buf_get_lines(state.prompt.buffer, 0, -1, false)
  local content = table.concat(lines, '\n')
  vim.fn.setreg('+', content)
  vim.fn.setreg('', content)
  close_prompt()
end

function keymap_fns.quicksave ()
  if vim.b.note_type == 'topic' then
    create_new_topic()
  elseif vim.b.note_type == 'note' then
    write_to_topic(utils.file.get_last_note(), state.last_heading_index)
  end
end

function keymap_fns.activate_leader ()
  if state.prompt.leader_active then
    reset_leader()
    return
  end
  state.prompt.leader_active = true
  local options = { buffer = state.prompt.buffer, noremap = true, silent = true }
  -- vim.keymap.set({ 'n', 'x', 'i' }, 'h', function () print'heading toggle'; reset_leader() end, options)
  -- vim.keymap.set({ 'n', 'x', 'i' }, 'd', function () print'todo toggle'; reset_leader() end, options)
  -- vim.keymap.set({ 'n', 'x', 'i' }, 'l', function () print'list toggle'; reset_leader() end, options)
  -- vim.keymap.set({ 'n', 'x', 'i' }, 'm', function () print'Edit metadata'; reset_leader() end, options)
  vim.keymap.set({ 'n', 'x', 'i' }, 't', function () leader_fns.toggle_topic() end, options)
  vim.keymap.set({ 'n', 'x', 'i' }, 's', function () leader_fns.save() end, options)
  if vim.b.note_type == 'note' then
    vim.keymap.set({ 'n', 'x', 'i' }, 'i', function () leader_fns.save_to_inbox() end, options)
    for i = 0, 9 do
      vim.keymap.set({ 'n', 'x', 'i' }, '' .. i, function () leader_fns.save_to_bookmark(i) end, options)
    end
  elseif vim.b.note_type == 'topic' then
  end
end

function prompt.open ()
  local width = determine_prompt_width()
  local row = math.max(1, (math.floor((vim.o.lines - 1) / 2) - 2))
  local col = math.floor((vim.o.columns - width) / 2)
  state.prompt.buffer = vim.api.nvim_create_buf(false, true)
  state.prompt.window = vim.api.nvim_open_win(state.prompt.buffer, true, {
    relative = 'editor',
    width = width,
    height = 1,
    row = row,
    col = col,
    style = 'minimal',
    border = 'rounded',
  })
  vim.b.is_notes_prompt = true
  vim.bo.buftype = 'nofile'
  vim.bo.buflisted = false
  vim.opt.wrap = true
  vim.opt.linebreak = true
  setup_keymaps()
  set_prompt_type'note'
  vim.api.nvim_create_autocmd({ 'TextChanged', 'TextChangedI' }, {
    buffer = state.prompt.buffer,
    callback = on_prompt_change,
  })
  vim.api.nvim_create_autocmd({ 'VimResized' }, {
    buffer = state.prompt.buffer,
    callback = on_prompt_change,
  })
  if vim.fn.mode(1):sub(1, 1) ~= 'i' then
    vim.api.nvim_feedkeys('i', 'n', true)
  end
end

return prompt

