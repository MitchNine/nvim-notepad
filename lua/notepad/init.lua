local M = {}

local uv = vim.uv or vim.loop

local defaults = {
  notes_dir = "~/notes",
  extension = ".md",
  width_pct = 0.5,
  height_pct = 0.5,
  border = "rounded",
}

-- Pre-seed config with defaults so M.open/M.show_tree work before M.setup()
local state = {
  bufnr = nil,
  winid = nil,
  path = nil,
  entries = {},
  config = vim.tbl_deep_extend("force", {}, defaults),
}

local tree_state = {
  bufnr = nil,
  winid = nil,
}

local function close()
  if state.winid and vim.api.nvim_win_is_valid(state.winid) then
    vim.api.nvim_win_close(state.winid, true)
  end
  state.bufnr = nil
  state.winid = nil
  state.path = nil
  state.entries = {}
end

-- Returns editor (width, height) from the first UI, with safe fallbacks.
local function get_editor_size()
  local ui = vim.api.nvim_list_uis()[1]
  return (ui and ui.width or 80), (ui and ui.height or 24)
end

-- Uses uv.fs_scandir so each entry's type is returned directly,
-- eliminating the N extra uv.fs_stat calls that readdir required.
local function list_entries(dir)
  if vim.fn.isdirectory(dir) == 0 then return {} end
  local handle = uv.fs_scandir(dir)
  if not handle then return {} end

  local dirs, files = {}, {}
  while true do
    local name, ftype = uv.fs_scandir_next(handle)
    if not name then break end
    if name:sub(1, 1) ~= "." then
    -- fs_scandir_next returns "link" for symlinks and "unknown" on some FSes.
    -- Fall back to fs_stat (which follows symlinks) for both cases.
    if ftype == "link" or ftype == "unknown" then
      local st = uv.fs_stat(dir .. "/" .. name)
      ftype = st and st.type or "unknown"
    end
    local full = dir .. "/" .. name
    if ftype == "directory" then
      table.insert(dirs, { name = name, path = full, kind = "dir" })
    elseif ftype == "file" then
      table.insert(files, { name = name, path = full, kind = "file" })
    end
    end
  end

  table.sort(dirs,  function(a, b) return a.name < b.name end)
  table.sort(files, function(a, b) return a.name < b.name end)

  local entries = {}
  for _, e in ipairs(dirs)  do table.insert(entries, e) end
  for _, e in ipairs(files) do table.insert(entries, e) end
  return entries
end

local ns = vim.api.nvim_create_namespace("notepad")

local function apply_list_highlights(buf, entries)
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for i, e in ipairs(entries) do
    local group = e.kind == "dir" and "NotepadDirectory" or "NotepadFile"
    vim.api.nvim_buf_add_highlight(buf, ns, group, i - 1, 0, -1)
    vim.api.nvim_buf_add_highlight(buf, ns, "NotepadMarker", i - 1, 1, 2)
  end
end

-- Uses state.entries (populated by render) so no disk read is needed.
local function entry_at_cursor()
  local buf = state.bufnr
  if not buf then return nil end
  if not (state.winid and vim.api.nvim_win_is_valid(state.winid)) then return nil end
  local line = vim.api.nvim_win_get_cursor(state.winid)[1]
  local entries = state.entries
  if line < 1 or line > #entries then return nil end
  return entries[line]
end

local function open_entry()
  local entry = entry_at_cursor()
  if not entry then return end
  if entry.kind == "dir" then
    render(entry.path)
  else
    local winid = state.winid
    local file_buf = vim.fn.bufadd(entry.path)
    vim.fn.bufload(file_buf)
    vim.api.nvim_win_set_buf(winid, file_buf)
    pcall(vim.api.nvim_win_set_config, winid, { title = " " .. vim.fn.fnamemodify(entry.path, ":.") .. " " })
    vim.api.nvim_win_set_cursor(winid, { 1, 0 })
  end
end

