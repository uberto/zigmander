const vaxis = @import("vaxis");

pub const Action = union(enum) {
    // Navigation
    cursor_up,
    cursor_down,
    enter,
    go_parent,
    switch_panel,
    toggle_select,
    // File operations
    copy,
    move,
    rename,
    delete,
    mkdir,
    open,
    // View toggles

    toggle_hidden,
    cycle_sort,
    cycle_size,
    toggle_permissions,
    toggle_mtime,
    toggle_btime,
    toggle_split,
    // App
    show_help,
    quit,
    dismiss,
    // Modal text input
    modal_confirm,
    modal_cancel,
    modal_char: u8,
    modal_backspace,
};

/// Maps a key event to an Action. Returns null if the key is not bound.
pub fn keyToAction(key: vaxis.Key, in_modal: bool) ?Action {
    if (in_modal) return modalKeyToAction(key);
    return normalKeyToAction(key);
}

// ── Modal key mapping ──────────────────────────────────────────────────────

/// Handles key input while a modal dialog is open.
fn modalKeyToAction(key: vaxis.Key) ?Action {
    if (key.matches(vaxis.Key.enter, .{}))     return .modal_confirm;
    if (key.matches(vaxis.Key.escape, .{}))    return .modal_cancel;
    if (key.matches(vaxis.Key.backspace, .{})) return .modal_backspace;
    if (isPrintableAscii(key)) return .{ .modal_char = @intCast(key.codepoint) };
    return null;
}

/// Returns true for plain (no modifier) printable ASCII characters.
fn isPrintableAscii(key: vaxis.Key) bool {
    const plain = !key.mods.ctrl and !key.mods.alt and !key.mods.super
               and !key.mods.hyper and !key.mods.meta;
    return plain and key.codepoint >= 0x20 and key.codepoint <= 0x7E;
}

// ── Normal key mapping ─────────────────────────────────────────────────────

/// Handles key input in normal (non-modal) mode.
fn normalKeyToAction(key: vaxis.Key) ?Action {
    if (key.matches(vaxis.Key.escape, .{})) return .dismiss;
    if (navKeyToAction(key))           |a| return a;
    if (viewKeyToAction(key))          |a| return a;
    if (fileOpKeyToAction(key))        |a| return a;
    if (optionKeyToAction(key))        |a| return a;
    if (macOsOptionKeyToAction(key))   |a| return a;
    return null;
}

/// Navigation keys: arrows, vim hjkl, Tab, Space.
fn navKeyToAction(key: vaxis.Key) ?Action {
    if (key.matches(vaxis.Key.up, .{}) or key.matches('k', .{}))       return .cursor_up;
    if (key.matches(vaxis.Key.down, .{}) or key.matches('j', .{}))     return .cursor_down;
    if (key.matches(vaxis.Key.enter, .{}) or key.matches(vaxis.Key.right, .{})) return .enter;
    if (key.matches(vaxis.Key.left, .{}) or key.matches(vaxis.Key.backspace, .{})) return .go_parent;
    if (key.matches(vaxis.Key.tab, .{})) return .switch_panel;
    if (key.matches(' ', .{}))           return .toggle_select;
    return null;
}

/// View-toggle keys: . s b p t T |  ?
fn viewKeyToAction(key: vaxis.Key) ?Action {
    if (key.matches('.', .{})) return .toggle_hidden;
    if (key.matches('s', .{})) return .cycle_sort;
    if (key.matches('b', .{})) return .cycle_size;
    if (key.matches('p', .{})) return .toggle_permissions;
    if (key.matches('t', .{})) return .toggle_mtime;
    if (key.matches('T', .{})) return .toggle_btime;
    if (key.matches('|', .{})) return .toggle_split;
    if (key.matches('?', .{})) return .show_help;
    return null;
}

/// File operation keys: c m r d n o q (plain, no modifier required)
fn fileOpKeyToAction(key: vaxis.Key) ?Action {
    if (key.matches('c', .{})) return .copy;
    if (key.matches('m', .{})) return .move;
    if (key.matches('r', .{})) return .rename;
    if (key.matches('d', .{})) return .delete;
    if (key.matches('n', .{})) return .mkdir;
    if (key.matches('o', .{})) return .open;
    if (key.matches('q', .{})) return .quit;
    return null;
}

/// Option+letter bindings — works in terminals with kitty protocol or xterm alt reporting.
fn optionKeyToAction(key: vaxis.Key) ?Action {
    if (key.matches('c', .{ .alt = true })) return .copy;
    if (key.matches('m', .{ .alt = true })) return .move;
    if (key.matches('r', .{ .alt = true })) return .rename;
    if (key.matches('d', .{ .alt = true })) return .delete;
    if (key.matches('n', .{ .alt = true })) return .mkdir;
    if (key.matches('q', .{ .alt = true })) return .quit;
    return null;
}

/// macOS Terminal.app sends Unicode characters instead of alt+letter (US keyboard).
/// ç=Opt+C  µ=Opt+M  ®=Opt+R  ∂=Opt+D  ˜=Opt+N  ƒ=Opt+F  œ=Opt+Q
fn macOsOptionKeyToAction(key: vaxis.Key) ?Action {
    return switch (key.codepoint) {
        0x00E7 => .copy,           // ç
        0x00B5 => .move,           // µ
        0x00AE => .rename,         // ®
        0x2202 => .delete,         // ∂
        0x02DC => .mkdir,          // ˜
        0x0153 => .quit,           // œ
        else   => null,
    };
}

