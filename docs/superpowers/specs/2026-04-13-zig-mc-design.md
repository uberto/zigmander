# zig-mc Design Spec

**Date:** 2026-04-13  
**Project:** zig-mc — a Midnight Commander-style double-pane terminal file manager for macOS  
**Language:** Zig  
**TUI library:** libvaxis (https://github.com/rockorager/libvaxis)

---

## Goal

A keyboard-driven, double-pane terminal file manager for macOS. Fast, minimal, no mouse required. Inspired by Midnight Commander but with Mac-friendly shortcuts (Option key instead of F-keys by default).

---

## Screen Layout

```
┌── /Users/foo/projects ────────┬── /Users/foo/docs ─────────────┐
│  ..                           │  ..                             │
│  src/              DIR        │ > README.md          4.2K       │
│> build.zig         1.1K       │  notes.txt           800        │
│  build.zig.zon     400        │  archive/            DIR        │
│                               │                                 │
├───────────────────────────────┴─────────────────────────────────┤
│ Tab Switch  Enter Open  Opt+C Copy  Opt+M Move  Opt+D Del  Opt+Q Quit │
└─────────────────────────────────────────────────────────────────┘
```

- Active panel has a highlighted border.
- Cursor row is highlighted.
- Directories shown with `DIR` tag, files with human-readable size.
- Status bar at the bottom always shows active shortcuts. In Fn-key mode, it switches to F1–F10 labels.

---

## Keyboard Shortcuts

### Navigation

| Key | Action |
|-----|--------|
| `↑` / `↓` | Move cursor within active panel |
| `←` | Go to parent directory |
| `→` / `Enter` | Enter directory / open file with `$EDITOR` |
| `Tab` | Switch active panel |
| `Space` | Toggle selection on item under cursor |

### Operations (Option/Alt prefix)

| Key | Action |
|-----|--------|
| `Opt+C` | Copy selected (or cursor item) to the other panel's directory |
| `Opt+M` | Move to other panel's directory |
| `Opt+R` | Rename in place (inline prompt) |
| `Opt+D` | Delete with confirmation prompt |
| `Opt+N` | Create new directory (inline prompt) |
| `Opt+F` | Toggle Fn-key mode (enables F1–F10 shortcuts, shown in status bar) |
| `Opt+Q` | Quit |

- `Opt+M` always moves to the other panel's current directory without prompting.
- `Opt+R` opens a rename prompt pre-filled with the current filename; editing it renames in place.

### Fn-key mode (opt-in)

Pressing `Opt+F` toggles Fn-key mode. When active:
- The status bar switches to display `F5 Copy  F6 Move  F8 Del  F7 Mkdir  F10 Quit`
- F5–F10 trigger the same operations as their Option equivalents
- Pressing `Opt+F` again returns to the default Option-key mode

This allows users with keyboards where F-keys are top-level (or who prefer classic MC muscle memory) to work in that style.

**Note:** Command (Cmd) key combinations are not used because macOS terminal emulators (Terminal.app, iTerm2) intercept them before the app receives input. Option/Alt keys are passed through reliably.

---

## Architecture

### Single-threaded event loop

```
main() → init vaxis → load both panels → event loop:
  read key event
  → input.zig: map to Action
  → app.zig: apply Action to AppState
  → render.zig: draw full frame to vaxis Surface
  → flush
```

No threads, no async. Each frame is fully synchronous.

### Source files

```
src/
  main.zig      Entry point. Initialises vaxis, creates AppState, runs the event loop.
  app.zig       AppState struct and action dispatch. Owns two Panel values and active_panel index.
  panel.zig     Panel struct: path, entries[], cursor, scroll_offset, selection (bit set or hash set).
  fs.zig        File system operations: listDir, copyEntry, moveEntry, deleteEntry, mkdir.
  render.zig    Renders both panels + status bar onto a vaxis Surface each frame.
  input.zig     Maps raw vaxis key events to Action (tagged union).
```

### Key types

```zig
// Tagged union of everything the user can trigger
const Action = union(enum) {
    cursor_up,
    cursor_down,
    enter,
    go_parent,
    switch_panel,
    toggle_select,
    copy,
    move,
    rename,
    delete,
    mkdir,
    toggle_fn_mode,
    quit,
};

// Per-panel state
const Panel = struct {
    path: []const u8,
    entries: []fs.Entry,
    cursor: usize,
    scroll_offset: usize,
    selections: std.StringHashMap(void),  // keyed by filename, stable across reloads
};

// Full app state
const AppState = struct {
    panels: [2]Panel,
    active: u1,           // index into panels (0 or 1)
    modal: Modal,
    fn_mode: bool,
    status_msg: ?[]const u8,  // cleared on next keypress
};

// Overlay modals
const Modal = union(enum) {
    none,
    confirm_delete: struct { path: []const u8 },
    mkdir_prompt: struct { input: [256]u8, len: usize },
    rename_prompt: struct { input: [256]u8, len: usize, src: []const u8 },
};
```

### Rendering

`render.zig` receives a read-only `AppState` and a mutable vaxis `Surface`. It:
1. Calculates column widths from terminal width (each panel = half).
2. Draws left panel, right panel, border between them.
3. Draws status bar row at the bottom (Option-key labels or F-key labels depending on `fn_mode`).
4. If `modal != .none`, draws a centred overlay on top.
5. If `status_msg != null`, shows it in an info line above the status bar.

### File operations

`fs.zig` exposes synchronous functions. Errors are returned (not panicked) and surfaced as `status_msg` on `AppState`. Operations:

- `listDir(allocator, path)` → `[]Entry` sorted: dirs first, then files, both alphabetically.
- `copyEntry(src, dest_dir)` — recursive for directories.
- `moveEntry(src, dest_dir)` — `rename` syscall first; falls back to copy+delete across devices.
- `renameEntry(path, new_name)` — renames within the same directory.
- `deleteEntry(path)` — recursive for directories.
- `mkdir(parent, name)` → creates directory.

After any mutating operation, the affected panel reloads its directory listing and attempts to keep the cursor on the same filename.

---

## Error handling

- File operation errors (permission denied, disk full, etc.) set `AppState.status_msg` with a short description. The message is cleared on the next keypress.
- No panics on I/O errors.
- Out-of-memory in `listDir` is propagated up and causes a clean exit with an error message.

---

## Out of scope

- Mouse support
- File preview / viewer pane
- Archive browsing (zip, tar)
- FTP / SFTP / remote filesystems
- Syntax highlighting
- Plugin system
- Configuration file (shortcuts are hardcoded for now)

---

## Dependencies

- Zig (tested against latest stable)
- `libvaxis` — fetched via `build.zig.zon`. No other external dependencies.
