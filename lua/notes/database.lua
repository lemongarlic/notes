local sqlite = require'sqlite'
local pickers = require'telescope.pickers'
local finders = require'telescope.finders'
local actions = require'telescope.actions'
local action_state = require'telescope.actions.state'
local previewers = require'telescope.previewers'
local config = require'telescope.config'.values
local utils = require'notes.utils'
local state = require'notes.state'

local database = {}
local db_utils = {}

local is_updating_frontmatter = false
local is_updating_db = false

local tables = {
  notes = sqlite.tbl('notes', {
    id = { type = 'text', primary = true },
    filename = { type = 'text', required = true, unique = true },
    title = { type = 'text' },
    hash = { type = 'text', required = true },
    created = { type = 'text', required = true },
    updated = { type = 'text', required = true },
  }),
  headings = sqlite.tbl('headings', {
    id = { type = 'integer', primary = true, autoincrement = true },
    note_id = { reference = 'notes.id', required = true, on_delete = 'cascade' },
    text = { type = 'text', required = true },
    level = { type = 'integer', required = true },
    line = { type = 'integer', required = true },
  }),
  bookmarks = sqlite.tbl('bookmarks', {
    number = { type = 'integer', primary = true, autoincrement = true },
    note_id = { reference = 'notes.id', required = true, on_delete = 'cascade' },
    heading_index = { type = 'integer', required = true },
    heading_text = { type = 'text', required = true },
  }),
}

function db_utils.get_markdown_files (dir)
  local expanded_dir = vim.fn.expand(dir)
  local files = vim.fn.glob(expanded_dir .. '/**/*.md', false, true)
  return vim.tbl_filter(function (file)
    local basename = vim.fn.fnamemodify(file, ':t:r')
    return not vim.tbl_contains(state.special_notes, basename)
  end, files)
end

function db_utils.calculate_file_hash (file_path)
  local file = io.open(file_path, 'rb')
  if not file then return nil end
  local content = file:read'*all'
  file:close()
  return vim.fn.sha256(content)
end

function db_utils.get_file_mtime_iso8601 (file_path)
  local stat = vim.loop.fs_stat(file_path)
  if not stat then return nil end
  local mtime_sec = math.floor(stat.mtime.sec)
  local datetime = os.date('!%Y-%m-%dT%H:%M:%S', mtime_sec)
  local ms = string.format('%03d', math.floor(stat.mtime.nsec / 1000000))
  return datetime .. '.' .. ms .. 'Z'
end

function db_utils.get_full_path (filename)
  return vim.fn.expand(state.config.notes_dir) .. '/' .. filename
end

function db_utils.clean_deleted_notes ()
  local notes = tables.notes:get()
  for _, note in ipairs(notes) do
    if not vim.loop.fs_stat(db_utils.get_full_path(note.filename)) then
      tables.notes:remove{ id = note.id }
    end
  end
end

function db_utils.is_special_note (filename)
  return vim.tbl_contains(state.special_notes, filename)
end

function db_utils.is_in_notes_dir (file_path)
  local notes_dir = vim.fn.expand(state.config.notes_dir)
  local abs_file_path = vim.fn.expand(file_path)
  if not notes_dir:match'/$' then
    notes_dir = notes_dir .. '/'
  end
  return vim.startswith(abs_file_path, notes_dir)
end

