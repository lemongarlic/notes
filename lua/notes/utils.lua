local parsers = require'nvim-treesitter.parsers'
local state = require'notes.state'

local queries = {
  headings = vim.treesitter.query.parse('markdown', [[
  (atx_heading) @heading
  ]]),
  frontmatter = vim.treesitter.query.parse('markdown', [[
  (minus_metadata) @frontmatter
  ]]),
  yaml = vim.treesitter.query.parse('yaml', [[
  (document
    (block_node
      (block_mapping
        (block_mapping_pair
          key: (flow_node (plain_scalar) @key)
          value: (_) @value))))
  ]])
}

local utils = {
  file = {},
  text = {},
}

local function ensure_md_parser_exists ()
  if not parsers.has_parser'markdown' then
    error'Tree-sitter parser for Markdown required (:TSInstall markdown).'
  end
end

function utils.text.trim (text)
  return text:match'^(.-)%s*$'
end

function utils.text.create_iso_8601_datetime ()
  return os.date'!%Y-%m-%dT%H:%M:%SZ'
end

function utils.text.create_note_id ()
  return vim.fn.strftime'%Y%m%d%H%M%S'
end

function utils.text.normalize (str)
  str = str:gsub('[%s]*([\xF0-\xF4][\x80-\xBF][\x80-\xBF][\x80-\xBF])', '')
  str = str:gsub('\u{2018}', "'")
  str = str:gsub('\u{2019}', "'")
  str = str:gsub('\u{201C}', '"')
  str = str:gsub('\u{201D}', '"')
  str = str:gsub('\u{2013}', '-')
  str = str:gsub('\u{2014}', '-')
  str = str:gsub('\u{2012}', '-')
  return str
end

function utils.text.format_text (content_lines)
  local i = 1
  while i < #content_lines do
    if content_lines[i] and content_lines[i]:match'^%s*#%s' then
      if i < #content_lines and content_lines[i + 1] ~= '' then
        table.insert(content_lines, i + 1, '')
        i = i + 1
      end
    end
    i = i + 1
  end
  while #content_lines > 0 and content_lines[#content_lines] == '' do
    table.remove(content_lines)
  end
  table.insert(content_lines, '')
  return content_lines
end

function utils.file.is_markdown (path)
  if not path then
    path = vim.fn.expand'%:p'
  end
  return path:match'%.md$'
end

