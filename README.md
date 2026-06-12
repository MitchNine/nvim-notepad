# notepad.nvim

A scratch-buffer file manager and link-tree visualizer for markdown notes.

## Keymaps

| Key | Action |
|-----|--------|
| `<leader>np` | Open notepad (default directory) |
| `<leader>nt` | Open notepad tree (default directory) |

## Commands

| Command | Description |
|---------|-------------|
| `:Notepad [path]` | Open a floating window listing files/dirs in `path` (default: `~/notes`) |
| `:NotepadTree [path]` | Open a floating window showing markdown link relationships |

## Notepad keymaps

| Key | Action |
|-----|--------|
| `<CR>` | Open file / enter directory |
| `<BS>` | Go up to parent directory |
| `n` | Create a new entry (appends `.md` if no extension) |
| `d` | Delete entry (with confirmation) |
| `r` | Rename entry |
| `R` | Refresh listing |
| `q` | Close window |

## NotepadTree keymaps

| Key | Action |
|-----|--------|
| `<CR>` | Open the file under cursor |
| `q` | Close window |

The tree parses `[text](file.md)` links in all `.md` files within the directory, builds a directed graph, and renders it. Cycles are detected and labelled `(cycle)`. Files with no incoming links are shown as roots; when every file is reachable (fully cyclic), all files become roots.

## Setup

```lua
require("notepad").setup({
  notes_dir = "~/notes",  -- default directory for :Notepad and :NotepadTree
  extension = ".md",       -- extension appended when creating new entries
  width_pct = 0.5,         -- floating window width as fraction of editor width
  height_pct = 0.5,        -- floating window height as fraction of editor height
  border = "rounded",      -- border style: "rounded", "single", "double", etc.
})
```