local function go_up()
  local root = vim.fn.expand(state.config.notes_dir):gsub("/+$", "")
  local parent = vim.fn.fnamemodify(state.path, ":h")
  local within_root = parent == root or parent:sub(1, #root + 1) == root .. "/"
  if parent and parent ~= state.path and within_root then
    render(parent)
  end
end

local function new_entry()
  vim.ui.input({ prompt = "Entry name: " }, function(name)
    if not name or name == "" then return end
    local full = state.path .. "/" .. name
    local is_dir = name:match("/$")
    if is_dir then
      full = full:sub(1, -2)
      vim.fn.mkdir(full, "p")
    else
      if not name:match("%.%w+$") then
        full = full .. state.config.extension
      end
      if vim.fn.writefile({}, full) ~= 0 then
        vim.notify("Failed to create file: " .. full, vim.log.levels.ERROR)
        return
      end
    end
    render(state.path)   -- re-populates state.entries
    -- Place cursor on the newly created entry
    if not (state.winid and vim.api.nvim_win_is_valid(state.winid)) then return end
    local target = vim.fn.fnamemodify(full, ":t")
    for i, e in ipairs(state.entries) do
      if e.name == target then
        vim.api.nvim_win_set_cursor(state.winid, { i, 0 })
        break
      end
    end
  end)
end

local function delete_entry()
  local entry = entry_at_cursor()
  if not entry then return end
  vim.ui.input({ prompt = "Delete \"" .. entry.name .. "\"? (y/N): " }, function(answer)
    if answer and answer:lower() == "y" then
      local result
      if entry.kind == "dir" then
        result = vim.fn.delete(entry.path, "rf")
      else
        result = vim.fn.delete(entry.path)
      end
      if result ~= 0 then
        vim.notify("Delete failed: " .. entry.path, vim.log.levels.ERROR)
        return
      end
      render(state.path)
    end
  end)
end

local function rename_entry()
  local entry = entry_at_cursor()
  if not entry then return end
  vim.ui.input({ prompt = "New name: ", default = entry.name }, function(name)
    if not name or name == "" then return end
    local new_path = state.path .. "/" .. name
    local result = vim.fn.rename(entry.path, new_path)
    if result ~= 0 then
      vim.notify("Rename failed: " .. entry.path, vim.log.levels.ERROR)
      return
    end
    render(state.path)
  end)
end

local function is_git_repo(dir)
  local git_dir = vim.fn.systemlist("git -C " .. vim.fn.shellescape(dir) .. " rev-parse --show-toplevel 2>/dev/null")
  return #git_dir > 0 and git_dir[1] ~= ""
end

local function render(dir)

  if not (state.bufnr and vim.api.nvim_buf_is_valid(state.bufnr)) then
    return
  end
  state.path = dir

  local entries = list_entries(dir)
  state.entries = entries          -- cache so entry_at_cursor avoids re-reading disk

  local lines = {}
  for _, e in ipairs(entries) do
    if e.kind == "dir" then
      table.insert(lines, " ▸ " .. e.name .. "/")
    else
      table.insert(lines, " · " .. e.name)
    end
  end

  local title = " " .. dir .. " "
  local footer = ""
  if is_git_repo(dir) then
    local branch = vim.fn.systemlist("git -C " .. vim.fn.shellescape(dir) .. " rev-parse --abbrev-ref HEAD 2>/dev/null")[1]
    if branch and branch ~= "" then
      title = " " .. dir .. " (" .. branch .. ") "
      footer = " " .. branch .. " "
      local ab = vim.fn.systemlist("git -C " .. vim.fn.shellescape(dir) .. " rev-list --count --left-right @{upstream}...HEAD 2>/dev/null")[1]
      if ab then
        local behind, ahead = ab:match("^(%d+)%s+(%d+)$")
        if behind and ahead then
          local parts = {}
          if tonumber(ahead) > 0 then table.insert(parts, "↑" .. ahead) end
          if tonumber(behind) > 0 then table.insert(parts, "↓" .. behind) end
          if #parts > 0 then footer = footer .. "│ " .. table.concat(parts, " ") .. " " end
        end
      end
    end
  end

  local buf = state.bufnr
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  pcall(vim.api.nvim_buf_set_name, buf, "notepad://" .. dir)
  pcall(vim.api.nvim_win_set_cursor, state.winid, { 1, 0 })
  apply_list_highlights(buf, entries)
  vim.api.nvim_win_set_config(state.winid, { title = title, footer = footer })
end

local function git_pull()
  local dir = state.path
  if not dir then return end
  if not is_git_repo(dir) then
    vim.notify("Not a git repository", vim.log.levels.WARN)
    return
  end
  vim.notify("Running git pull...", vim.log.levels.INFO)
  local result = vim.fn.system("git -C " .. vim.fn.shellescape(dir) .. " pull 2>&1")
  vim.notify(result:gsub("%s+$", ""), vim.log.levels.INFO)
  render(dir)
end

local function git_commit()
  local dir = state.path
  if not dir then return end
  if not is_git_repo(dir) then
    vim.notify("Not a git repository", vim.log.levels.WARN)
    return
  end
  vim.ui.input({ prompt = "Commit message: " }, function(msg)
    if not msg or msg == "" then return end
    vim.fn.system("git -C " .. vim.fn.shellescape(dir) .. " add -A")
    local result = vim.fn.system("git -C " .. vim.fn.shellescape(dir) .. " commit -m " .. vim.fn.shellescape(msg) .. " 2>&1")
    if vim.v.shell_error ~= 0 then
      vim.notify(result:gsub("%s+$", ""), vim.log.levels.WARN)
    else
      vim.notify(result:gsub("%s+$", ""), vim.log.levels.INFO)
    end
    render(dir)
  end)
end

local function git_push()
  local dir = state.path
  if not dir then return end
  if not is_git_repo(dir) then
    vim.notify("Not a git repository", vim.log.levels.WARN)
    return
  end
  vim.fn.system("git -C " .. vim.fn.shellescape(dir) .. " add -A")
  local auto_msg = "Auto-sync: " .. os.date("%Y-%m-%d %H:%M:%S")
  vim.fn.system("git -C " .. vim.fn.shellescape(dir) .. " commit -m " .. vim.fn.shellescape(auto_msg) .. " 2>/dev/null")
  vim.notify("Running git push...", vim.log.levels.INFO)
  local result = vim.fn.system("git -C " .. vim.fn.shellescape(dir) .. " push 2>&1")
  if vim.v.shell_error ~= 0 then
    vim.notify(result:gsub("%s+$", ""), vim.log.levels.WARN)
  else
    vim.notify(result:gsub("%s+$", ""), vim.log.levels.INFO)
  end
  render(dir)
end

local function setup_buffer()
  local buf = vim.api.nvim_create_buf(false, true)
  state.bufnr = buf

  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "notepad"
  vim.bo[buf].modifiable = false

  local map = function(mode, lhs, rhs, desc)
    vim.api.nvim_buf_set_keymap(buf, mode, lhs, "", {
      callback = rhs,
      desc = desc or "",
      nowait = true,
      silent = true,
    })
  end

  map("n", "<CR>", open_entry,   "Open entry")
  map("n", "<BS>", go_up,        "Go up")
  map("n", "a",    new_entry,    "New entry")
  map("n", "d",    delete_entry, "Delete entry")
  map("n", "r",    rename_entry, "Rename entry")
  map("n", "q",    close,        "Close notepad")
  map("n", "R",    function() render(state.path) end, "Refresh")
  map("n", "i",    open_entry,   "Open entry")
  map("n", "o",    open_entry,   "Open entry")
  map("n", "P",    git_pull,     "Git pull")
  map("n", "c",    git_commit,   "Git commit")
  map("n", "p",    git_push,     "Git push")

  return buf
end

-- Shared autocmd setup for both the browser float and the tree float.
-- Registers a BufEnter autocmd that re-applies "q" to any buffer that enters
-- the float, and a WinClosed autocmd that cleans up the augroup and calls
-- on_close().
local function setup_float_autocmds(winid, aug, on_close)
  -- Re-apply q to any buffer that enters this float (e.g. after a file is
  -- swapped in).  Self-deregisters if the window is no longer valid (guard
  -- against WinClosed never firing).
  vim.api.nvim_create_autocmd("BufEnter", {
    group = aug,
    callback = function()
      if not vim.api.nvim_win_is_valid(winid) then
        pcall(vim.api.nvim_del_augroup_by_id, aug)
        return
      end
      if vim.api.nvim_get_current_win() == winid then
        vim.keymap.set("n", "q", function()
          if vim.api.nvim_win_is_valid(winid) then
            vim.api.nvim_win_close(winid, true)
          end
        end, { buffer = true, nowait = true, silent = true, desc = "Close float" })
      end
    end,
  })

  -- Clean up augroup and state when the window is closed.
  vim.api.nvim_create_autocmd("WinClosed", {
    group = aug,
    pattern = tostring(winid),
    once = true,
    callback = function()
      vim.api.nvim_del_augroup_by_id(aug)
      on_close()
    end,
  })
end

function M.open(dir)
  if state.winid and vim.api.nvim_win_is_valid(state.winid) then
    vim.api.nvim_set_current_win(state.winid)
    -- If scratch buf was swapped out (file is open in the float), rebuild the browser
    if not (state.bufnr and vim.api.nvim_buf_is_valid(state.bufnr)) then
      local browse_dir = dir or state.path or state.config.notes_dir
      local new_buf = setup_buffer()
      vim.api.nvim_win_set_buf(state.winid, new_buf)
      render(vim.fn.expand(browse_dir))
    else
      render(dir or state.path)
    end
    return
  end

  dir = vim.fn.expand(dir or state.config.notes_dir)
  if not vim.fn.isdirectory(dir) then
    vim.fn.mkdir(dir, "p")
  end

  local buf = setup_buffer()

  local editor_w, editor_h = get_editor_size()
  local float_w = math.floor(editor_w * state.config.width_pct)
  local float_h = math.floor(editor_h * state.config.height_pct)

  state.winid = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width    = float_w,
    height   = float_h,
    row      = math.floor((editor_h - float_h) / 2),
    col      = math.floor((editor_w - float_w) / 2),
    style    = "minimal",
    border   = state.config.border,
    title    = " " .. dir .. " ",
  })

  local winid = state.winid
  local aug = vim.api.nvim_create_augroup("NotepadBrowser_" .. winid, { clear = true })
  setup_float_autocmds(winid, aug, function()
    state.bufnr  = nil
    state.winid  = nil
    state.path   = nil
    state.entries = {}
  end)

  render(dir)