function db_utils.update_frontmatter (file_path, force_update)
  if is_updating_frontmatter then
    return
  end
  if not db_utils.is_in_notes_dir(file_path) then
    return
  end
  local current_buffer = vim.fn.expand'%:p'
  if not file_path or file_path == '' then
    file_path = current_buffer
  else
    file_path = vim.fn.expand(file_path)
  end
  if not utils.file.is_markdown(file_path) then
    return
  end
  local filename = vim.fn.fnamemodify(file_path, ':t')
  local is_special = db_utils.is_special_note(filename)
  local bufnr = vim.fn.bufnr(file_path)
  if bufnr ~= -1 and vim.bo[bufnr].modified then
    vim.api.nvim_buf_call(bufnr, function ()
      vim.cmd'silent! w!'
    end)
  end
  local outline = utils.file.get_outline(file_path)
  local metadata = outline.metadata or {}
  local existing_note = nil
  if not is_special and metadata.id then
    existing_note = tables.notes:where({ id = metadata.id })
  end
  local current_created = metadata.created
  local current_updated = metadata.updated
  local db_created = existing_note and existing_note.created
  local db_updated = existing_note and existing_note.updated
  if not force_update then
    if is_special then
      if current_created and current_updated then
        return {
          created = current_created,
          updated = current_updated,
        }
      end
    else
      if metadata.id and current_created and current_updated and metadata.tags then
        if (not existing_note) or (current_created == db_created and current_updated == db_updated) then
          return {
            id = metadata.id,
            created = current_created,
            updated = current_updated,
          }
        end
      end
    end
  end
  local defaults = {
    id = utils.text.create_note_id(),
    created = utils.text.create_iso_8601_datetime(),
    updated = utils.text.create_iso_8601_datetime(),
    tags = '[]',
  }
  local id = is_special and nil or (metadata.id or defaults.id)
  local created = current_created or db_created or defaults.created
  local updated
  if force_update then
    updated = defaults.updated
  else
    updated = current_updated or db_updated or defaults.updated
  end
  local tags = is_special and nil or (metadata.tags or defaults.tags)
  if (is_special and current_created == created and current_updated == updated) or
     (not is_special and metadata.id == id and current_created == created and current_updated == updated and metadata.tags == tags) then
    return {
      id = id,
      created = created,
      updated = updated,
    }
  end
  local cursor_pos = nil
  local window_view = nil
  local mode = nil
  local is_current_buffer = current_buffer == file_path
  if is_current_buffer then
    cursor_pos = vim.api.nvim_win_get_cursor(0)
    window_view = vim.fn.winsaveview()
    mode = vim.api.nvim_get_mode().mode
  end
  local id_line = is_special and nil or ('id: ' .. id)
  local created_line = 'created: ' .. created
  local updated_line = 'updated: ' .. updated
  local tags_line = is_special and nil or ('tags: ' .. tags)
  local lines = {}
  if bufnr ~= -1 then
    lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  else
    local f = io.open(file_path, 'r')
    if not f then
      return
    end
    for line in f:lines() do
      table.insert(lines, line)
    end
    f:close()
  end
  local frontmatter_start, frontmatter_end = nil, nil
  for i = 1, #lines do
    if lines[i]:match'^%-%-%-$' then
      if not frontmatter_start then
        frontmatter_start = i
      elseif not frontmatter_end then
        frontmatter_end = i
        break
      end
    end
  end
  if not frontmatter_start or not frontmatter_end then
    lines = {
      '---',
      id_line,
      created_line,
      updated_line,
      tags_line,
      '---',
      '',
      unpack(lines),
    }
  else
    local new_lines = {}
    for i = 1, frontmatter_start do
      table.insert(new_lines, lines[i])
    end
    if not is_special then
      table.insert(new_lines, id_line)
    end
    table.insert(new_lines, created_line)
    table.insert(new_lines, updated_line)
    if not is_special then
      table.insert(new_lines, tags_line)
    end
    for i = frontmatter_start + 1, frontmatter_end - 1 do
      local line = lines[i]
      local key = line:match'^([^:]+):'
      if key then
        key = key:match'^%s*(.-)%s*$'
        if key ~= 'id' and key ~= 'created' and key ~= 'updated' and key ~= 'tags' then
          table.insert(new_lines, line)
        end
      end
    end
    table.insert(new_lines, '---')
    for i = frontmatter_end + 1, #lines do
      table.insert(new_lines, lines[i])
    end
    lines = new_lines
  end
  if bufnr ~= -1 then
    local was_modifiable = vim.bo[bufnr].modifiable
    vim.bo[bufnr].modifiable = true
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    local old_eventignore = vim.o.eventignore
    vim.o.eventignore = 'BufWritePre,BufWritePost'
    is_updating_frontmatter = true
    vim.api.nvim_buf_call(bufnr, function ()
      vim.cmd'silent! w!'
    end)
    is_updating_frontmatter = false
    vim.o.eventignore = old_eventignore
    vim.bo[bufnr].modified = false
    vim.bo[bufnr].modifiable = was_modifiable
    if is_current_buffer then
      if cursor_pos then
        local line_count = vim.api.nvim_buf_line_count(bufnr)
        if cursor_pos[1] > line_count then
          cursor_pos[1] = line_count
        end
        local line = vim.api.nvim_buf_get_lines(bufnr, cursor_pos[1]-1, cursor_pos[1], false)[1] or ''
        if cursor_pos[2] > #line then
          cursor_pos[2] = #line
        end
        vim.api.nvim_win_set_cursor(0, cursor_pos)
      end
      if window_view then
        vim.fn.winrestview(window_view)
      end
      if mode and (mode == 'i' or mode:find'^i') then
        vim.cmd'startinsert'
      end
    end
  else
    local f = io.open(file_path, 'w')
    if not f then
      vim.notify('Failed to open file for writing: ' .. file_path, vim.log.levels.ERROR)
      return
    end
    for _, line in ipairs(lines) do
      f:write(line .. '\n')
    end
    f:close()
  end
  return {
    id = id,
    created = created,
    updated = updated
  }