function utils.file.get_outline (path)
  ensure_md_parser_exists()
  if not path then
    path = vim.fn.expand'%:p'
  end
  local outline = { path = path, metadata = {}, headings = {} }
  if not utils.file.is_markdown(path) then
    return outline
  end
  local temp_bufnr = vim.api.nvim_create_buf(false, true)
  local file = io.open(path, 'r')
  if not file then
    vim.api.nvim_buf_delete(temp_bufnr, { force = true })
    return outline
  end
  local content = {}
  for line in file:lines() do
    table.insert(content, line)
  end
  file:close()
  vim.api.nvim_buf_set_lines(temp_bufnr, 0, -1, false, content)
  vim.bo[temp_bufnr].filetype = 'markdown'
  local md_parser = parsers.get_parser(temp_bufnr, 'markdown')
  if not md_parser then
    vim.api.nvim_buf_delete(temp_bufnr, { force = true })
    return outline
  end
  local md_tree = md_parser:parse()[1]
  local md_root = md_tree:root()
  local heading_index = 1
  for id, node, _ in queries.headings:iter_captures(md_root, temp_bufnr, 0, -1) do
    local name = queries.headings.captures[id]
    local start_row, start_col, end_row, end_col = node:range()
    local buffer_line_count = vim.api.nvim_buf_line_count(temp_bufnr)
    if start_row < buffer_line_count and end_row < buffer_line_count then
      local raw = vim.api.nvim_buf_get_text(temp_bufnr, start_row, start_col, end_row, end_col, {})[1]
      local marker = raw:match'^(#+)'
      local level = marker and #marker or 0
      local text = raw:gsub('^#+%s*', '')
      table.insert(outline.headings, {
        name = name,
        start_row = start_row + 1,
        start_col = start_col + 1,
        end_row = end_row + 1,
        end_col = end_col + 1,
        level = level,
        raw = raw,
        text = text,
        index = heading_index,
      })
      heading_index = heading_index + 1
    end
  end
  local frontmatter = {}
  for _, node, _ in queries.frontmatter:iter_captures(md_root, temp_bufnr, 0, -1) do
    local start_row, start_col, end_row, end_col = node:range()
    local buffer_line_count = vim.api.nvim_buf_line_count(temp_bufnr)
    if start_row < buffer_line_count and end_row < buffer_line_count then
      local lines = vim.api.nvim_buf_get_text(temp_bufnr, start_row, start_col, end_row, end_col, {})
      for _, line in ipairs(lines) do
        local trimmed = utils.text.trim(line)
        if trimmed ~= '' and trimmed ~= '---' then
          table.insert(frontmatter, line)
        end
      end
    end
  end
  local yaml_bufnr = vim.api.nvim_create_buf(false, true)
  vim.bo[yaml_bufnr].filetype = 'yaml'
  vim.api.nvim_buf_set_lines(yaml_bufnr, 0, -1, false, frontmatter)
  local yaml_parser = parsers.get_parser(yaml_bufnr)
  if yaml_parser then
    local yaml_tree = yaml_parser:parse()[1]
    local yaml_root = yaml_tree:root()
    local current_key = nil
    for id, node, _ in queries.yaml:iter_captures(yaml_root, yaml_bufnr, 0, -1) do
      local capture_name = queries.yaml.captures[id]
      local start_row, start_col, end_row, end_col = node:range()
      local buffer_line_count = vim.api.nvim_buf_line_count(yaml_bufnr)
      if start_row < buffer_line_count and end_row < buffer_line_count then
        local text = vim.api.nvim_buf_get_text(yaml_bufnr, start_row, start_col, end_row, end_col, {})[1]
        if capture_name == 'key' then
          current_key = text
        elseif capture_name == 'value' and current_key then
          outline.metadata[current_key] = text
          current_key = nil
        end
      end
    end
  end
  vim.api.nvim_buf_delete(yaml_bufnr, { force = true })
  vim.api.nvim_buf_delete(temp_bufnr, { force = true })
  return outline
end