end

local function open_float_win(buf, title, lines)
  local editor_w, editor_h = get_editor_size()
  local float_w = math.floor(editor_w * state.config.width_pct)
  local float_h = math.min(#lines + 2, math.floor(editor_h * state.config.height_pct))

  -- Set lines before opening to avoid flash of empty content
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false

  local winid = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width    = float_w,
    height   = float_h,
    row      = math.floor((editor_h - float_h) / 2),
    col      = math.floor((editor_w - float_w) / 2),
    style    = "minimal",
    border   = state.config.border,
    title    = " " .. title .. " ",
  })

  return winid
end

local function build_link_graph(dir)
  dir = vim.fn.expand(dir):gsub("/+$", "")
  local files = vim.fn.globpath(dir, "**/*.md", false, true)

  local outgoing = {}
  local incoming = {}
  local all = {}

  for _, fp in ipairs(files) do
    local norm = vim.fn.resolve(fp)
    all[norm] = true
    outgoing[norm] = {}
    incoming[norm] = {}
  end

  for _, fp in ipairs(files) do
    local norm = vim.fn.resolve(fp)
    local dirname = vim.fn.fnamemodify(fp, ":h")
    local content = table.concat(vim.fn.readfile(fp), "\n")
    -- Strip image links first so ![alt](url) isn't treated as a doc link
    local doc_content = content:gsub("!%[[^%]]*%]%([^%)]*%)", "")
    local seen = {}

    for text, target in doc_content:gmatch("%[([^%]]+)%]%(([^%)]+)%)") do
      local resolved = vim.fn.resolve(dirname .. "/" .. target)
      if all[resolved] and not seen[resolved] then
        seen[resolved] = true
        table.insert(outgoing[norm], { target = resolved, text = text })
        table.insert(incoming[resolved], norm)
      end
    end
  end

  local roots = {}
  for _, fp in ipairs(files) do
    local norm = vim.fn.resolve(fp)
    if #incoming[norm] == 0 then
      table.insert(roots, norm)
    end
  end

  if #roots == 0 then
    for _, fp in ipairs(files) do
      table.insert(roots, vim.fn.resolve(fp))
    end
  end

  table.sort(roots)

  return {
    outgoing = outgoing,
    roots = roots,
    dir = dir,
  }
