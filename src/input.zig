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
    // View toggles
    toggle_hidden,
    cycle_sort,
    toggle_split,
    // App
    toggle_fn_mode,
    show_help,
    quit,
    // Modal text input
    modal_confirm,
    modal_cancel,
    modal_char: u8,
    modal_backspace,
};

pub fn keyToAction(key: vaxis.Key, fn_mode: bool, in_modal: bool) ?Action {
    if (in_modal) {
        if (key.matches(vaxis.Key.enter, .{})) return .modal_confirm;
        if (key.matches(vaxis.Key.escape, .{})) return .modal_cancel;
        if (key.matches(vaxis.Key.backspace, .{})) return .modal_backspace;
        const plain = !key.mods.ctrl and !key.mods.alt and !key.mods.super and !key.mods.hyper and !key.mods.meta;
        if (plain and key.codepoint >= 0x20 and key.codepoint <= 0x7E) {
            return .{ .modal_char = @intCast(key.codepoint) };
        }
        return null;
    }

    // Navigation
    if (key.matches(vaxis.Key.up, .{}) or key.matches('k', .{})) return .cursor_up;
    if (key.matches(vaxis.Key.down, .{}) or key.matches('j', .{})) return .cursor_down;
    if (key.matches(vaxis.Key.enter, .{}) or key.matches(vaxis.Key.right, .{})) return .enter;
    if (key.matches(vaxis.Key.left, .{}) or key.matches(vaxis.Key.backspace, .{})) return .go_parent;
    if (key.matches(vaxis.Key.tab, .{})) return .switch_panel;
    if (key.matches(' ', .{})) return .toggle_select;

    // View toggles
    if (key.matches('.', .{})) return .toggle_hidden;
    if (key.matches('s', .{})) return .cycle_sort;
    if (key.matches('|', .{})) return .toggle_split;

    // App
    if (key.matches('?', .{})) return .show_help;

    // Option+key operations — kitty keyboard protocol / xterm alt reporting
    if (key.matches('c', .{ .alt = true })) return .copy;
    if (key.matches('m', .{ .alt = true })) return .move;
    if (key.matches('r', .{ .alt = true })) return .rename;
    if (key.matches('d', .{ .alt = true })) return .delete;
    if (key.matches('n', .{ .alt = true })) return .mkdir;
    if (key.matches('f', .{ .alt = true })) return .toggle_fn_mode;
    if (key.matches('q', .{ .alt = true })) return .quit;

    // Option+key — macOS Terminal.app sends Unicode chars for Option+letter (US keyboard)
    if (key.codepoint == 0x00E7) return .copy;          // ç  = Opt+C
    if (key.codepoint == 0x00B5) return .move;          // µ  = Opt+M
    if (key.codepoint == 0x00AE) return .rename;        // ®  = Opt+R
    if (key.codepoint == 0x2202) return .delete;        // ∂  = Opt+D
    if (key.codepoint == 0x02DC) return .mkdir;         // ˜  = Opt+N
    if (key.codepoint == 0x0192) return .toggle_fn_mode; // ƒ = Opt+F
    if (key.codepoint == 0x0153) return .quit;          // œ  = Opt+Q

    // Fn-key mode
    if (fn_mode) {
        if (key.matches(vaxis.Key.f5, .{})) return .copy;
        if (key.matches(vaxis.Key.f6, .{})) return .move;
        if (key.matches(vaxis.Key.f7, .{})) return .mkdir;
        if (key.matches(vaxis.Key.f8, .{})) return .delete;
        if (key.matches(vaxis.Key.f10, .{})) return .quit;
    }

    return null;
}
