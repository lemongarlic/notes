local prompt = require'notes.prompt'
local database = require'notes.database'
local note = require'notes.note'
local state = require'notes.state'
local utils = require'notes.utils'

_G.Notes = {
  setup = function (config)
    config = config or {}
    state.init(config)
    database.init()
    note.init()
  end,
}

_G.Notes.api = {
  inbox = function ()
    local notes_dir = vim.fn.expand(state.config.notes_dir)
    if not notes_dir:match'/$' then
      notes_dir = notes_dir .. '/'
    end
    vim.cmd('e! ' .. notes_dir .. state.config.inbox_note)
  end,
  open = prompt.open,
  notes = database.find_note,
  toggle = function ()
    local current_file = vim.fn.expand'%:p'
    local notes_dir = vim.fn.expand(state.config.notes_dir)
    if not notes_dir:match'/$' then
      notes_dir = notes_dir .. '/'
    end
    local is_current_note = vim.startswith(current_file, notes_dir)
    if is_current_note then
      if state.last_non_note ~= '' and vim.fn.filereadable(state.last_non_note) == 1 then
        vim.cmd('e! ' .. state.last_non_note)
      else
        vim.cmd('e! ' .. notes_dir .. state.config.inbox_note)
      end
    else
      local target_file = utils.file.get_last_note()
      vim.cmd('e! ' .. target_file)
      if state.force_position then
        vim.api.nvim_win_set_cursor(0, { state.insert_position, 0 })
        state.force_position = false
      end
    end
  end,
  delete = function ()
    local current_file = vim.fn.expand'%:p'
    database.delete_note(current_file)
  end,
  undo = function ()
    local saved_pos = vim.fn.winsaveview()
    if state.undo.file_path == '' or #state.undo.file_content == 0 then
      vim.notify('Nothing to undo', vim.log.levels.WARN)
      return
    end
    if #state.undo.prompt_content > 0 then
      local clipboard_text = table.concat(state.undo.prompt_content, '\n')
      vim.fn.setreg('+', clipboard_text)
      vim.fn.setreg('', clipboard_text)
    end
    local file_path = state.undo.file_path
    local bufnr = vim.fn.bufnr(file_path)
    if bufnr ~= -1 and vim.api.nvim_buf_is_valid(bufnr) then
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, state.undo.file_content)
      vim.api.nvim_buf_call(bufnr, function ()
        vim.cmd'silent! w!'
      end)
    else
      local f = io.open(file_path, 'w')
      if f then
        for _, line in ipairs(state.undo.file_content) do
          f:write(line .. '\n')
        end
        f:close()
      else
        vim.notify('Failed to write to file: ' .. file_path, vim.log.levels.ERROR)
        return
      end
    end
    if file_path == vim.fn.expand'%:p' then
      vim.cmd'e!'
    end
    vim.fn.winrestview(saved_pos)
    state.undo.file_path = ''
    state.undo.file_content = {}
    state.undo.prompt_content = {}
    vim.notify('Reverted changes to ' .. vim.fn.fnamemodify(file_path, ':t'), vim.log.levels.INFO)
  end,
  bookmarks = {
    add = function (number)
      database.insert_bookmark(number)
    end,
    remove = function (number)
      database.remove_bookmark(number)
    end,
    go = function (number)
      database.goto_bookmark(number)
    end,
    list = function ()
      local bookmarks = database.get_bookmarks()
      if #bookmarks <= 0 then
        vim.notify('No bookmarks found', vim.log.levels.INFO)
        return
      end
      local lines = {}
      local width = 40
      for _, mark in ipairs(bookmarks) do
        local text = ' ' .. mark.number .. '. ' .. database.get_note_title(mark.note_id) .. ' (' .. mark.heading_text .. ') '
        if #text > width then
          width = #text
        end
        table.insert(lines, text)
      end
      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
      local win = vim.api.nvim_open_win(buf, false, {
        relative = 'editor',
        width = width,
        height = #lines,
        row = 0,
        col = vim.o.columns - width - 3,
        style = 'minimal',
        border = 'rounded',
        focusable = false,
      })
      vim.defer_fn(function ()
        vim.api.nvim_win_close(win, true)
      end, 1500)
    end,
  },
}

return _G.Notes

