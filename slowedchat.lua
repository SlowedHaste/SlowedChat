addon.name      = 'slowedchat';
addon.author    = 'panda';
addon.version   = '0.2';
addon.desc      = 'WoW-style tabbed chat windows.';
addon.link      = '';

require 'common';

local chat      = require 'chat';
local imgui     = require 'imgui';
local settings  = require 'settings';
local modes     = require 'modes';
local cleaner   = require 'cleaner';
local palette   = require 'palette';
local render    = require 'render';
local input     = require 'input';
local nativechat = require 'nativechat';

-- Default Settings
local default_settings = T{
    layout          = 'single',     -- 'single' or 'dual'
    hide_native     = false,        -- Block captured lines from the game's own chat log.
    hide_npc        = false,        -- Also hide NPC dialog. (Off: some NPCs rely on the game's log.)
    hide_window     = false,        -- Hide the game's chat log windows themselves. (Memory write; see nativechat.lua)
    custom_input    = true,         -- Enter / '/' opens slowedchat's input instead of the game's.
    chat_channel    = 'say',        -- Last sticky input channel.
    tell_target     = '',           -- Last tell target, when chat_channel is 'tell'.
    chat_menus      = T{ },         -- Game menus where Enter opens chat. (Learned automatically.)
    timestamps      = true,
    timestamp_fmt   = '[%H:%M]',
    max_lines       = 300,          -- Lines kept per tab.
    font_scale      = 1.0,
    bg_alpha        = 0.60,
    line_gap        = 2,            -- Extra pixels between lines.
    wrap_indent     = 12,           -- Indent for wrapped continuation rows.
    text_shadow     = true,
    inline_colors   = true,         -- Use the game's own colors for items, key items, etc.
    locked          = false,
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
            { name = 'Messages', cats = MESSAGES },
            { name = 'System',   cats = SYSTEM },
        } },
    },
    dual = {
        { id = 'main', title = 'Chat', tabs = {
            { name = 'General',  cats = NOCOMBAT },
            { name = 'Messages', cats = MESSAGES },
        } },
        { id = 'log', title = 'Log', tabs = {
            { name = 'Combat',   cats = COMBAT },
            { name = 'System',   cats = SYSTEM },
        } },
    },
};

-- Styles whose numbers are highlighted.
local NUMBER_STYLES = cats('combat', 'dealt', 'taken', 'heal', 'crit', 'skillchain', 'xp', 'gil');

-- Window theme. (Dark, low-contrast chrome so the text stands out.)
local theme_colors = {
    { ImGuiCol_WindowBg,                 { 0.02, 0.02, 0.03, 1.00 } },
    { ImGuiCol_Border,                   { 1.00, 1.00, 1.00, 0.07 } },
    { ImGuiCol_Tab,                      { 0.10, 0.10, 0.12, 0.80 } },
    { ImGuiCol_TabHovered,               { 0.30, 0.30, 0.36, 1.00 } },
    { ImGuiCol_TabSelected,              { 0.20, 0.20, 0.25, 1.00 } },
    { ImGuiCol_TabSelectedOverline,      { 1.00, 0.82, 0.00, 1.00 } },
    { ImGuiCol_TabDimmed,                { 0.10, 0.10, 0.12, 0.80 } },
    { ImGuiCol_TabDimmedSelected,        { 0.20, 0.20, 0.25, 1.00 } },
    { ImGuiCol_TabDimmedSelectedOverline,{ 1.00, 0.82, 0.00, 0.60 } },
    { ImGuiCol_ScrollbarBg,              { 0.00, 0.00, 0.00, 0.00 } },
    { ImGuiCol_ScrollbarGrab,            { 1.00, 1.00, 1.00, 0.15 } },
    { ImGuiCol_ScrollbarGrabHovered,     { 1.00, 1.00, 1.00, 0.30 } },
    { ImGuiCol_ResizeGrip,               { 1.00, 1.00, 1.00, 0.05 } },
};
local theme_vars = {
    { ImGuiStyleVar_WindowRounding,  4.0 },
    { ImGuiStyleVar_WindowPadding,   { 6, 4 } },
    { ImGuiStyleVar_ScrollbarSize,   6.0 },
    { ImGuiStyleVar_TabRounding,     3.0 },
    { ImGuiStyleVar_FramePadding,    { 8, 3 } },
    { ImGuiStyleVar_TabBarBorderSize, 0.0 },
};