end

function db_utils.clean_special_notes ()
  local notes = tables.notes:get()
  for _, note in ipairs(notes) do
    if db_utils.is_special_note(note.filename) then
      tables.notes:remove{ id = note.id }
    end
  end
end

function db_utils.check_and_update_mtime (file_path)
  if is_updating_frontmatter or is_updating_db then
    return
  end
  if not db_utils.is_in_notes_dir(file_path) then
    return
  end
  local filename = vim.fn.fnamemodify(file_path, ':t')
  local bufnr = vim.fn.bufnr(file_path)
  if bufnr ~= -1 and vim.bo[bufnr].modified then
    return
  end
  local mtime_iso = db_utils.get_file_mtime_iso8601(file_path)
  if not mtime_iso then return end
  local outline = utils.file.get_outline(file_path)
  local metadata = outline.metadata or {}
  if not metadata or not metadata.updated then
    return
  end
  if mtime_iso > metadata.updated then
    local current_hash = db_utils.calculate_file_hash(file_path)
    if not current_hash then return end
    local note_id = metadata.id
    if not note_id then return end
    local existing = note_id and tables.notes:where{ id = note_id }
    if existing and current_hash ~= existing.hash then
      vim.defer_fn(function ()
        db_utils.update_frontmatter(file_path, true)
        if not db_utils.is_special_note(filename) then
          db_utils.update_note_in_db(file_path, true)
        end
      end, 0)
    end
  end
end

function db_utils.update_note_in_db (file_path, skip_frontmatter)
  if is_updating_db then
    return
  end
  if not db_utils.is_in_notes_dir(file_path) then
    return
  end
  local filename = vim.fn.fnamemodify(file_path, ':t')
  if db_utils.is_special_note(filename) then
    if not skip_frontmatter then
      db_utils.update_frontmatter(file_path, false)
    end
    return
  end
  is_updating_db = true
  local file_hash = db_utils.calculate_file_hash(file_path)
  if not file_hash then
    is_updating_db = false
    return
  end
  local outline = utils.file.get_outline(file_path)
  local note_id = outline.metadata and outline.metadata.id
  local existing = note_id and tables.notes:where({ id = note_id })
  if existing and existing.hash == file_hash and not skip_frontmatter then
    is_updating_db = false
    return
  end
  if not skip_frontmatter then
    local frontmatter = db_utils.update_frontmatter(file_path, false)
    if not frontmatter then
      is_updating_db = false
      return
    end
  end
  note_id = outline.metadata and outline.metadata.id
  if not note_id then
    db_utils.update_frontmatter(file_path, true)
    db_utils.update_note_in_db(file_path, true)
    outline = utils.file.get_outline(file_path)
    note_id = outline.metadata and outline.metadata.id
    if not note_id then
      return
    end
  end
  local title = nil
  for _, heading in ipairs(outline.headings) do
    if heading.level == 1 then
      title = heading.text
      break
    end
  end
  local created = outline.metadata.created
  local updated = outline.metadata.updated
  if existing then
    tables.notes:update{
      where = { id = note_id },
      set = {
        filename = filename,
        title = title,
        hash = file_hash,
        created = created,
        updated = updated
      }
    }
  else
    tables.notes:insert{
      id = note_id,
      filename = filename,
      title = title,
      hash = file_hash,
      created = created,
      updated = updated
    }
  end
  tables.headings:remove{ note_id = note_id }
  for _, heading in ipairs(outline.headings) do
    tables.headings:insert{
      note_id = note_id,
      text = heading.text,
      level = heading.level,
      line = heading.start_row
    }
  end
  if not skip_frontmatter and existing and existing.hash ~= file_hash then
    db_utils.update_frontmatter(file_path, true)
  end

  is_updating_db = false
end

