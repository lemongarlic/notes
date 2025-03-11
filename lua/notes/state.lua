local config = require'notes.config'

local state = {
  config = {
    notes_dir = '',
    inbox_note = '',
    db_file = '',
  },
  special_notes = {},
  prompt = {
    window = 0,
    buffer = 0,
    leader_active = false,
  },
  last_note = '',
  last_heading_index = 1,
  last_non_note = '',
  insert_position = nil,
  force_position = false,
  undo = {
    file_path = '',
    file_content = {},
    prompt_content = {},
  },
}

local function track_last_files ()
  local file_path = vim.fn.expand'%:p'
  if file_path == '' then return end
  local notes_dir = vim.fn.expand(state.config.notes_dir)
  if not notes_dir:match'/$' then
    notes_dir = notes_dir .. '/'
  end
  if vim.startswith(file_path, notes_dir) then
    state.last_note = file_path
  else
    state.last_non_note = file_path
  end
end

function state.init (user_config)
  local c = {}
  for k, v in pairs(config) do
    c[k] = v
  end
  for k, v in pairs(user_config) do
    c[k] = v
  end
  state.config.notes_dir = vim.fn.expand(c.notes_dir)
  state.config.inbox_note = c.inbox_note
  state.config.db_file = c.db_file
  state.special_notes = {
    state.config.inbox_note,
  }
  vim.api.nvim_create_autocmd('BufEnter', {
    callback = track_last_files
  })
end

return state

