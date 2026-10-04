addon.name      = 'slowedchat';
addon.author    = 'Slowed';
addon.version   = '0.4';
addon.desc      = 'WoW-style tabbed chat windows.';
addon.link      = '';

require 'common';

local ffi       = require 'ffi';
local chat      = require 'chat';
local imgui     = require 'imgui';
local settings  = require 'settings';
local modes     = require 'modes';
local cleaner   = require 'cleaner';
local palette   = require 'palette';
local render    = require 'render';
local input     = require 'input';
local nativechat = require 'nativechat';
local fonts     = require 'fonts';
local hud       = require 'hud';
local autotranslate = require 'autotranslate';

-- Default Settings
local default_settings = T{
    layout          = 'single',     -- 'single' or 'dual'
    hide_native     = false,        -- Block captured lines from the game's own chat log.
    hide_npc        = false,        -- Also hide NPC dialog. (Off: some NPCs rely on the game's log.)
    hide_window     = false,        -- Hide the game's chat log windows themselves. (Memory write; see nativechat.lua)
    hide_compass    = true,         -- Hide the game's compass and clock. (Code patch; see hud.lua)
    show_time       = true,         -- Show Vana'diel day/time in the chat window's tab row.
    custom_input    = true,         -- Enter / '/' opens slowedchat's input instead of the game's.
    chat_channel    = 'say',        -- Last sticky input channel.
    tell_target     = '',           -- Last tell target, when chat_channel is 'tell'.
    chat_menus      = T{ },         -- Game menus where Enter opens chat. (Learned automatically.)
    menu_fade       = T{ },         -- [menu name] = true/false: your '/schat fade' choices. (See input.game_menu_open)
    timestamps      = true,
    timestamp_fmt   = '[%H:%M]',
    max_lines       = 300,          -- Lines kept per tab.
    font_family     = 'Segoe UI',   -- See fonts.lua. 'Default' is Ashita's ImGui font.
    text_size       = 0,            -- Pixels; 0 = match Ashita's ImGui font size.
    text_effect     = 'outline',    -- 'outline', 'shadow' or 'none'.
    message_style   = 'wow',        -- 'wow' ("[Party] Name: hi") or 'ffxi' ("(Name) hi").
    mention_highlight = true,       -- Highlight lines where someone says your name.
    bg_alpha        = 0.60,         -- Background opacity while hovered / typing.
    hover_reveal    = true,         -- Dim the background and chrome while the mouse is elsewhere.
    idle_bg_alpha   = 0.20,         -- Background opacity while idle. (With hover_reveal.)
    lines_shade     = 0.20,         -- Constant dark shade behind the message lines.
    speaker_names   = true,         -- Draw speaker names a shade brighter than the message.
    line_gap        = 2,            -- Extra pixels between lines.
    wrap_indent     = 12,           -- Indent for wrapped continuation rows.
    inline_colors   = true,         -- Use the game's own colors for items, key items, etc.
    locked          = false,
    menu_mode       = 'fade',       -- While a game menu is open: 'fade', 'hide' or 'off'.
    menu_alpha      = 0.15,         -- Opacity when faded.
    menu_slide      = true,         -- Slide the chat right for game menus instead of fading it.
    slide_auto      = true,         -- Slide just past the open menu's right edge. (Reads its size.)
    slide_margin    = 20,           -- Gap between the menu and the chat when sliding automatically.
    item_info_slide = 700,          -- Slide distance in item lists, to clear the item details box.
    slide_dist      = 400,          -- Fixed slide distance when slide_auto is off. (Also set by dragging it while slid.)
    show_mode_ids   = false,        -- Prefix lines with their chat mode id. (For '/schat map'.)
    windows = T{
        main = T{ x = 20,  y = 480, w = 520, h = 260, visible = true, tab = '' },
        log  = T{ x = 560, y = 480, w = 460, h = 260, visible = true, tab = '' },
    },
    mode_overrides  = T{ },         -- [tostring(mode)] = category
    colors          = T{ },         -- [style key] = { r, g, b, a }
};

-- Category sets used by tab filters.
local function cats(...)
    local t = { };
    for _, v in ipairs({ ... }) do
        t[v] = true;
    end
    return t;
end

local ALL       = cats(unpack(modes.categories));
local NOCOMBAT  = cats('say', 'shout', 'yell', 'emote', 'tell', 'party', 'linkshell', 'linkshell2', 'unity', 'npc', 'system');
local MESSAGES  = cats('tell', 'party', 'linkshell', 'linkshell2');
local SYSTEM    = cats('system', 'npc');
local COMBAT    = cats('combat');

-- Window/tab layouts.
local layouts = {
    single = {
        { id = 'main', title = 'Chat', tabs = {
            { name = 'All',      cats = ALL },
            { name = 'Combat',   cats = COMBAT },
            { name = 'Messages', cats = MESSAGES, notify = true },
            { name = 'System',   cats = SYSTEM },
        } },
    },
    dual = {
        { id = 'main', title = 'Chat', tabs = {
            { name = 'General',  cats = NOCOMBAT },
            { name = 'Messages', cats = MESSAGES, notify = true },
        } },
        { id = 'log', title = 'Log', tabs = {
            { name = 'Combat',   cats = COMBAT },
            { name = 'System',   cats = SYSTEM },
        } },
    },
};

-- Styles whose numbers are highlighted.
local NUMBER_STYLES = cats('combat', 'dealt', 'taken', 'heal', 'crit', 'skillchain', 'xp', 'gil');

-- Window theme. Dark, low-contrast chrome so the text stands out. Chrome that
-- only matters while interacting (border, scrollbar, resize grip) fades in with
-- 'reveal' (0 = idle, 1 = hovered / typing).
local ACCENT = { 1.00, 0.82, 0.00 };

local function theme_colors(reveal, s)
    return {
        { ImGuiCol_WindowBg,             { 0.03, 0.03, 0.045, 1.00 } },
        -- The lines area is a child window: a light, constant shade behind the
        -- text for readability (see lines_shade), on top of the window background.
        { ImGuiCol_ChildBg,              { 0.00, 0.00, 0.00, s.lines_shade or 0.20 } },
        { ImGuiCol_Border,               { 1.00, 1.00, 1.00, 0.09 * reveal } },
        { ImGuiCol_ScrollbarBg,          { 0.00, 0.00, 0.00, 0.00 } },
        { ImGuiCol_ScrollbarGrab,        { 1.00, 1.00, 1.00, 0.20 * reveal } },
        { ImGuiCol_ScrollbarGrabHovered, { 1.00, 1.00, 1.00, 0.35 } },
        { ImGuiCol_ScrollbarGrabActive,  { ACCENT[1], ACCENT[2], ACCENT[3], 0.60 } },
        { ImGuiCol_ResizeGrip,           { 1.00, 1.00, 1.00, 0.10 * reveal } },
        { ImGuiCol_ResizeGripHovered,    { ACCENT[1], ACCENT[2], ACCENT[3], 0.50 } },
        { ImGuiCol_ResizeGripActive,     { ACCENT[1], ACCENT[2], ACCENT[3], 0.80 } },
    };
end
local theme_vars = {
    { ImGuiStyleVar_WindowRounding,   6.0 },
    { ImGuiStyleVar_WindowPadding,    { 8, 6 } },
    { ImGuiStyleVar_WindowBorderSize, 1.0 },
    { ImGuiStyleVar_ScrollbarSize,    5.0 },
    { ImGuiStyleVar_FramePadding,     { 8, 3 } },
};

-- Speaker prefixes per category: { pattern capturing the name, WoW-style label }.
-- Labels ending in 's' are verbs ("Name says:"), the rest are tags ("[Party] Name:").
local SPEAKERS = {
    say        = { { '^([^%s:]+) : ', 'says' } },
    shout      = { { '^([^%s:]+) : ', 'shouts' } },
    yell       = { { '^([^%s%[]+)%[[^%]]*%]: ', 'yells' }, { '^([^%s:]+) : ', 'yells' } },
    party      = { { '^%(([^%)]+)%) ', 'Party' } },
    linkshell  = { { '^<([^>]+)> ', 'LS' } },
    linkshell2 = { { '^%[2%]<([^>]+)> ', 'LS2' }, { '^<([^>]+)> ', 'LS2' } },
    unity      = { { '^{([^}]+)} ', 'Unity' } },
    tell       = { { '^([^%s>]+)>> ', 'From' }, { '^>>([^%s:]+) : ', 'To' } },
};

-- Addon State
local state = {
    settings    = settings.load(default_settings),
    history     = T{ },     -- Every captured line, used to rebuild tabs on layout changes.
    windows     = { },      -- Runtime windows built from the current layout.
    config_open = { false },
    party       = { },      -- Cached party/alliance member names.
    party_time  = 0,
    fade        = 1.0,      -- Chat window opacity multiplier. (Lowered while game menus are open.)
    slide_on    = false,    -- A game menu wants the chat slid aside. (See update_fade)
    captured    = 0,        -- Lines captured this session. (For '/schat status'.)
    blocked     = 0,        -- Lines hidden from the game's log this session.
};

--[[
* Writes an error (once per distinct message) to error.log in the addon folder.
* Errors can't be shown reliably in chat: they would be routed through the
* failing chat window, and the game's log may be hidden.
--]]
local logged_errors = { };
local function log_error(where, err)
    local msg = tostring(err);
    if (logged_errors[msg]) then
        return;
    end
    logged_errors[msg] = true;
    state.last_error = ('%s: %s'):fmt(where, msg:match('^[^\n]*'));

    local dir = addon.path or (AshitaCore:GetInstallPath():gsub('\\$', '') .. '\\addons\\slowedchat\\');
    local f = io.open(dir:gsub('[\\/]$', '') .. '\\error.log', 'a');
    if (f ~= nil) then
        f:write(('[%s] %s\n%s\n\n'):fmt(os.date('%Y-%m-%d %H:%M:%S'), where, msg));
        f:close();
    end
end

--[[
* Runs fn, logging any error instead of letting it stop the addon's event.
--]]
local function trap(where, fn, ...)
    local ok, err = xpcall(fn, debug.traceback, ...);
    if (not ok) then
        log_error(where, err);
    end
    return ok;
end

--[[
* Returns the names of the player's party and alliance members. (Cached for a second.)
--]]
local function party_names()
    local now = os.clock();
    if (now - state.party_time < 1.0) then
        return state.party;
    end
    state.party_time = now;

    local names = { };
    local party = AshitaCore:GetMemoryManager():GetParty();
    for i = 0, 17 do
        if (party:GetMemberIsActive(i) == 1) then
            local n = party:GetMemberName(i);
            if (n ~= nil and #n > 0) then
                names[#names + 1] = n;
            end
        end
    end
    state.party = names;
    return names;
end

--[[
* Converts parsed spans into render spans, splitting out numbers when the style highlights them.
--]]
local function build_spans(parsed, style, cat)
    local out = { };
    local numbers = NUMBER_STYLES[style];

    -- Pull the speaker prefix ("(Name) ", "<Name> ", "Name>> " ...) out of the
    -- message; the renderer draws it in the FFXI or WoW style. (See render.lua)
    local speaker = nil;
    local first = parsed[1];
    if (first ~= nil and first.fx == nil and SPEAKERS[cat] ~= nil) then
        for _, sp in ipairs(SPEAKERS[cat]) do
            local _, b, name = first.text:find(sp[1]);
            if (b ~= nil) then
                speaker = { prefix = first.text:sub(1, b), name = name, label = sp[2] };
                parsed = { { text = first.text:sub(b + 1), fx = nil }, unpack(parsed, 2) };
                break;
            end
        end
    end

    for _, sp in ipairs(parsed) do
        local key = sp.fx or 'base';
        if (numbers and key == 'base') then
            local pos = 1;
            for a, num, b in sp.text:gmatch('()(%d[%d,]*)()') do
                if (a > pos) then
                    out[#out + 1] = { text = sp.text:sub(pos, a - 1), key = 'base' };
                end
                out[#out + 1] = { text = num, key = 'number' };
                pos = b;
            end
            if (pos <= #sp.text) then
                out[#out + 1] = { text = sp.text:sub(pos), key = 'base' };
            end
        else
            out[#out + 1] = { text = sp.text, key = key };
        end
    end
    return out, speaker;
end

--[[
* Returns true if someone else's chat line mentions the player by name.
--]]
local function mentions_me(speaker, text)
    local me = AshitaCore:GetMemoryManager():GetParty():GetMemberName(0);
    if (speaker == nil or me == nil or #me == 0 or speaker.name == me) then
        return false;
    end
    local body = text:sub(#speaker.prefix + 1):lower();
    local name = me:lower();
    local a, b = body:find(name, 1, true);
    while (a ~= nil) do
        -- Whole word only..
        local before = (a > 1) and body:sub(a - 1, a - 1) or ' ';
        local after = body:sub(b + 1, b + 1);
        if (not before:match('%w') and not after:match('%w')) then
            return true;
        end
        a, b = body:find(name, b + 1, true);
    end
    return false;
end

--[[
* Rebuilds the runtime windows/tabs from the current layout and history.
--]]
local function build_windows()
    local layout = layouts[state.settings.layout] or layouts.single;
    state.windows = { };

    for _, w in ipairs(layout) do
        local win = { id = w.id, title = w.title, tabs = { }, open = { true }, select = nil };
        for i, t in ipairs(w.tabs) do
            local tab = { name = t.name, cats = t.cats, notify = t.notify, lines = { }, unread = false, scroll = true };
            for _, e in ipairs(state.history) do
                if (tab.cats[e.cat]) then
                    table.insert(tab.lines, e);
                end
            end
            while (#tab.lines > state.settings.max_lines) do
                table.remove(tab.lines, 1);
            end
            if (t.name == state.settings.windows[w.id].tab) then
                win.select = i;
            end
            table.insert(win.tabs, tab);
        end
        table.insert(state.windows, win);
    end
end

--[[
* Adds a captured line to the history and every matching tab.
--]]
local function push_line(e)
    state.history:append(e);
    while (#state.history > state.settings.max_lines * 4) do
        table.remove(state.history, 1);
    end

    for _, win in ipairs(state.windows) do
        for i, tab in ipairs(win.tabs) do
            if (tab.cats[e.cat]) then
                table.insert(tab.lines, e);
                if (#tab.lines > state.settings.max_lines) then
                    table.remove(tab.lines, 1);
                end
                -- Counted for the "N new" jump button while scrolled up..
                if (tab.scrolled_up) then
                    tab.new_below = (tab.new_below or 0) + 1;
                end
                -- Only tabs that opt in (Messages) get the unread marker; the busy
                -- ones would always be lit..
                if (tab.notify and win.active ~= i) then
                    tab.unread = true;
                end
            end
        end
    end
end

local function clear_all()
    state.history = T{ };
    build_windows();
end

local function copy_line(e)
    imgui.SetClipboardText(e.text);
    print(chat.header(addon.name):append(chat.message('Line copied to clipboard.')));
end

--[[
* Registers a callback for the settings to monitor for character switches.
--]]
settings.register('settings', 'settings_update', function (s)
    if (s ~= nil) then
        state.settings = s;
    end
    render.version = render.version + 1;
    build_windows();
    input.restore(state.settings);
    -- Move the windows to this character's saved position/size. (ImGui only
    -- applies FirstUseEver once, so existing windows would otherwise stay put
    -- and overwrite this character's saved layout.)
    state.reset_pos = true;
    settings.save();
end);

--[[
* Prints the addon help information.
--]]
local function print_help(isError)
    if (isError) then
        print(chat.header(addon.name):append(chat.error('Invalid command syntax for command: ')):append(chat.success('/schat')));
    else
        print(chat.header(addon.name):append(chat.message('Available commands:')));
    end

    local cmds = T{
        { '/schat', 'Toggles the settings window.' },
        { '/schat layout (single | dual)', 'One tabbed window, or Chat + Log windows.' },
        { '/schat native', 'Toggles hiding the game\'s own chat log.' },
        { '/schat fade','With a game menu open: toggles whether that menu fades the chat.' },
        { '/schat window','Toggles hiding the game\'s chat windows themselves.' },
        { '/schat input','Toggles using slowedchat\'s input bar instead of the game\'s.' },
        { '/schat status', 'Prints diagnostic information.' },
        { '/schat lock', 'Toggles locking the chat windows in place.' },
        { '/schat clear', 'Clears all chat tabs.' },
        { '/schat debug', 'Toggles showing chat mode ids on each line.' },
        { '/schat map <mode> <category>', 'Moves a chat mode into a category.' },
        { '/schat unmap <mode>', 'Removes a chat mode override.' },
    };

    cmds:ieach(function (v)
        print(chat.header(addon.name):append(chat.error('Usage: ')):append(chat.message(v[1]):append(' - ')):append(chat.color1(6, v[2])));
    end);
    print(chat.header(addon.name):append(chat.message('Categories: ')):append(chat.color1(6, modes.categories:concat(', '))));
end

--[[
* event: load
--]]
ashita.events.register('load', 'load_cb', function ()
    -- Fonts must be added here, never mid-frame. (See fonts.lua)
    fonts.prewarm();
    build_windows();
    input.restore(state.settings);
end);

--[[
* event: unload
--]]
ashita.events.register('unload', 'unload_cb', function ()
    nativechat.restore();
    hud.restore();
    settings.save();
end);

--[[
* event: command
--]]
ashita.events.register('command', 'command_cb', function (e)
    local args = e.command:args();
    if (#args == 0 or not args[1]:any('/schat', '/slowedchat')) then
        return;
    end

    e.blocked = true;
    local s = state.settings;

    if (#args == 1 or args[2]:any('config', 'cfg')) then
        state.config_open[1] = not state.config_open[1];
        return;
    end

    if (args[2]:any('help')) then
        print_help(false);
        return;
    end

    if (#args == 3 and args[2]:any('layout') and layouts[args[3]:lower()] ~= nil) then
        s.layout = args[3]:lower();
        build_windows();
        settings.save();
        return;
    end

    if (args[2]:any('native')) then
        s.hide_native = not s.hide_native;
        settings.save();
        print(chat.header(addon.name):append(chat.message('Game chat log is now ')):append(chat.success(s.hide_native and 'hidden' or 'shown')));
        return;
    end

    -- Handle: /schat menudump - Writes the open menu's raw data to menudump.log.
    -- (Research: finding where the game keeps a menu's on-screen size/position.)
    if (args[2]:any('menudump')) then
        local header = input.menu_header();
        local name = input.menu_name();
        if (header == nil or name == '') then
            print(chat.header(addon.name):append(chat.error('No game menu is open. Open one, then press / and type /schat menudump.')));
            return;
        end

        local dir = addon.path or (AshitaCore:GetInstallPath():gsub('\\$', '') .. '\\addons\\slowedchat\\');
        local f = io.open(dir:gsub('[\\/]$', '') .. '\\menudump.log', 'a');
        if (f == nil) then
            print(chat.header(addon.name):append(chat.error('Could not write menudump.log.')));
            return;
        end

        local w, h = imgui.GetIO().DisplaySize and imgui.GetIO().DisplaySize.x, imgui.GetIO().DisplaySize and imgui.GetIO().DisplaySize.y;
        f:write(('[%s] menu "%s" header 0x%08X screen %sx%s\n'):fmt(os.date('%H:%M:%S'), name, header, tostring(w), tostring(h)));
        for row = 0, 0x17F, 16 do
            local hex, s16 = { }, { };
            for i = 0, 15 do
                hex[#hex + 1] = ('%02X'):fmt(ashita.memory.read_uint8(header + row + i));
            end
            for i = 0, 14, 2 do
                s16[#s16 + 1] = ('%6d'):fmt(ashita.memory.read_int16(header + row + i));
            end
            f:write(('  +%03X  %s  | %s\n'):fmt(row, table.concat(hex, ' '), table.concat(s16, ' ')));
        end

        -- Every menu block near this one: name (at +0x46) and raw rectangle
        -- (4 int16 at +0x10). Read-only; the region is checked readable first.
        local span = 0x8000;
        local start = header - span;
        local ok_read = nativechat.valid(start, span * 2, false);
        if (not ok_read) then
            start, span = header, span;     -- Fall back to just after the header..
            ok_read = nativechat.valid(start, span, false);
        end
        if (ok_read) then
            local size = (start == header) and span or span * 2;
            local blob = ffi.string(ffi.cast('const char*', start), size);
            local function i16(o)
                local lo, hi = blob:byte(o + 1), blob:byte(o + 2);
                local v = lo + hi * 256;
                return (v >= 0x8000) and (v - 0x10000) or v;
            end
            f:write('  nearby menu blocks (offset from focused, name, raw x1 y1 x2 y2):\n');
            local pos = 1;
            while (true) do
                local a = blob:find('menu    ', pos, true);
                if (a == nil) then
                    break;
                end
                local o = (a - 1) - 0x46;       -- Block start, relative to blob.
                if (o >= 0 and o + 0x18 <= #blob) then
                    local nm = blob:sub(a, a + 15):gsub('%z.*', '');
                    f:write(('    %+7d  %-16s  %5d %5d %5d %5d\n'):fmt((start + o) - header, nm,
                        i16(o + 0x10), i16(o + 0x12), i16(o + 0x14), i16(o + 0x16)));
                end
                pos = a + 8;
            end
        else
            f:write('  (nearby memory not readable; skipped)\n');
        end

        -- Follow each of the block's first pointers as a chain, logging any menu
        -- reached (directly, or via a node whose +4 points at a menu block, like
        -- the focused-menu chain). Looking for the list of open windows.
        local function menu_at(p)
            if (p == 0 or not nativechat.valid(p + 0x10, 0x46, false)) then
                return nil;
            end
            local nm = ffi.string(ffi.cast('const char*', p + 0x46), 16):gsub('%z.*', '');
            if (nm:sub(1, 8) ~= 'menu    ') then
                return nil;
            end
            return nm, ashita.memory.read_int16(p + 0x10), ashita.memory.read_int16(p + 0x12),
                ashita.memory.read_int16(p + 0x14), ashita.memory.read_int16(p + 0x16);
        end
        for _, off in ipairs({ 0x04, 0x08, 0x0C }) do
            f:write(('  chain via +0x%02X:\n'):fmt(off));
            local p, seen = header, { };
            for step = 1, 24 do
                if (p == 0 or seen[p] or not nativechat.valid(p + off, 4, false)) then
                    break;
                end
                seen[p] = true;
                p = ashita.memory.read_uint32(p + off);
                local nm, a, b, c, d = menu_at(p);
                local via = '';
                if (nm == nil and p ~= 0 and nativechat.valid(p + 4, 4, false)) then
                    nm, a, b, c, d = menu_at(ashita.memory.read_uint32(p + 4));
                    via = ' (via +4)';
                end
                if (nm ~= nil) then
                    f:write(('    %2d  0x%08X  %-16s  %5d %5d %5d %5d%s\n'):fmt(step, p, nm, a, b, c, d, via));
                else
                    f:write(('    %2d  0x%08X  (not a menu)\n'):fmt(step, p));
                end
            end
        end

        f:write('\n');
        f:close();
        print(chat.header(addon.name):append(chat.message('Menu data written to menudump.log for: ')):append(chat.success(input.short_name(name))));
        return;
    end

    -- Handle: /schat fade - Toggles whether the game menu that's open now fades the chat.
    if (args[2]:any('fade')) then
        local name = input.menu_name();
        local short = input.short_name(name);
        if (name == '' or short == 'inline' or (s.chat_menus and s.chat_menus[name])) then
            print(chat.header(addon.name):append(chat.error('No game menu is open. Open the menu first, then press / and type /schat fade.')));
            return;
        end

        -- Flip whatever it does now; drop the choice when it matches the default..
        s.menu_fade = s.menu_fade or T{ };
        local fades = not input.game_menu_open(s);
        local default = not input.right_side(name);
        if (fades == default) then
            s.menu_fade[name] = nil;
        else
            s.menu_fade[name] = fades;
        end

        print(chat.header(addon.name):append(chat.message(fades and 'Chat now fades for: ' or 'Chat no longer fades for: ')):append(chat.success(short)));
        settings.save();
        return;
    end

    if (args[2]:any('window')) then
        s.hide_window = not s.hide_window;
        settings.save();
        print(chat.header(addon.name):append(chat.message('Game chat windows: ')):append(chat.success(s.hide_window and 'hidden' or 'shown')));
        return;
    end

    if (args[2]:any('input')) then
        s.custom_input = not s.custom_input;
        input.close(true);
        settings.save();
        print(chat.header(addon.name):append(chat.message('Chat input: ')):append(chat.success(s.custom_input and 'slowedchat' or 'game')));
        return;
    end

    if (args[2]:any('status')) then
        local function line(k, v)
            print(chat.header(addon.name):append(chat.message(k .. ': ')):append(chat.color1(6, tostring(v))));
        end
        line('Hide game chat log', s.hide_native);
        line('Lines captured / hidden this session', ('%d / %d'):fmt(state.captured, state.blocked));
        line('Hide game chat windows', ('%s (%s)'):fmt(tostring(s.hide_window), nativechat.status));
        line('Custom input', s.custom_input);
        line('Game menu at last Enter press', ('"%s"'):fmt(input.last_enter_menu or '(none yet)'));
        line('Last reason Enter was left to the game', input.last_refusal or 'none');
        local choices = T{ };
        for k, v in pairs(s.menu_fade or { }) do
            choices:append(('%s %s'):fmt(input.short_name(k), v and '(fades)' or '(doesn\'t fade)'));
        end
        line('Menu fade overrides', #choices > 0 and choices:concat(', ') or 'none (every menu slides/fades the chat)');
        line('Game menu open now (fades chat)', ('%s "%s"'):fmt(tostring(input.game_menu_open(s)), input.menu_name()));
        local ml, mt, mr, mb = input.menu_rect();
        if (ml ~= nil) then
            ml, mt, mr, mb = math.floor(ml), math.floor(mt), math.floor(mr), math.floor(mb);
        end
        local cw = s.windows.main;
        line('Open menu on screen / chat window', ml and ('x %d-%d y %d-%d  /  x %d-%d y %d-%d'):fmt(ml, mr, mt, mb, cw.x, cw.x + cw.w, cw.y, cw.y + cw.h) or 'no menu');
        local learned = T{ };
        for k, _ in pairs(s.chat_menus or { }) do
            learned:append(('"%s"'):fmt(k));
        end
        line('Learned chat menus', #learned > 0 and learned:concat(', ') or 'none');        line('Game input state', tostring(AshitaCore:GetChatManager():IsInputOpen()));
        line('Last capture error', state.last_error or 'none');
        line('Auto-translate phrases', autotranslate.error and ('off - ' .. autotranslate.error)
            or (autotranslate.ready and #autotranslate.list or 'not checked yet'));
        if (s.hide_native) then
            print(chat.header(addon.name):append(chat.warning('TEST LINE: if you can read this in the game\'s own chat log, hiding is not working.')));
        end
        return;
    end

    if (args[2]:any('lock')) then
        s.locked = not s.locked;
        settings.save();
        return;
    end

    if (args[2]:any('clear')) then
        clear_all();
        return;
    end

    if (args[2]:any('debug')) then
        s.show_mode_ids = not s.show_mode_ids;
        render.version = render.version + 1;
        settings.save();
        return;
    end

    if (#args == 4 and args[2]:any('map')) then
        local mode = tonumber(args[3]);
        local cat = args[4]:lower();
        if (mode ~= nil and modes.valid[cat]) then
            s.mode_overrides[tostring(mode)] = cat;
            settings.save();
            print(chat.header(addon.name):append(chat.message(('Mode %d -> %s'):fmt(mode, cat))));
            return;
        end
    end

    if (#args == 3 and args[2]:any('unmap')) then
        local mode = tonumber(args[3]);
        if (mode ~= nil) then
            s.mode_overrides[tostring(mode)] = nil;
            settings.save();
            return;
        end
    end

    print_help(true);
end);

--[[
* event: text_in
--]]
ashita.events.register('text_in', 'text_in_cb', function (e)
    if (e.blocked) then
        return;
    end

    local mode = bit.band(e.mode_modified, 0x000000FF);

    -- Skip NPC chat reinjections. (The original line was already captured.)
    if (mode == 190) then
        e.blocked = state.settings.hide_native and state.settings.hide_npc;
        return;
    end

    local is_npc = false;

    -- Printing from here can deadlock, so errors are kept for '/schat status' instead..
    local ok, err = pcall(function ()
        -- Read the line as the game sent it, before other addons touched it:
        -- e.g. the timestamp addon prefixes a colored stamp that would hide the
        -- speaker. (slowedchat draws its own timestamps.)
        local parsed, text = cleaner.parse(e.message);
        if (#text == 0) then
            return;
        end

        local cat = modes.classify(mode, state.settings.mode_overrides);
        is_npc = cat == 'npc';
        local style = modes.style(cat, text, party_names());
        input.on_line(mode, text);
        state.captured = state.captured + 1;
        local spans, speaker = build_spans(parsed, style, cat);
        push_line({
            time    = os.time(),
            mode    = mode,
            cat     = cat,
            style   = style,
            text    = text,
            spans   = spans,
            speaker = speaker,
            mention = mentions_me(speaker, text),
        });
    end);

    if (not ok) then
        state.last_error = tostring(err);
        return;
    end

    -- NPC dialog stays in the game's log unless asked; some NPC menus depend on it..
    if (state.settings.hide_native and (state.settings.hide_npc or not is_npc)) then
        e.blocked = true;
        state.blocked = state.blocked + 1;
    end
end);

--[[
* events: key / key_data / key_state
* desc  : Opens slowedchat's input on Enter or '/' and keeps keys from the game while typing.
--]]
ashita.events.register('key', 'key_cb', function (e)
    trap('key', input.on_key, e, state.settings);
end);

ashita.events.register('key_data', 'key_data_cb', function (e)
    trap('key_data', input.on_key_data, e, state.settings);
end);

ashita.events.register('key_state', 'key_state_cb', function (e)
    trap('key_state', input.on_key_state, e, state.settings);
end);

--[[
* Renders the lines of a tab inside a scrolling child region.
--]]
local function u32(r, g, b, a)
    return imgui.GetColorU32({ r, g, b, a });
end

--[[
* Draws the "jump to latest" pill at the bottom-right of the lines area.
* Returns true when clicked.
--]]
local function jump_button(tab)
    local dl = imgui.GetWindowDrawList();
    local font, fs = imgui.GetFont(), imgui.GetFontSize();
    local lh = imgui.GetTextLineHeight();
    local wx, wy = imgui.GetWindowPos();
    local ww, wh = imgui.GetWindowSize();

    local n = tab.new_below or 0;
    local label = (n > 0) and ('%d new'):fmt(n) or 'Latest';
    local tw = imgui.CalcTextSize(label);
    local pw, ph = tw + 30, lh + 8;
    local px, py = wx + ww - pw - 12, wy + wh - ph - 6;

    imgui.SetCursorScreenPos({ px, py });
    local clicked = imgui.InvisibleButton('##jump', { pw, ph });
    local hovered = imgui.IsItemHovered();

    local border = (n > 0) and u32(ACCENT[1], ACCENT[2], ACCENT[3], 0.85) or u32(1, 1, 1, 0.25);
    dl:AddRectFilled({ px, py }, { px + pw, py + ph }, hovered and u32(0.18, 0.18, 0.22, 0.95) or u32(0.08, 0.08, 0.10, 0.92), ph * 0.5);
    dl:AddRect({ px, py }, { px + pw, py + ph }, border, ph * 0.5, ImDrawFlags_None, 1.0);

    -- Down arrow..
    local cx, cy = px + 13, py + ph * 0.5;
    local arrow = (n > 0) and u32(ACCENT[1], ACCENT[2], ACCENT[3], 1.0) or u32(0.85, 0.85, 0.85, 1.0);
    dl:AddTriangleFilled({ cx - 4, cy - 2 }, { cx + 4, cy - 2 }, { cx, cy + 3 }, arrow);
    dl:AddText(font, fs, { px + 22, py + 4 }, u32(0.92, 0.92, 0.92, 1.0), label);

    return clicked;
end

local function render_lines(tab, footer)
    imgui.BeginChild('##lines', { 0, -footer }, ImGuiChildFlags_None, ImGuiWindowFlags_None);

    -- Stay pinned to the bottom unless the user has scrolled up..
    local at_bottom = imgui.GetScrollY() >= imgui.GetScrollMaxY() - 2;

    imgui.PushStyleVar(ImGuiStyleVar_ItemSpacing, { 0, state.settings.line_gap });
    render.lines(tab.lines, state.settings, copy_line, state.font_ctx);
    imgui.PopStyleVar();

    -- Breathing room under the newest line..
    imgui.Dummy({ 0, 6 });

    if (at_bottom or tab.scroll) then
        imgui.SetScrollHereY(1.0);
        tab.scroll = false;
        tab.scrolled_up = false;
        tab.new_below = 0;
    else
        tab.scrolled_up = true;
        if (jump_button(tab)) then
            tab.scroll = true;
        end
    end

    imgui.EndChild();
end

--[[
* Selects a tab in a window.
--]]
local function select_tab(win, ws, i)
    local tab = win.tabs[i];
    if (tab == nil) then
        return;
    end
    win.active = i;
    tab.scroll = true;
    tab.unread = false;
    if (ws.tab ~= tab.name) then
        ws.tab = tab.name;
        state.pending_save = true;
    end
end

--[[
* Draws the tab strip: flat text tabs with an accent underline on the selected
* one, a pulsing dot on tabs with unread messages, and a settings button.
--]]
local function render_tabs(win, ws, reveal)
    local s = state.settings;
    local dl = imgui.GetWindowDrawList();
    local font, fs = imgui.GetFont(), imgui.GetFontSize();
    local lh = imgui.GetTextLineHeight();
    local fh = imgui.GetFrameHeight();
    local x0, y0 = imgui.GetCursorScreenPos();
    local avail = imgui.GetContentRegionAvail();
    local pad = 9;

    if (win.active == nil) then
        select_tab(win, ws, win.select or 1);
        win.select = nil;
    end

    local dim = 0.55 + 0.35 * reveal;
    local dot = palette.get('tell', s.colors) or { 1, 0.5, 1, 1 };
    local pulse = 0.55 + 0.45 * math.sin(os.clock() * 5.0);

    local x = x0;
    for i, tab in ipairs(win.tabs) do
        local tw = imgui.CalcTextSize(tab.name);
        local w = tw + pad * 2 + (tab.unread and 9 or 0);

        imgui.SetCursorScreenPos({ x, y0 });
        if (imgui.InvisibleButton(('##tab_%s_%d'):fmt(win.id, i), { w, fh })) then
            select_tab(win, ws, i);
        end
        local hovered = imgui.IsItemHovered();
        local selected = (win.active == i);

        if (selected) then
            dl:AddRectFilled({ x, y0 }, { x + w, y0 + fh }, u32(1, 1, 1, 0.07), 4.0, ImDrawFlags_RoundCornersTop);
            dl:AddRectFilled({ x + 5, y0 + fh - 2 }, { x + w - 5, y0 + fh }, u32(ACCENT[1], ACCENT[2], ACCENT[3], 1.0), 1.0);
        elseif (hovered) then
            dl:AddRectFilled({ x, y0 }, { x + w, y0 + fh }, u32(1, 1, 1, 0.04), 4.0, ImDrawFlags_RoundCornersTop);
        end

        local tc;
        if (selected) then
            tc = u32(1.0, 1.0, 1.0, 1.0);
        elseif (hovered) then
            tc = u32(0.90, 0.90, 0.92, 1.0);
        else
            tc = u32(0.62, 0.62, 0.66, dim);
        end
        local ty = y0 + (fh - lh) * 0.5;
        dl:AddText(font, fs, { x + pad + 1, ty + 1 }, u32(0, 0, 0, 0.7 * dim), tab.name);
        dl:AddText(font, fs, { x + pad, ty }, tc, tab.name);

        if (tab.unread) then
            dl:AddCircleFilled({ x + pad + tw + 7, y0 + fh * 0.5 }, 3.0, u32(dot[1], dot[2], dot[3], pulse), 12);
        end

        x = x + w + 2;
    end

    -- Settings button (three bars) at the right..
    local bx = x0 + avail - fh;
    imgui.SetCursorScreenPos({ bx, y0 });
    if (imgui.InvisibleButton(('##cfg_%s'):fmt(win.id), { fh, fh })) then
        state.config_open[1] = not state.config_open[1];
    end
    local bc = imgui.IsItemHovered() and u32(1, 1, 1, 0.95) or u32(0.62, 0.62, 0.66, 0.9 * reveal);
    local cx, cy = bx + fh * 0.5, y0 + fh * 0.5;
    for k = -1, 1 do
        dl:AddRectFilled({ cx - 5, cy + k * 4 - 0.5 }, { cx + 5, cy + k * 4 + 1 }, bc, 0.5);
    end

    -- Vana'diel day and time, right-aligned before the settings button. (Main
    -- window only; the day name is dropped first when space runs out.)
    if (s.show_time and win.id == 'main') then
        local hh, mm, d = hud.vana_time();
        local day = hud.DAYS[d] or hud.DAYS[0];
        local time = ('%02d:%02d'):fmt(hh, mm);
        local tw = imgui.CalcTextSize(time);
        local dw = imgui.CalcTextSize(day[1] .. '  ');
        local ty = y0 + (fh - lh) * 0.5;
        local right = bx - 6;

        local show_day = (right - tw - dw) > x + 8;
        if (show_day or (right - tw) > x + 8) then
            local tx = right - tw;
            if (show_day) then
                local c = day[2];
                dl:AddText(font, fs, { tx - dw + 1, ty + 1 }, u32(0, 0, 0, 0.7), day[1]);
                dl:AddText(font, fs, { tx - dw, ty }, u32(c[1], c[2], c[3], 0.75 + 0.25 * reveal), day[1]);
            end
            dl:AddText(font, fs, { tx + 1, ty + 1 }, u32(0, 0, 0, 0.7), time);
            dl:AddText(font, fs, { tx, ty }, u32(0.85, 0.85, 0.88, 0.75 + 0.25 * reveal), time);
        end
    end

    -- Hairline under the strip..
    dl:AddLine({ x0, y0 + fh + 0.5 }, { x0 + avail, y0 + fh + 0.5 }, u32(1, 1, 1, 0.06 + 0.06 * reveal), 1.0);

    imgui.SetCursorScreenPos({ x0, y0 + fh + 4 });
end

--[[
* Returns true for item-list menus (inventory, bags), which show an item
* details box. The box is a display, not a menu, and couldn't be found in
* memory, so these slide a fixed distance (item_info_slide) instead of fitting.
* 'inventor' is confirmed; the other name fragments are best guesses.
--]]
local ITEM_LISTS = { 'invent', 'item', 'bag', 'sack', 'case', 'wardrob', 'safe', 'stora', 'locker' };
local function is_item_list(short)
    for _, p in ipairs(ITEM_LISTS) do
        if (short:find(p, 1, true)) then
            return true;
        end
    end
    return false;
end

--[[
* Eases the chat windows toward faded/hidden while a game menu is open.
*
* ImGui always draws above the game's own UI, so the windows can't sit behind a
* menu; instead they fade (and let clicks through) or hide until it closes.
--]]
local function update_fade()
    local s = state.settings;

    -- Game menus (the player menu is always up while engaged) slide the chat
    -- aside instead of fading it, when enabled. NPC conversations never fade
    -- it on their own: their dialog is read here. (Dialogue options are a
    -- menu, so the chat slides out of their way like any other.)
    local menu = input.game_menu_open(s);
    local slide = s.menu_slide and menu;

    local target = 1.0;
    if (s.menu_mode ~= 'off' and not input.active and not slide and menu) then
        target = (s.menu_mode == 'hide') and 0.0 or s.menu_alpha;
    end

    local dt = imgui.GetIO().DeltaTime or 0.016;
    local k = math.min(1.0, dt * 12.0);

    state.fade = state.fade + (target - state.fade) * k;
    if (math.abs(target - state.fade) < 0.01) then
        state.fade = target;
    end

    -- What the windows slide past: the open menu's screen rectangle (auto), or
    -- the fixed distance. (Each window works out its own offset in render_window.)
    state.slide_on = slide;
    state.menu_rect = nil;
    state.menu_items = slide and is_item_list(input.short_name(input.menu_name()));
    if (slide and s.slide_auto) then
        local l, t, r, b = input.menu_rect();
        if (l ~= nil) then
            state.menu_rect = { l, t, r, b };
        end
    end
end

--[[
* Returns how far (pixels) a chat window should sit to the right of its saved
* position right now, and whether it's in the manual, drag-to-set mode.
--]]
local function slide_target(s, ws)
    if (not state.slide_on) then
        return 0, false;
    end
    -- Item lists: the item details box is a display, not a menu, so its size
    -- and place can't be read. Slide a fixed distance for it, whether or not
    -- the list itself overlaps the chat..
    if (state.menu_items) then
        return s.item_info_slide, false;
    end

    local m = state.menu_rect;
    if (s.slide_auto and m ~= nil) then
        -- Only move for a menu that overlaps this window horizontally; menus
        -- further right are ignored. (Vertical isn't checked: the game's y
        -- values proved relative to something else, not screen positions.)
        local l, r = m[1], m[3];
        if (l >= ws.x + ws.w or r <= ws.x) then
            return 0, false;
        end
        -- ..and then just clear its right edge.
        return math.max(0, r + s.slide_margin - ws.x), false;
    end
    return s.slide_dist, not s.slide_auto;
end

--[[
* Renders one chat window.
--]]
local function render_window(win)
    local s = state.settings;
    local ws = s.windows[win.id];
    -- Hidden, or stepped back while a game menu is open. (See update_fade)
    if (not ws.visible or state.fade <= 0.01) then
        return;
    end

    -- Ease toward revealed (hovered / typing / settings open) or idle..
    local target = 1.0;
    if (s.hover_reveal and not win.hovered and not (win.id == 'main' and input.active) and not state.config_open[1]) then
        target = 0.0;
    end
    local dt = imgui.GetIO().DeltaTime or 0.016;
    win.reveal = (win.reveal or 1.0) + (target - (win.reveal or 1.0)) * math.min(1.0, dt * 10.0);
    local reveal = win.reveal;

    -- Slid aside for a game menu: ease the offset toward the target (which
    -- follows the menu's size in auto mode). In manual mode, once fully aside
    -- the window is left free so dragging it sets the distance.
    local goal, manual = slide_target(s, ws);
    local off = win.slide_px or 0;
    off = off + (goal - off) * math.min(1.0, dt * 12.0);
    if (math.abs(goal - off) < 0.5) then
        off = goal;
    end
    win.slide_px = off;

    local slid = manual and off == goal and goal > 0;   -- Manual, fully aside: free to drag.
    local sliding = off > 0 and not slid;               -- Placed by us this frame.
    local cond = state.reset_pos and ImGuiCond_Always or ImGuiCond_FirstUseEver;

    -- Just finished sliding back: put it exactly on its saved spot. Otherwise it
    -- stays where the last (fractional) animation frame left it, and that spot
    -- gets saved as the new position, drifting right a little every slide.
    local landing = off == 0 and (win.was_offset or false);
    win.was_offset = off > 0;

    if (sliding) then
        imgui.SetNextWindowPos({ ws.x + off, ws.y }, ImGuiCond_Always);
    elseif (landing) then
        imgui.SetNextWindowPos({ ws.x, ws.y }, ImGuiCond_Always);
    elseif (not slid) then
        imgui.SetNextWindowPos({ ws.x, ws.y }, cond);
    end
    imgui.SetNextWindowSize({ ws.w, ws.h }, cond);
    imgui.SetNextWindowBgAlpha(s.idle_bg_alpha + (s.bg_alpha - s.idle_bg_alpha) * (s.hover_reveal and reveal or 1.0));

    local flags = bit.bor(ImGuiWindowFlags_NoTitleBar, ImGuiWindowFlags_NoCollapse, ImGuiWindowFlags_NoScrollbar,
        ImGuiWindowFlags_NoSavedSettings, ImGuiWindowFlags_NoFocusOnAppearing, ImGuiWindowFlags_NoBringToFrontOnFocus);
    if (s.locked) then
        flags = bit.bor(flags, ImGuiWindowFlags_NoMove, ImGuiWindowFlags_NoResize);
    end

    -- Let clicks through to the game while faded..
    if (state.fade < 0.99) then
        flags = bit.bor(flags, ImGuiWindowFlags_NoInputs);
    end

    local colors = theme_colors(reveal, s);
    for _, c in ipairs(colors) do
        imgui.PushStyleColor(c[1], c[2]);
    end
    for _, v in ipairs(theme_vars) do
        imgui.PushStyleVar(v[1], v[2]);
    end
    imgui.PushStyleVar(ImGuiStyleVar_Alpha, state.fade);

    if (imgui.Begin(('%s##slowedchat_%s'):fmt(win.title, win.id), win.open, flags)) then
        -- Remember position/size so they survive reloads..
        -- Remember position/size (whole pixels) and save when they change..
        local x, y = imgui.GetWindowPos();
        local w, h = imgui.GetWindowSize();
        x, y = math.floor(x + 0.5), math.floor(y + 0.5);
        w, h = math.floor(w + 0.5), math.floor(h + 0.5);
        if (w ~= ws.w or h ~= ws.h) then
            ws.w, ws.h = w, h;
            state.pending_save = true;
        end
        if (slid) then
            -- Aside for the player menu: a drag sets the slide distance (and height)..
            if (math.abs((x - ws.x) - s.slide_dist) >= 1 or y ~= ws.y) then
                s.slide_dist = x - ws.x;
                ws.y = y;
                state.pending_save = true;
            end
        elseif (not sliding and (x ~= ws.x or y ~= ws.y)) then
            ws.x, ws.y = x, y;
            state.pending_save = true;
        end

        -- Hover state drives the reveal fade next frame..
        win.hovered = imgui.IsWindowHovered(bit.bor(ImGuiHoveredFlags_RootAndChildWindows, ImGuiHoveredFlags_AllowWhenBlockedByActiveItem));

        -- Chat font for the whole window (tabs, lines, input)..
        local regular, strong = fonts.get(s.font_family);
        local pushed = pcall(imgui.PushFont, regular or imgui.GetFont(), fonts.size(s.text_size));
        state.font_ctx = { regular = imgui.GetFont(), strong = strong, size = imgui.GetFontSize() };

        render_tabs(win, ws, reveal);

        local tab = win.tabs[win.active];
        if (tab ~= nil) then
            tab.unread = false;
            render_lines(tab, win.id == 'main' and input.height() or 0);
        end

        if (win.id == 'main') then
            input.render(s);
        end

        if (pushed) then
            imgui.PopFont();
        end
    end
    imgui.End();

    imgui.PopStyleVar(#theme_vars + 1);
    imgui.PopStyleColor(#colors);
end

--[[
* Renders the color pickers in the settings window.
--]]
local function render_color_config(s)
    local changed = false;

    for _, g in ipairs(palette.groups) do
        imgui.TextDisabled(g[1]);
        for i, item in ipairs(g[2]) do
            local c = palette.get(item[1], s.colors);
            local v = { c[1], c[2], c[3], c[4] };
            if (imgui.ColorEdit4(('%s##col_%s'):fmt(item[2], item[1]), v, ImGuiColorEditFlags_NoInputs)) then
                s.colors[item[1]] = { v[1], v[2], v[3], v[4] };
                changed = true;
            end
            if (i % 3 ~= 0 and i < #g[2]) then
                imgui.SameLine(8 + 160 * (i % 3));
            end
        end
        imgui.Spacing();
    end

    if (imgui.Button('Reset colors')) then
        s.colors = T{ };
        changed = true;
    end

    return changed;
end

--[[
* Renders the settings window.
--]]
local function render_config()
    if (not state.config_open[1]) then
        return;
    end

    local s = state.settings;
    local changed = false;

    local function checkbox(label, key)
        local v = { s[key] };
        if (imgui.Checkbox(label, v)) then
            s[key] = v[1];
            changed = true;
        end
    end

    local function slider(label, key, lo, hi, fmt, int)
        local v = { s[key] };
        local moved;
        if (int) then
            moved = imgui.SliderInt(label, v, lo, hi);
        else
            moved = imgui.SliderFloat(label, v, lo, hi, fmt);
        end
        if (moved) then
            s[key] = v[1];
            changed = true;
        end
    end

    local function hint(text)
        imgui.SameLine();
        imgui.TextDisabled(text);
    end

    imgui.SetNextWindowSizeConstraints({ 420, 0 }, { 700, 900 });
    imgui.PushStyleVar(ImGuiStyleVar_WindowRounding, 6.0);
    imgui.PushStyleVar(ImGuiStyleVar_FrameRounding, 3.0);
    imgui.PushStyleVar(ImGuiStyleVar_WindowPadding, { 12, 10 });
    imgui.PushStyleColor(ImGuiCol_WindowBg, { 0.05, 0.05, 0.07, 0.96 });
    imgui.PushStyleColor(ImGuiCol_Header, { 1.0, 1.0, 1.0, 0.06 });
    imgui.PushStyleColor(ImGuiCol_HeaderHovered, { 1.0, 1.0, 1.0, 0.10 });
    imgui.PushStyleColor(ImGuiCol_CheckMark, { ACCENT[1], ACCENT[2], ACCENT[3], 1.0 });
    imgui.PushStyleColor(ImGuiCol_SliderGrab, { ACCENT[1], ACCENT[2], ACCENT[3], 0.80 });

    if (imgui.Begin('slowedchat##settings', state.config_open, ImGuiWindowFlags_AlwaysAutoResize)) then
        local open = ImGuiTreeNodeFlags_DefaultOpen;

        if (imgui.CollapsingHeader('Layout', open)) then
            if (imgui.RadioButton('One window  (All / Combat / Messages / System)', s.layout == 'single')) then
                s.layout = 'single';
                build_windows();
                changed = true;
            end
            if (imgui.RadioButton('Split  (Chat window + Log window)', s.layout == 'dual')) then
                s.layout = 'dual';
                build_windows();
                changed = true;
            end
            checkbox('Lock windows', 'locked');
            imgui.Spacing();
        end

        if (imgui.CollapsingHeader('Appearance', open)) then
            checkbox('Show the background only on hover', 'hover_reveal');
            slider('Background opacity', 'bg_alpha', 0.0, 1.0, '%.2f');
            if (s.hover_reveal) then
                slider('Idle background opacity', 'idle_bg_alpha', 0.0, 1.0, '%.2f');
            end
            slider('Shade behind text', 'lines_shade', 0.0, 0.8, '%.2f');
            imgui.Spacing();
        end

        if (imgui.CollapsingHeader('Text', open)) then
            -- Font family..
            if (imgui.BeginCombo('Font', s.font_family)) then
                for _, f in ipairs(fonts.families) do
                    if (fonts.available(f.name) and imgui.Selectable(f.name, s.font_family == f.name)) then
                        s.font_family = f.name;
                        changed = true;
                    end
                end
                imgui.EndCombo();
            end
            slider('Font size', 'text_size', 0, 32, nil, true);
            imgui.SameLine();
            imgui.TextDisabled(s.text_size == 0 and ('(auto: %d px)'):fmt(fonts.size(0)) or '(0 = auto)');
            slider('Line spacing', 'line_gap', 0, 10, nil, true);

            imgui.Text('Text effect:');
            for _, m in ipairs({ { 'outline', 'Outline' }, { 'shadow', 'Shadow' }, { 'none', 'None' } }) do
                imgui.SameLine();
                if (imgui.RadioButton(m[2] .. '##effect', s.text_effect == m[1])) then
                    s.text_effect = m[1];
                    changed = true;
                end
            end

            imgui.Text('Names:');
            for _, m in ipairs({ { 'wow', '[Party] Name: hi' }, { 'ffxi', '(Name) hi' } }) do
                imgui.SameLine();
                if (imgui.RadioButton(m[2] .. '##style', s.message_style == m[1])) then
                    s.message_style = m[1];
                    changed = true;
                end
            end

            checkbox('Bold, brighter speaker names', 'speaker_names');
            checkbox('Highlight lines that mention you', 'mention_highlight');
            checkbox('Show timestamps', 'timestamps');
            checkbox('Use game colors for items / key items', 'inline_colors');
            if (s.font_family ~= 'Default') then
                imgui.TextDisabled('If Japanese text shows as "?", try the Default font.');
            end
            imgui.Spacing();
        end

        if (imgui.CollapsingHeader('Behavior', open)) then
            checkbox('Type in slowedchat  (Enter / \'/\' opens its input bar)', 'custom_input');
            imgui.Text('While a game menu is open (when not sliding):');
            for _, m in ipairs({ { 'fade', 'Fade' }, { 'hide', 'Hide' }, { 'off', 'Stay visible' } }) do
                imgui.SameLine();
                if (imgui.RadioButton(m[2] .. '##menu_mode', s.menu_mode == m[1])) then
                    s.menu_mode = m[1];
                    changed = true;
                end
            end
            if (s.menu_mode == 'fade') then
                slider('Faded opacity', 'menu_alpha', 0.0, 0.8, '%.2f');
            end
            checkbox('Slide aside for game menus instead of fading', 'menu_slide');
            if (s.menu_slide) then
                imgui.Indent();
                checkbox('Fit to the open menu\'s size', 'slide_auto');
                if (s.slide_auto) then
                    slider('Gap after the menu', 'slide_margin', 0, 200, nil, true);
                    slider('Slide in item lists', 'item_info_slide', 0, 1200, nil, true);
                    hint('(inventory / bags, for the item details box)');
                else
                    slider('Slide distance', 'slide_dist', 0, 1200, nil, true);
                    hint('(or drag the chat while a menu is open)');
                end
                imgui.Unindent();
            end
            slider('Lines kept per tab', 'max_lines', 50, 1000, nil, true);
            imgui.Spacing();
        end

        if (imgui.CollapsingHeader('Game chat', open)) then
            checkbox('Hide the game\'s chat windows', 'hide_window');
            hint(('(%s)'):fmt(nativechat.status));
            checkbox('Hide the game\'s compass and clock', 'hide_compass');
            hint(('(%s)'):fmt(hud.status));
            checkbox('Show Vana\'diel time in the chat window', 'show_time');
            checkbox('Hide lines from the game\'s chat log', 'hide_native');
            if (s.hide_native) then
                imgui.Indent();
                checkbox('Also hide NPC dialog  (may confuse some NPCs)', 'hide_npc');
                imgui.Unindent();
            end
            imgui.Spacing();
        end

        if (imgui.CollapsingHeader('Colors')) then
            if (render_color_config(s)) then
                changed = true;
            end
            imgui.Spacing();
        end

        if (imgui.CollapsingHeader('Advanced')) then
            checkbox('Show chat mode ids on each line  (for /schat map)', 'show_mode_ids');
            imgui.Spacing();
        end

        imgui.Spacing();
        if (imgui.Button('Clear all tabs')) then
            clear_all();
        end
        imgui.SameLine();
        if (imgui.Button('Reset window positions')) then
            s.windows.main.x, s.windows.main.y = default_settings.windows.main.x, default_settings.windows.main.y;
            s.windows.log.x, s.windows.log.y = default_settings.windows.log.x, default_settings.windows.log.y;
            state.reset_pos = true;
            changed = true;
        end
    end
    imgui.End();

    imgui.PopStyleColor(5);
    imgui.PopStyleVar(3);

    if (changed) then
        render.version = render.version + 1;
        state.pending_save = true;
    end
end

--[[
* event: d3d_present
--]]
local present;

ashita.events.register('d3d_present', 'present_cb', function ()
    trap('present', present);
end);

present = function ()
    nativechat.tick(state.settings.hide_window);
    hud.tick(state.settings.hide_compass);

    -- Hide while the player is not logged in..
    local player = GetPlayerEntity();
    if (player == nil) then
        return;
    end

    -- Confirm the auto-translate code format once. (See autotranslate.lua)
    trap('autotranslate', autotranslate.step);

    trap('input.update', input.update, state.settings, function ()
        settings.save();
    end);

    trap('update_fade', update_fade);

    for _, win in ipairs(state.windows) do
        render_window(win);
    end
    state.reset_pos = false;
    render_config();

    -- Save any change (window moves/resizes, tabs, channel, settings) once the
    -- mouse is released, so nothing is lost if the game closes without unloading..
    if (input.dirty) then
        input.dirty = false;
        state.pending_save = true;
    end
    if (state.pending_save and not imgui.IsMouseDown(0)) then
        state.pending_save = false;
        settings.save();
    end
end