function database.find_note (callback)
  local headings = tables.headings:get{ where = { level = 1 } }
  local results = {}
  for _, heading in ipairs(headings) do
    local notes = tables.notes:get{ where = { id = heading.note_id } }
    local note = notes[1]
    if note then
      table.insert(results, {
        heading = heading.text,
        file = db_utils.get_full_path(note.filename),
        line = heading.line
      })
    end
  end
  table.sort(results, function (a, b) return a.heading < b.heading end)
  pickers.new({}, {
    prompt_title = 'Notes',
    finder = finders.new_table {
      results = results,
      entry_maker = function (entry)
        return {
          value = entry,
          display = entry.heading,
          ordinal = entry.heading,
          path = entry.file,
          lnum = entry.line
        }
      end
    },
    sorter = config.generic_sorter{},
    previewer = previewers.vim_buffer_cat.new{},
    attach_mappings = function (prompt_bufnr)
      actions.select_default:replace(function ()
        local selection = action_state.get_selected_entry()
        actions.close(prompt_bufnr)
        if callback then
          callback(selection)
        else
          vim.cmd('e! ' .. selection.path)
          vim.api.nvim_win_set_cursor(0, { selection.lnum, 0 })
        end
      end)
      return true
    end,
  }):find()
end

function database.find_heading (note_path, callback)
  local outline = utils.file.get_outline(note_path)
  if #outline.headings == 0 then
    vim.notify('No headings found in selected note', vim.log.levels.WARN)
    return
  end
  if #outline.headings == 1 then
    local heading = outline.headings[1]
    local entry = {
      value = heading,
      heading = heading,
      path = note_path,
      lnum = heading.start_row
    }
    if callback then
      callback(entry)
    else
      vim.cmd('e! ' .. note_path)
      vim.api.nvim_win_set_cursor(0, { heading.start_row, 0 })
    end
    return
  end
  local reversed_headings = {}
  for i = #outline.headings, 1, -1 do
    table.insert(reversed_headings, outline.headings[i])
  end
  pickers.new({}, {
    prompt_title = 'Headings',
    finder = finders.new_table {
      results = reversed_headings,
      entry_maker = function (heading)
        local prefix = string.rep('#', heading.level) .. ' '
        return {
          value = heading,
          display = prefix .. heading.text,
          ordinal = heading.text,
          heading = heading,
          path = note_path,
          lnum = heading.start_row,
        }
      end,
    },
    sorter = config.generic_sorter{},
    previewer = previewers.new_buffer_previewer{
      get_buffer_by_name = function (_, entry)
        return entry.path
      end,
      define_preview = function (self, entry)
        local bufnr = self.state.bufnr
        local winid = self.state.winid
        vim.bo[bufnr].filetype = 'markdown'
        local filename = entry.path
        local ok, content = pcall(function()
          local file = io.open(filename, 'r')
          if not file then return nil end
          local content = file:read'*all'
          file:close()
          return vim.split(content, '\n')
        end)
        if ok and content then
          vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, content)
          local line_count = vim.api.nvim_buf_line_count(bufnr)
          local target_line = math.min(entry.lnum, line_count)
          vim.schedule(function ()
            if vim.api.nvim_win_is_valid(winid) then
              vim.api.nvim_win_set_cursor(winid, {target_line, 0})
              vim.api.nvim_win_call(winid, function()
                vim.cmd'normal! zt'
              end)
            end
          end)
        end
      end,
    },
    attach_mappings = function (heading_prompt_bufnr)
      actions.select_default:replace(function ()
        local heading_selection = action_state.get_selected_entry()
        actions.close(heading_prompt_bufnr)
        if callback then
          callback(heading_selection)
        else
          vim.cmd('e! ' .. heading_selection.path)
          vim.api.nvim_win_set_cursor(0, { heading_selection.lnum, 0 })
        end
      end)
      return true
    end,
  }):find()
end

function database.update_note (path)
  if path and path ~= '' and db_utils.is_in_notes_dir(path) then
    local filename = vim.fn.fnamemodify(path, ':t')
    if not db_utils.is_special_note(filename) then
      db_utils.update_note_in_db(path, true)
    end
  end
end

function database.delete_note (path)
  if not path or path == '' or not db_utils.is_in_notes_dir(path) then
    return
  end
  local filename = vim.fn.fnamemodify(path, ':t')
  if db_utils.is_special_note(filename) then
    return
  end
  local notes = tables.notes:where{ filename = filename }
  if notes and notes.id then
    tables.notes:remove{ id = notes.id }
  end