function utils.file.insert_text (text, path, index, is_prepend)
  if not text or utils.text.trim(text) == '' then
    return
  end
  if not path then
    path = vim.fn.expand'%:p'
  else
    path = vim.fn.expand(path)
  end
  if not utils.file.is_markdown(path) then
    return
  end
  if not index then
    index = 1
  end
  state.undo.file_path = path
  state.undo.prompt_content = {}
  for line in (text .. '\n'):gmatch'([^\r\n]*)[\r\n]' do
    table.insert(state.undo.prompt_content, line)
  end
  local existing_bufnr = vim.fn.bufnr(path)
  local using_existing_buffer = existing_bufnr ~= -1
  local file_content = {}
  local f = io.open(path, 'r')
  vim.defer_fn(function ()
    if not f then
      error(string.format('Failed to write to file: %s', path))
    end
    for line in f:lines() do
      table.insert(file_content, line)
    end
    f:close()
    state.undo.file_content = vim.deepcopy(file_content)
    local outline = utils.file.get_outline(path)
    if #outline.headings < index then
      error('Heading index ' .. index .. ' out of bounds for file: ' .. path)
      return
    end
    local lines = vim.deepcopy(file_content)
    local target_heading = outline.headings[index]
    local next_heading = outline.headings[index + 1]
    local insert_line
    if is_prepend then
      insert_line = target_heading.start_row
    else
      insert_line = next_heading and (next_heading.start_row - 1) or #lines
    end
    local text_lines = {}
    for line in (text .. '\n'):gmatch'([^\r\n]*)[\r\n]' do
      table.insert(text_lines, line)
    end
    for i = 1, #text_lines do
      text_lines[i] = tostring(text_lines[i] or '')
    end
    local is_first_line_list = text_lines[1] and text_lines[1]:match'^%s*[-*+]%s' or (text_lines[1] and text_lines[1]:match'^%s*%d+%.%s')
    local is_last_line_list = text_lines[#text_lines] and text_lines[#text_lines]:match'^%s*[-*+]%s' or (text_lines[#text_lines] and text_lines[#text_lines]:match'^%s*%d+%.%s')
    local prev_content_line
    for i = insert_line, 1, -1 do
      if lines[i] and not lines[i]:match'^%s*$' then
        prev_content_line = lines[i]
        break
      end
    end
    local next_content_line
    for i = insert_line + 1, #lines do
      if lines[i] and not lines[i]:match'^%s*$' then
        next_content_line = lines[i]
        break
      end
    end
    local prev_is_list = prev_content_line and (prev_content_line:match'^%s*[-*+]%s' or prev_content_line:match'^%s*%d+%.%s')
    local next_is_list = next_content_line and (next_content_line:match'^%s*[-*+]%s' or next_content_line:match'^%s*%d+%.%s')
    local need_space_before = not (is_first_line_list and prev_is_list)
    local need_space_after = not (is_last_line_list and next_is_list)
    if need_space_before then
      while insert_line > 1 and lines[insert_line] and lines[insert_line]:match'^%s*$' do
        table.remove(lines, insert_line)
        insert_line = insert_line - 1
      end
      if insert_line > 1 and lines[insert_line] and not lines[insert_line]:match'^%s*$' then
        insert_line = insert_line + 1
        table.insert(lines, insert_line, '')
      end
    else
      while insert_line > 1 and lines[insert_line] and lines[insert_line]:match'^%s*$' do
        table.remove(lines, insert_line)
        insert_line = insert_line - 1
      end
    end
    local actual_insert_line = insert_line + 1
    state.insert_position = actual_insert_line
    state.force_position = true
    for _, line in ipairs(text_lines) do
      insert_line = insert_line + 1
      table.insert(lines, insert_line, line)
    end
    if next_heading then
      if is_last_line_list and next_is_list then
        while insert_line + 1 <= #lines and lines[insert_line + 1]:match'^%s*$' do
          table.remove(lines, insert_line + 1)
        end
      else
        while insert_line + 1 <= #lines and lines[insert_line + 1]:match'^%s*$' do
          table.remove(lines, insert_line + 1)
        end
        insert_line = insert_line + 1
        table.insert(lines, insert_line, '')
      end
    else
      if need_space_after then
        while insert_line + 1 <= #lines and lines[insert_line + 1]:match'^%s*$' do
          table.remove(lines, insert_line + 1)
        end
        if insert_line < #lines then
          insert_line = insert_line + 1
          table.insert(lines, insert_line, '')
        end
      else
        while insert_line + 1 <= #lines and lines[insert_line + 1]:match'^%s*$' do
          table.remove(lines, insert_line + 1)
        end
      end
    end
    lines = utils.text.format_text(lines)
    if using_existing_buffer then
      vim.api.nvim_buf_set_lines(existing_bufnr, 0, -1, false, lines)
      vim.api.nvim_buf_call(existing_bufnr, function ()
        vim.cmd'silent! w!'
      end)
    else
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
      if frontmatter_start and frontmatter_end then
        local found_updated = false
        for i = frontmatter_start + 1, frontmatter_end - 1 do
          local key = lines[i]:match'^([^:]+):'
          if key and key:match'^%s*updated%s*$' then
            lines[i] = 'updated: ' .. utils.text.create_iso_8601_datetime()
            found_updated = true
            break
          end
        end
        if not found_updated then
          table.insert(lines, frontmatter_end, 'updated: ' .. utils.text.create_iso_8601_datetime())
          frontmatter_end = frontmatter_end + 1
        end
      end
      local f = io.open(path, 'w')
      if f then
        f:write(table.concat(lines, '\n') .. '\n')
        f:close()
      else
        error(string.format('Failed to write to file: %s', path))
      end
    end
    if path == vim.fn.expand'%:p' and (not using_existing_buffer or vim.api.nvim_get_current_buf() ~= existing_bufnr) then
      vim.cmd'e!'
    end
  end, 1)
end

function utils.file.generate_frontmatter_params ()
  local now = utils.text.create_iso_8601_datetime()
  local id = utils.text.create_note_id()
  return {
    id = id,
    created = now,
    updated = now,
    tags = '[]',
  }
end

function utils.file.update_frontmatter (path)
  local current_buffer = vim.fn.expand'%:p'
  if not path or path == '' then
    path = current_buffer
  else
    path = vim.fn.expand(path)
  end
  if not utils.file.is_markdown(path) then
    return
  end
  local filename = vim.fn.fnamemodify(path, ':t')
  local is_special = false
  for _, special in ipairs(state.special_notes) do
    if filename == special then
      is_special = true
      break
    end
  end
  local bufnr = vim.fn.bufnr(path)
  if bufnr ~= -1 and vim.bo[bufnr].modified then
    vim.api.nvim_buf_call(bufnr, function ()
      vim.cmd'silent! w!'
    end)
  end
  local lines = {}
  local f = io.open(path, 'r')
  if not f then
    return
  end
  for line in f:lines() do
    table.insert(lines, line)
  end
  f:close()
  local defaults = utils.file.generate_frontmatter_params()
  local id_line      = is_special and nil or ('id: ' .. defaults.id)
  local created_line = 'created: ' .. defaults.created
  local updated_line = 'updated: ' .. utils.text.create_iso_8601_datetime()
  local tags_line    = is_special and nil or ('tags: ' .. defaults.tags)
  local frontmatter_start, frontmatter_end = nil, nil
  local found_id      = is_special or false
  local found_created = false
  local found_updated = false
  local found_tags    = is_special or false
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
    while frontmatter_start > 1 and lines[frontmatter_start - 1]:match'^%s*$' do
      table.remove(lines, frontmatter_start - 1)
      frontmatter_start = frontmatter_start - 1
      frontmatter_end = frontmatter_end - 1
    end
    for i = frontmatter_start + 1, frontmatter_end - 1 do
      local line = lines[i]
      if line:match'^id:' then
        found_id = true
      end
      if line:match'^created:' then
        found_created = true
      end
      if line:match'^updated:' then
        lines[i] = updated_line
        found_updated = true
      end
      if line:match'^tags:' then
        found_tags = true
      end
    end
    local inserted = 0
    local function insert_frontmatter_line (str)
      table.insert(lines, frontmatter_end + inserted, str)
      inserted = inserted + 1
    end
    if not found_id then
      insert_frontmatter_line(id_line)
    end
    if not found_created then
      insert_frontmatter_line(created_line)
    end
    if not found_updated then
      insert_frontmatter_line(updated_line)
    end
    if not found_tags then
      insert_frontmatter_line(tags_line)
    end
  end
  local frontmatter_lines = {}
  local order = { id = 1, created = 2, updated = 3, tags = 4 }
  local new_start, new_end = nil, nil
  for i = 1, #lines do
    if lines[i]:match'^%-%-%-$' then
      if not new_start then
        new_start = i
      elseif not new_end then
        new_end = i
        break
      end
    end
  end
  frontmatter_start = new_start
  frontmatter_end = new_end
  if frontmatter_start and frontmatter_end then
    for i = frontmatter_start + 1, frontmatter_end - 1 do
      local line = lines[i]
      local key = line:match'^([^:]+):'
      if key then
        if not is_special or (key ~= 'id' and key ~= 'tags') then
          table.insert(frontmatter_lines, { line = line, key = key:match'^%s*(.-)%s*$' })
        end
      end
    end
    table.sort(frontmatter_lines, function (a, b)
      return (order[a.key] or 99) < (order[b.key] or 99)
    end)
    local new_lines = {}
    for i = 1, frontmatter_start do
      table.insert(new_lines, lines[i])
    end
    for _, item in ipairs(frontmatter_lines) do
      table.insert(new_lines, item.line)
    end
    for i = frontmatter_end, #lines do
      table.insert(new_lines, lines[i])
    end
    lines = new_lines
  end
  f = io.open(path, 'w')
  if not f then
    error(string.format('Failed to open file for writing: %s', path))
  end
  for _, line in ipairs(lines) do
    f:write(line .. '\n')
  end
  f:close()
  if current_buffer == path then
    vim.cmd'e!'
  end
end

function utils.file.get_last_note ()
  if state.last_note ~= '' and vim.fn.filereadable(state.last_note) == 1 then
    return state.last_note
  else
    local notes_dir = vim.fn.expand(state.config.notes_dir)
    if not notes_dir:match'/$' then
      notes_dir = notes_dir .. '/'
    end
    return notes_dir .. state.config.inbox_note
  end
end

return utils