end

local function render_tree_node(graph, fp, prefix, is_last, depth, visited, lines)
  local relpath = fp:sub(#graph.dir + 2)

  if visited[fp] then
    table.insert(lines, prefix .. (is_last and "└── " or "├── ") .. relpath .. " (cycle)")
    return
  end

  visited[fp] = true

  if depth == 0 then
    table.insert(lines, relpath)
  else
    table.insert(lines, prefix .. (is_last and "└── " or "├── ") .. relpath)
  end

  local children = graph.outgoing[fp] or {}
  for i, child in ipairs(children) do
    -- Each sibling branch gets an independent copy so they don't see each
    -- other's visited marks.  vim.tbl_extend is faster than a manual loop.
    local branch = vim.tbl_extend("force", {}, visited)
    local child_prefix
    if depth == 0 then
      child_prefix = ""
    else
      child_prefix = prefix .. (is_last and "    " or "│   ")
    end
    render_tree_node(graph, child.target, child_prefix, i == #children, depth + 1, branch, lines)
  end
end

function M.show_tree(dir)
  if tree_state.winid and vim.api.nvim_win_is_valid(tree_state.winid) then
    vim.api.nvim_win_close(tree_state.winid, true)
  end

  local graph = build_link_graph(dir or state.config.notes_dir)

  local lines = {}
  for i, root in ipairs(graph.roots) do
    render_tree_node(graph, root, "", i == #graph.roots, 0, {}, lines)
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "notepad"
  vim.bo[buf].modifiable = false

  -- Set q on the initial scratch buf
  vim.api.nvim_buf_set_keymap(buf, "n", "q", "", {
    callback = function()
      if tree_state.winid and vim.api.nvim_win_is_valid(tree_state.winid) then
        vim.api.nvim_win_close(tree_state.winid, true)
      end
    end,
    nowait = true,
    silent = true,
    desc = "Close tree",
  })

  vim.api.nvim_buf_set_keymap(buf, "n", "<CR>", "", {
    callback = function()
      local winid = tree_state.winid
      if not winid then return end
      local line = vim.api.nvim_win_get_cursor(winid)[1]
      local text = lines[line]
      if text then
        local file = text:gsub("^[│├└─ ]+", ""):gsub(" %(cycle%)$", "")
        if file and file ~= "" then
          local full_path = vim.fn.resolve(graph.dir .. "/" .. file)
          if vim.fn.filereadable(full_path) == 1 then
            local file_buf = vim.fn.bufadd(full_path)
            vim.fn.bufload(file_buf)
            vim.api.nvim_win_set_buf(winid, file_buf)
            pcall(vim.api.nvim_win_set_config, winid, { title = " " .. vim.fn.fnamemodify(full_path, ":.") .. " " })
            vim.api.nvim_win_set_cursor(winid, { 1, 0 })
          end
        end
      end
    end,
    nowait = true,
    silent = true,
    desc = "Open file at cursor",
  })

  tree_state.bufnr = buf
  tree_state.winid = open_float_win(buf, "Link Tree: " .. graph.dir, lines)

  local winid = tree_state.winid
  local aug = vim.api.nvim_create_augroup("NotepadTree_" .. winid, { clear = true })
  setup_float_autocmds(winid, aug, function()
    tree_state.bufnr = nil
    tree_state.winid = nil
  end)

  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for i, line in ipairs(lines) do
    local prefix_end = line:find("[^│├└─ ]")
    if prefix_end then
      vim.api.nvim_buf_add_highlight(buf, ns, "NotepadTreeConnector", i - 1, 0, prefix_end - 1)
    end
    local cycle_col = line:find("%(cycle%)")
    if cycle_col then
      vim.api.nvim_buf_add_highlight(buf, ns, "NotepadCycle", i - 1, cycle_col - 1, -1)
    end
  end
end

function M.setup(opts)
  state.config = vim.tbl_deep_extend("force", {}, defaults, opts or {})

  vim.api.nvim_set_hl(0, "NotepadDirectory",    { link = "Directory",  default = true })
  vim.api.nvim_set_hl(0, "NotepadFile",          { link = "Normal",     default = true })
  vim.api.nvim_set_hl(0, "NotepadMarker",        { link = "Comment",    default = true })
  vim.api.nvim_set_hl(0, "NotepadTreeConnector", { link = "Comment",    default = true })
  vim.api.nvim_set_hl(0, "NotepadCycle",         { link = "WarningMsg", default = true })

  -- Commands are registered by plugin/notepad.lua on load; setup() only
  -- (re-)applies options, highlights, and the default global keymaps.
  vim.keymap.set("n", "<leader>np", function() M.open() end,      { desc = "Open notepad" })
  vim.keymap.set("n", "<leader>nt", function() M.show_tree() end, { desc = "Open notepad tree" })
end

return M