end

function database.init ()
  if not sqlite then
    error'SQLite support is required. Please compile Neovim with SQLite support.'
  end
  sqlite{
    uri = state.config.db_file,
    notes = tables.notes,
    headings = tables.headings,
    bookmarks = tables.bookmarks,
  }
  vim.api.nvim_create_autocmd({ 'BufDelete' }, {
    pattern = '*.md',
    callback = function ()
      local file_path = vim.fn.expand'<afile>:p'
      vim.defer_fn(function ()
        if file_path and file_path ~= '' and db_utils.is_in_notes_dir(file_path) then
          if not vim.loop.fs_stat(file_path) then
            database.delete_note(file_path)
          end
        end
      end, 100)
    end,
  })
  vim.api.nvim_create_autocmd({ 'BufEnter' }, {
    pattern = '*.md',
    callback = function ()
      local file_path = vim.fn.expand'%:p'
      if file_path and file_path ~= '' and db_utils.is_in_notes_dir(file_path) then
        db_utils.check_and_update_mtime(file_path)
      end
    end,
  })
  vim.api.nvim_create_autocmd({ 'BufWritePre' }, {
    pattern = '*.md',
    callback = function ()
      local file_path = vim.fn.expand'%:p'
      if file_path and file_path ~= '' and db_utils.is_in_notes_dir(file_path) then
        if not is_updating_frontmatter and not is_updating_db then
          is_updating_frontmatter = true
          is_updating_db = true
          local bufnr = vim.api.nvim_get_current_buf()
          local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
          local filename = vim.fn.fnamemodify(file_path, ':t')
          local formatted_lines = utils.text.format_text(lines)
          vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, formatted_lines)
          local outline = utils.file.get_outline(file_path)
          local title_from_heading = nil
          if outline.headings and #outline.headings > 0 then
            for _, heading in ipairs(outline.headings) do
              if heading.level == 1 then
                title_from_heading = heading.text
                break
              end
            end
          end
          if not title_from_heading and not db_utils.is_special_note(filename) then
            local base_filename = vim.fn.fnamemodify(filename, ':r')
            local clean_name = base_filename:gsub('^%d+%-', '')
            if clean_name == '' then
              clean_name = 'Untitled note'
            else
              clean_name = clean_name:gsub('%-', ' ')
              clean_name = clean_name:sub(1, 1):upper() .. clean_name:sub(2)
            end
            local frontmatter_end = 0
            for i, line in ipairs(formatted_lines) do
              if i > 1 and line:match'^%-%-%-$' then
                frontmatter_end = i
                break
              end
            end
            local heading_line = '# ' .. clean_name
            if frontmatter_end > 0 then
              table.insert(formatted_lines, frontmatter_end + 1, '')
              table.insert(formatted_lines, frontmatter_end + 2, heading_line)
              if frontmatter_end + 3 > #formatted_lines or formatted_lines[frontmatter_end + 3] ~= '' then
                table.insert(formatted_lines, frontmatter_end + 3, '')
              end
            else
              table.insert(formatted_lines, 1, heading_line)
              if #formatted_lines < 2 or formatted_lines[2] ~= '' then
                table.insert(formatted_lines, 2, '')
              end
            end
            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, formatted_lines)
            outline = utils.file.get_outline(file_path)
            title_from_heading = clean_name
          end
          local note_id = outline.metadata and outline.metadata.id
          if not note_id and not db_utils.is_special_note(filename) then
            note_id = utils.text.create_note_id()
          end
          local updated_timestamp = utils.text.create_iso_8601_datetime()
          local created_timestamp = outline.metadata and outline.metadata.created or updated_timestamp
          local frontmatter_start, frontmatter_end = nil, nil
          for i = 1, #formatted_lines do
            if formatted_lines[i]:match'^%-%-%-$' then
              if not frontmatter_start then
                frontmatter_start = i
              elseif not frontmatter_end then
                frontmatter_end = i
                break
              end
            end
          end
          local new_lines = {}
          if not frontmatter_start or not frontmatter_end then
            table.insert(new_lines, '---')
            if not db_utils.is_special_note(filename) then
              table.insert(new_lines, 'id: ' .. note_id)
            end
            table.insert(new_lines, 'created: ' .. created_timestamp)
            table.insert(new_lines, 'updated: ' .. updated_timestamp)
            if not db_utils.is_special_note(filename) then
              table.insert(new_lines, 'tags: []')
            end
            table.insert(new_lines, '---')
            table.insert(new_lines, '')
            for _, line in ipairs(formatted_lines) do
              table.insert(new_lines, line)
            end
          else
            local found_id = db_utils.is_special_note(filename) or false
            local found_created = false
            local found_updated = false
            local found_tags = db_utils.is_special_note(filename) or false
            for i = 1, frontmatter_start do
              table.insert(new_lines, formatted_lines[i])
            end
            for i = frontmatter_start + 1, frontmatter_end - 1 do
              local line = formatted_lines[i]
              local key = line:match'^([^:]+):'
              if key then
                key = key:match'^%s*(.-)%s*$'
                if key == 'id' then
                  found_id = true
                  if not db_utils.is_special_note(filename) then
                    table.insert(new_lines, 'id: ' .. note_id)
                  end
                elseif key == 'created' then
                  found_created = true
                  table.insert(new_lines, 'created: ' .. created_timestamp)
                elseif key == 'updated' then
                  found_updated = true
                  table.insert(new_lines, 'updated: ' .. updated_timestamp)
                elseif key == 'tags' then
                  found_tags = true
                  if not db_utils.is_special_note(filename) then
                    local tags = line:match'^[^:]+:%s*(.-)%s*$' or '[]'
                    table.insert(new_lines, 'tags: ' .. tags)
                  end
                else
                  table.insert(new_lines, line)
                end
              else
                table.insert(new_lines, line)
              end
            end
            if not found_id and not db_utils.is_special_note(filename) then
              table.insert(new_lines, 'id: ' .. note_id)
            end
            if not found_created then
              table.insert(new_lines, 'created: ' .. created_timestamp)
            end
            if not found_updated then
              table.insert(new_lines, 'updated: ' .. updated_timestamp)
            end
            if not found_tags and not db_utils.is_special_note(filename) then
              table.insert(new_lines, 'tags: []')
            end
            table.insert(new_lines, '---')
            for i = frontmatter_end + 1, #formatted_lines do
              table.insert(new_lines, formatted_lines[i])
            end
          end
          vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, new_lines)
          vim.defer_fn(function ()
            if not db_utils.is_special_note(filename) then
              db_utils.update_note_in_db(file_path, true)
            end
            if title_from_heading and note_id and not db_utils.is_special_note(filename) then
              local sanitized_title = title_from_heading:gsub('[^%w%s]', '')
                :match'^%s*(.-)%s*$'
                :gsub('%s+', '-')
                :lower()
              local expected_filename = note_id .. '-' .. sanitized_title .. '.md'
              if expected_filename ~= filename then
                local notes_dir = vim.fn.expand(state.config.notes_dir)
                if not notes_dir:match'/$' then
                  notes_dir = notes_dir .. '/'
                end
                local new_file_path = notes_dir .. expected_filename
                vim.defer_fn(function ()
                  local existing = tables.notes:where{ id = note_id }
                  if existing then
                    tables.notes:update{
                      where = { id = note_id },
                      set = { filename = expected_filename }
                    }
                  end
                  local old_file_path = file_path
                  vim.loop.fs_rename(file_path, new_file_path)
                  local current_bufnr = vim.fn.bufnr(file_path)
                  if current_bufnr ~= -1 then
                    local was_current = vim.api.nvim_get_current_buf() == current_bufnr
                    local cursor_pos, window_view
                    if was_current then
                      cursor_pos = vim.api.nvim_win_get_cursor(0)
                      window_view = vim.fn.winsaveview()
                    end
                    vim.api.nvim_buf_set_name(current_bufnr, new_file_path)
                    state.last_note = new_file_path
                    if was_current then
                      vim.fn.winrestview(window_view)
                      vim.api.nvim_win_set_cursor(0, cursor_pos)
                      vim.cmd'normal! m`'
                    end
                    vim.cmd('silent! windo if expand("%:p") == "' .. old_file_path .. '" | bdelete! | endif')
                  end
                end, 100)
              end
            end
          end, 10)
          is_updating_frontmatter = false
          is_updating_db = false
        end
      end
    end,
  })

  vim.api.nvim_create_autocmd({ 'FocusGained' }, {
    pattern = '*.md',
    callback = function ()
      local file_path = vim.fn.expand'%:p'
      if file_path and file_path ~= '' and
         utils.file.is_markdown(file_path) and
         db_utils.is_in_notes_dir(file_path) then
        vim.schedule(function ()
          db_utils.check_and_update_mtime(file_path)
        end)
      end
    end,
  })
  vim.defer_fn(function ()
    db_utils.clean_deleted_notes()
    db_utils.clean_special_notes()
    local files = db_utils.get_markdown_files(state.config.notes_dir)
    local chunk_size = 5
    local current_index = 1
    local function process_chunk ()
      local end_index = math.min(current_index + chunk_size - 1, #files)
      for i = current_index, end_index do
        local file_path = files[i]
        local filename = vim.fn.fnamemodify(file_path, ':t')
        if db_utils.is_special_note(filename) then
          db_utils.update_frontmatter(file_path, false)
        else
          db_utils.update_note_in_db(file_path)
        end
      end
      current_index = end_index + 1
      if current_index <= #files then
        vim.defer_fn(process_chunk, 10)
      end
    end
    process_chunk()
  end, 100)
  vim.api.nvim_create_autocmd('VimLeavePre', {
    callback = function ()
      db_utils.clean_deleted_notes()
      db_utils.clean_special_notes()
    end
  })
end

function database.get_note_title (note_id)
  local note = tables.notes:where{ id = note_id }
  if not note then
    vim.notify('Note not found for ID: ' .. note_id, vim.log.levels.ERROR)
    return nil
  end
  local outline = utils.file.get_outline(db_utils.get_full_path(note.filename))
  for _, heading in ipairs(outline.headings) do
    if heading.level == 1 then
      return heading.text
    end
  end
  return nil
end

function database.with_bookmark (number, fn)
  local bookmark = tables.bookmarks:where{ number = number }
  if not bookmark then
    vim.notify('Bookmark not found: ' .. number, vim.log.levels.WARN)
    return
  end
  local note = tables.notes:where{ id = bookmark.note_id }
  if not note then
    vim.notify('Note not found for bookmark: ' .. number, vim.log.levels.ERROR)
    tables.bookmarks:remove{ number = number }
    return
  end
  local outline = utils.file.get_outline(db_utils.get_full_path(note.filename))
  local heading = outline.headings[bookmark.heading_index]
  if heading and heading.text == bookmark.heading_text then
    fn(bookmark, note, heading)
  else
    local found = false
    for idx, h in ipairs(outline.headings) do
      if h.text == bookmark.heading_text then
        tables.bookmarks:update{
          where = { number = number },
          set = { heading_index = idx },
        }
        fn(bookmark, note, h)
        found = true
        break
      end
    end
    if not found and heading then
      tables.bookmarks:update{
        where = { number = number },
        set = { heading_text = heading.text }
      }
      fn(bookmark, note, heading)
      found = true
    end
    if not found then
      vim.notify('Heading not found for bookmark: ' .. number, vim.log.levels.ERROR)
      tables.bookmarks:remove{ number = number }
    end
  end
end

function database.insert_bookmark (number)
  if not number then
    error'Bookmark number is required'
    return
  end
  tables.bookmarks:remove{ number = number }
  local file_path = vim.fn.expand'%:p'
  if not db_utils.is_in_notes_dir(file_path) then
    error'Current file is not in the notes directory'
    return
  end
  local outline = utils.file.get_outline(file_path)
  local cursor_line = vim.api.nvim_win_get_cursor(0)[1]
  local heading_index, heading_text
  for idx, heading in ipairs(outline.headings) do
    if cursor_line >= heading.start_row then
      heading_index = idx
      heading_text = heading.text
    else
      break
    end
  end
  if not heading_index or not heading_text then
    error'No valid heading found at the current cursor position'
    return
  end
  local note_id = outline.metadata.id
  if not note_id then
    error'Note ID not found in the current file'
    return
  end
  tables.bookmarks:insert{
    number = number,
    note_id = note_id,
    heading_index = heading_index,
    heading_text = heading_text,
  }
end

function database.remove_bookmark (number)
  tables.bookmarks:remove{ number = number }
end

function database.get_bookmarks ()
  return tables.bookmarks:get()
end

function database.goto_bookmark (number)
  database.with_bookmark(number, function (_, note, heading)
    vim.cmd('e! ' .. db_utils.get_full_path(note.filename))
    vim.api.nvim_win_set_cursor(0, { heading.start_row, 0 })
    vim.cmd'normal! zt'
  end)
end

return database

