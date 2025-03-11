local note = {}
local state = require'notes.state'
local utils = require'notes.utils'
local ns_id = nil

local function get_current_heading_index ()
  local cursor_line = vim.api.nvim_win_get_cursor(0)[1]
  local file_path = vim.fn.expand'%:p'
  if not utils.file.is_markdown(file_path) then
    return 1
  end
  local outline = utils.file.get_outline(file_path)
  if #outline.headings == 0 then
    return 1
  end
  local current_index = 1
  for i, heading in ipairs(outline.headings) do
    if cursor_line >= heading.start_row then
      current_index = i
    else
      break
    end
  end
  return current_index
end

local function update_current_heading ()
  if vim.bo.filetype ~= 'markdown' then
    return
  end
  local file_path = vim.fn.expand'%:p'
  local notes_dir = vim.fn.expand(state.config.notes_dir)
  if not notes_dir:match'/$' then
    notes_dir = notes_dir .. '/'
  end
  if not vim.startswith(file_path, notes_dir) then
    return
  end
  state.last_heading_index = get_current_heading_index()
end

local function format_timestamp (iso_timestamp)
  if not iso_timestamp then return nil end
  local year, month, day, hour, min, sec =
    iso_timestamp:match'(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)Z'
  if not year then return nil end
  year = tonumber(year) or 0
  month = tonumber(month) or 0
  day = tonumber(day) or 0
  hour = tonumber(hour) or 0
  min = tonumber(min) or 0
  sec = tonumber(sec) or 0
  local utc_time = os.time{
    year = year,
    month = month,
    day = day,
    hour = hour,
    min = min,
    sec = sec,
  }
  local now = os.time()
  local local_offset = os.difftime(now, os.time(os.date('!*t', now)))
  local local_time = os.date('*t', utc_time + local_offset)
  return string.format('%d-%02d-%02d @ %02d:%02d:%02d',
    local_time.year,
    local_time.month,
    local_time.day,
    local_time.hour,
    local_time.min,
    local_time.sec
  )
end

local function format_tags (tags_str)
  if not tags_str then return nil end
  local tags = tags_str:match'^%[(.*)%]$'
  if not tags then return nil end
  local tag_list = {}
  for tag in tags:gmatch'[^,]+' do
    tag = tag:match"^%s*\'?(.-)'?%s*$" or tag:match'^%s*"?(.-)"?%s*$'
    if tag and tag ~= '' then
      table.insert(tag_list, tag)
    end
  end
  return tag_list
end

local function update_timestamps ()
  local bufnr = vim.api.nvim_get_current_buf()
  local cursor_line = vim.api.nvim_win_get_cursor(0)[1] - 1
  local mode = vim.api.nvim_get_mode().mode
  local in_visual = mode:match'^[vV\22]'
  vim.api.nvim_buf_clear_namespace(bufnr, ns_id, 0, -1)
  if vim.bo[bufnr].filetype ~= 'markdown' then
    return
  end
  if in_visual then
    return
  end
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local in_frontmatter = false
  for i, line in ipairs(lines) do
    if line:match'^%-%-%-$' then
      if not in_frontmatter then
        in_frontmatter = true
      else
        break
      end
    elseif in_frontmatter then
      local key, value = line:match'^(created%s*:%s*)(.*)'
      if not key then
        key, value = line:match'^(updated%s*:%s*)(.*)'
      end
      if key and value then
        local formatted = format_timestamp(value)
        if formatted and (i - 1) ~= cursor_line then
          local start_col = #key
          local end_col = #line
          local date, time = formatted:match'(.+) @ (.+)'
          vim.api.nvim_buf_set_extmark(bufnr, ns_id, i - 1, start_col, {
            end_col = end_col,
            hl_group = '@string',
            virt_text_pos = 'overlay',
            virt_text = {
              { date, '@string' },
              { ' @ ', '@function' },
              { time, '@string' },
            },
            conceal = '',
            priority = 100,
          })
        end
      else
        key, value = line:match'^(tags%s*:%s*)(.*)'
        if key and value then
          local tags = format_tags(value)
          if tags and (i - 1) ~= cursor_line then
            local start_col = #key
            local end_col = #line
            local virt_text = {}
            for idx, tag in ipairs(tags) do
              table.insert(virt_text, { tag, '@string' })
              if idx < #tags then
                table.insert(virt_text, { ', ', '@function' })
              end
            end
            if ns_id ~= nil then
              vim.api.nvim_buf_set_extmark(bufnr, ns_id, i - 1, start_col, {
                end_col = end_col,
                hl_group = '@string',
                virt_text_pos = 'overlay',
                virt_text = virt_text,
                conceal = '',
                priority = 100
              })
            end
          end
        end
      end
    end
  end
end

function note.init ()
  if not ns_id then
    ns_id = vim.api.nvim_create_namespace'notes_timestamps'
  end
  local group = vim.api.nvim_create_augroup('NotesTimestamps', { clear = true })
  vim.api.nvim_create_autocmd({ 'BufEnter', 'BufWritePost' }, {
    group = group,
    pattern = '*.md',
    callback = update_timestamps
  })
  vim.api.nvim_create_autocmd({ 'CursorMoved', 'CursorMovedI' }, {
    group = group,
    pattern = '*.md',
    callback = update_timestamps
  })
  vim.api.nvim_create_autocmd('ModeChanged', {
    group = group,
    pattern = '*',
    callback = update_timestamps
  })
  local heading_group = vim.api.nvim_create_augroup('NotesHeadingTracker', { clear = true })
  vim.api.nvim_create_autocmd({ 'BufEnter', 'CursorMoved', 'CursorMovedI', 'TextChanged', 'TextChangedI' }, {
    group = heading_group,
    pattern = '*.md',
    callback = update_current_heading
  })
end

return note