-- Addon State
local state = {
    settings    = settings.load(default_settings),
    history     = T{ },     -- Every captured line, used to rebuild tabs on layout changes.
    windows     = { },      -- Runtime windows built from the current layout.
    config_open = { false },
    party       = { },      -- Cached party/alliance member names.
    party_time  = 0,
    captured    = 0,        -- Lines captured this session. (For '/schat status'.)
    blocked     = 0,        -- Lines hidden from the game's log this session.
};

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
local function build_spans(parsed, style)
    local out = { };
    local numbers = NUMBER_STYLES[style];

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
    return out;
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
            local tab = { name = t.name, cats = t.cats, lines = { }, unread = false, scroll = true };
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
                if (win.active ~= i) then
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
        { '/schat window', 'Toggles hiding the game\'s chat windows themselves.' },
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
    build_windows();
    input.restore(state.settings);
end);

--[[
* event: unload
--]]
ashita.events.register('unload', 'unload_cb', function ()
    nativechat.restore();
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
        local learned = T{ };
        for k, _ in pairs(s.chat_menus or { }) do
            learned:append(('"%s"'):fmt(k));
        end
        line('Learned chat menus', #learned > 0 and learned:concat(', ') or 'none');
        line('Game input state', tostring(AshitaCore:GetChatManager():IsInputOpen()));
        line('Last capture error', state.last_error or 'none');
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
        local parsed, text = cleaner.parse(e.message_modified);
        if (#text == 0) then
            return;
        end

        local cat = modes.classify(mode, state.settings.mode_overrides);
        is_npc = cat == 'npc';
        local style = modes.style(cat, text, party_names());
        input.on_line(mode, text);
        state.captured = state.captured + 1;
        push_line({
            time  = os.time(),
            mode  = mode,
            cat   = cat,
            style = style,
            text  = text,
            spans = build_spans(parsed, style),
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
    input.on_key(e, state.settings);
end);

ashita.events.register('key_data', 'key_data_cb', function (e)
    input.on_key_data(e, state.settings);
end);

ashita.events.register('key_state', 'key_state_cb', function (e)
    input.on_key_state(e);
end);

--[[
* Renders the lines of a tab inside a scrolling child region.
--]]
local function render_lines(tab, footer)
    imgui.BeginChild('##lines', { 0, -footer }, ImGuiChildFlags_None, ImGuiWindowFlags_None);

    -- Stay pinned to the bottom unless the user has scrolled up..
    local at_bottom = imgui.GetScrollY() >= imgui.GetScrollMaxY() - 2;

    imgui.PushStyleVar(ImGuiStyleVar_ItemSpacing, { 0, state.settings.line_gap });
    render.lines(tab.lines, state.settings, copy_line);
    imgui.PopStyleVar();

    if (at_bottom or tab.scroll) then
        imgui.SetScrollHereY(1.0);
        tab.scroll = false;
    end

    imgui.EndChild();
end

--[[
* Renders one chat window.
--]]
local function render_window(win)
    local s = state.settings;
    local ws = s.windows[win.id];
    if (not ws.visible) then
        return;
    end

    local cond = state.reset_pos and ImGuiCond_Always or ImGuiCond_FirstUseEver;
    imgui.SetNextWindowPos({ ws.x, ws.y }, cond);
    imgui.SetNextWindowSize({ ws.w, ws.h }, cond);
    imgui.SetNextWindowBgAlpha(s.bg_alpha);

    local flags = bit.bor(ImGuiWindowFlags_NoTitleBar, ImGuiWindowFlags_NoCollapse, ImGuiWindowFlags_NoScrollbar,
        ImGuiWindowFlags_NoSavedSettings, ImGuiWindowFlags_NoFocusOnAppearing, ImGuiWindowFlags_NoBringToFrontOnFocus);
    if (s.locked) then
        flags = bit.bor(flags, ImGuiWindowFlags_NoMove, ImGuiWindowFlags_NoResize);
    end

    for _, c in ipairs(theme_colors) do
        imgui.PushStyleColor(c[1], c[2]);
    end
    for _, v in ipairs(theme_vars) do
        imgui.PushStyleVar(v[1], v[2]);
    end

    if (imgui.Begin(('%s##slowedchat_%s'):fmt(win.title, win.id), win.open, flags)) then
        -- Remember position/size so they survive reloads..
        ws.x, ws.y = imgui.GetWindowPos();
        ws.w, ws.h = imgui.GetWindowSize();

        local pushed = false;
        if (s.font_scale ~= 1.0) then
            pushed = pcall(imgui.PushFont, imgui.GetFont(), imgui.GetFontSize() * s.font_scale);
        end

        local tbflags = bit.bor(ImGuiTabBarFlags_NoTooltip, ImGuiTabBarFlags_DrawSelectedOverline);
        if (imgui.BeginTabBar('##tabs_' .. win.id, tbflags)) then
            for i, tab in ipairs(win.tabs) do
                local tflags = ImGuiTabItemFlags_None;
                if (win.select == i) then
                    tflags = ImGuiTabItemFlags_SetSelected;
                    win.select = nil;
                end

                -- Highlight tabs with unread lines..
                local unread = tab.unread;
                local label = tab.name;
                if (unread) then
                    imgui.PushStyleColor(ImGuiCol_Text, { 1.0, 0.82, 0.0, 1.0 });
                    label = label .. ' *';
                else
                    imgui.PushStyleColor(ImGuiCol_Text, { 0.85, 0.85, 0.85, 1.0 });
                end
                local open = imgui.BeginTabItem(('%s###tab%d'):fmt(label, i), nil, tflags);
                imgui.PopStyleColor();

                if (open) then
                    if (win.active ~= i) then
                        win.active = i;
                        tab.scroll = true;
                        ws.tab = tab.name;
                    end
                    tab.unread = false;
                    render_lines(tab, win.id == 'main' and input.height() or 0);
                    imgui.EndTabItem();
                end
            end
            imgui.EndTabBar();
        end

        if (win.id == 'main') then
            input.render(s);
        end

        if (pushed) then
            imgui.PopFont();
        end
    end
    imgui.End();

    imgui.PopStyleVar(#theme_vars);
    imgui.PopStyleColor(#theme_colors);
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

    if (imgui.Begin('slowedchat Settings', state.config_open, ImGuiWindowFlags_AlwaysAutoResize)) then
        imgui.Text('Layout');
        if (imgui.RadioButton('Single window (All / Combat / Messages / System)', s.layout == 'single')) then
            s.layout = 'single';
            build_windows();
            changed = true;
        end
        if (imgui.RadioButton('Split: Chat window + Log window', s.layout == 'dual')) then
            s.layout = 'dual';
            build_windows();
            changed = true;
        end

        imgui.Separator();
        checkbox('Hide lines from the game\'s chat log', 'hide_native');
        if (s.hide_native) then
            imgui.Indent();
            checkbox('Also hide NPC dialog (may confuse some NPCs)', 'hide_npc');
            imgui.Unindent();
        end
        checkbox('Hide the game\'s chat windows', 'hide_window');
        imgui.SameLine();
        imgui.TextDisabled(('(%s)'):fmt(nativechat.status));
        checkbox('Type in slowedchat (Enter / \'/\' opens its input bar)', 'custom_input');
        checkbox('Show timestamps', 'timestamps');
        checkbox('Text shadow', 'text_shadow');
        checkbox('Use game colors for items / key items', 'inline_colors');
        checkbox('Lock windows', 'locked');
        checkbox('Show chat mode ids (debug)', 'show_mode_ids');

        imgui.Separator();
        local alpha = { s.bg_alpha };
        if (imgui.SliderFloat('Background opacity', alpha, 0.0, 1.0, '%.2f')) then
            s.bg_alpha = alpha[1];
            changed = true;
        end
        local scale = { s.font_scale };
        if (imgui.SliderFloat('Font scale', scale, 0.5, 2.0, '%.2f')) then
            s.font_scale = scale[1];
            changed = true;
        end
        local gap = { s.line_gap };
        if (imgui.SliderInt('Line spacing', gap, 0, 10)) then
            s.line_gap = gap[1];
            changed = true;
        end
        local lines = { s.max_lines };
        if (imgui.SliderInt('Lines per tab', lines, 50, 1000)) then
            s.max_lines = lines[1];
            changed = true;
        end

        imgui.Separator();
        if (imgui.CollapsingHeader('Colors')) then
            if (render_color_config(s)) then
                changed = true;
            end
        end

        imgui.Separator();
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

    if (changed) then
        render.version = render.version + 1;
        state.pending_save = true;
    end

    -- Save once the mouse is released instead of every frame while dragging..
    if (state.pending_save and not imgui.IsMouseDown(0)) then
        state.pending_save = false;
        settings.save();
    end
end

--[[
* event: d3d_present
--]]
ashita.events.register('d3d_present', 'present_cb', function ()
    nativechat.tick(state.settings.hide_window);

    -- Hide while the player is not logged in..
    local player = GetPlayerEntity();
    if (player == nil) then
        return;
    end

    input.update(state.settings, function ()
        settings.save();
    end);

    for _, win in ipairs(state.windows) do
        render_window(win);
    end
    state.reset_pos = false;
    render_config();
end);
