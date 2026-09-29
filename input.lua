--[[
* slowedchat - WoW-style chat input.
*
* Enter (or '/') opens an input bar in the Chat window instead of the game's
* own chat line. Plain text goes to the current channel; '/p', '/l', '/t name'
* etc. switch the sticky channel like WoW. Any other command is passed through.
--]]

require 'common';

local ffi     = require 'ffi';
local imgui   = require 'imgui';
local chat    = require 'chat';
local cleaner = require 'cleaner';
local palette = require 'palette';
local at      = require 'autotranslate';

local input = {
    active      = false,    -- Input bar is open.
    focus       = false,    -- Focus the input box on the next frame.
    buf         = { '' },
    gen         = 0,        -- Input widget id suffix; bumped to make ImGui re-read buf.
    to_end      = false,    -- Move the cursor to the end once the input is active.
    history     = { },
    hist_pos    = 0,
    channel     = 'say',
    tell_target = nil,
    reply_to    = nil,      -- Last player who sent us a tell.
    held        = { },      -- [DIK] = true: hidden from the game until released.
    held_at     = 0,
    takeover    = nil,      -- In-progress replacement of the game's chat line.
    tried       = false,    -- Takeover already attempted for the current game input.
    inject_esc  = 0,        -- Frames left to hold Escape down for the game.
    last_enter_menu = nil,  -- Game menu name the last time Enter was pressed. (Diagnostics)
};

local MAX_INPUT = 256;

local CHANNELS = {
    say        = { cmd = '/s',     label = 'Say' },
    party      = { cmd = '/p',     label = 'Party' },
    linkshell  = { cmd = '/l',     label = 'Linkshell' },
    linkshell2 = { cmd = '/l2',    label = 'Linkshell 2' },
    shout      = { cmd = '/sh',    label = 'Shout' },
    yell       = { cmd = '/yell',  label = 'Yell' },
    unity      = { cmd = '/u',     label = 'Unity' },
    emote      = { cmd = '/em',    label = 'Emote' },
    tell       = { cmd = '/t',     label = 'Tell' },
};

local ALIASES = {
    ['/s']  = 'say',        ['/say']        = 'say',
    ['/p']  = 'party',      ['/party']      = 'party',
    ['/l']  = 'linkshell',  ['/linkshell']  = 'linkshell',
    ['/l2'] = 'linkshell2', ['/linkshell2'] = 'linkshell2',
    ['/sh'] = 'shout',      ['/shout']      = 'shout',
    ['/yell'] = 'yell',
    ['/u']  = 'unity',      ['/unity']      = 'unity',
    ['/em'] = 'emote',      ['/emote']      = 'emote',
    ['/t']  = 'tell',       ['/tell']       = 'tell',
    ['/r']  = 'reply',      ['/reply']      = 'reply',
};

-- Keys
local VK_RETURN     = 0x0D;
local VK_OEM_2      = 0xBF; -- '/?'
local DIK_RETURN    = 0x1C;
local DIK_NUMPADENT = 0x9C;
local DIK_SLASH     = 0x35;
local DIK_ESCAPE    = 0x01;
local VK_CHAR_SLASH = 0x2F; -- '/' as a WM_CHAR character code.

--[[
* Game menu detection. (Signature from XIUI's core/gamestate.lua, thanks to Velyn.)
--]]
local pGameMenu     = ashita.memory.find('FFXiMain.dll', 0, '8B480C85C974??8B510885D274??3B05', 16, 0);
local pEventSystem  = ashita.memory.find('FFXiMain.dll', 0, 'A0????????84C0741AA1????????85C0741166A1????????663B05????????0F94C0C3', 0, 0);

input.menu_name = function ()
    if (pGameMenu == 0) then
        return '';
    end
    local p = ashita.memory.read_uint32(pGameMenu);
    if (p == 0) then return ''; end
    p = ashita.memory.read_uint32(p);
    if (p == 0) then return ''; end
    p = ashita.memory.read_uint32(p + 4);
    if (p == 0) then return ''; end
    return (ashita.memory.read_string(p + 0x46, 16):gsub('%z', ''):gsub('%s+$', ''));
end

-- Game menus that do NOT fade the chat: they open on the right side of the
-- screen, away from it. (Short names, without the 'menu' prefix; from XIUI's
-- menu list.) Every other menu (player menu, NPC options, Yes/No confirmations,
-- Mog House ...) fades it. '/schat fade' overrides either way. (s.menu_fade)
local RIGHT_SIDE_MENUS = {
    magselec = true,    -- Magic side menu.
    magic    = true,    -- Magic / Trust list.
    abiselec = true,    -- Abilities side menu.
    ability  = true,    -- Job abilities, weapon skills, pet commands.
    mount    = true,    -- Mount list.
};

--[[
* Returns the short name of a game menu. ('menu    myroom' -> 'myroom')
--]]
input.short_name = function (name)
    return name:match('^menu%s+(.+)$') or name;
end

--[[
* Returns true if the chat should step back for the game menu that's open.
--]]
input.game_menu_open = function (s)
    local name = input.menu_name();
    local short = input.short_name(name);

    -- No menu, an idle state, or the game's chat line..
    if (name == '' or short == 'inline' or (s.chat_menus ~= nil and s.chat_menus[name])) then
        return false;
    end

    -- Your choice from '/schat fade' wins; otherwise right-side menus don't fade..
    local choice = s.menu_fade and s.menu_fade[name];
    if (choice ~= nil) then
        return choice;
    end
    return not RIGHT_SIDE_MENUS[short];
end

-- True if a menu is excluded by default. (For '/schat fade' / status.)
input.right_side = function (name)
    return RIGHT_SIDE_MENUS[input.short_name(name)] == true;
end

--[[
* Returns the game's chat input state. IsInputOpen returns a ChatInputOpenStatus
* number (0 = closed, 0x11 = chat line, 0x21 = bazaar/search comment), not a bool.
*
* @return {boolean} open - True if any game text input is open.
* @return {boolean} is_chat - True if it is the chat line.
--]]
local function game_input_state()
    local v = AshitaCore:GetChatManager():IsInputOpen();
    if (type(v) == 'boolean') then
        return v, v;
    end
    v = tonumber(v) or 0;
    return bit.band(v, 0x01) ~= 0, bit.band(v, 0x10) ~= 0;
end

local function event_active()
    if (pEventSystem == 0) then
        return false;
    end
    local p = ashita.memory.read_uint32(pEventSystem + 1);
    return p ~= 0 and ashita.memory.read_uint8(p) == 1;
end

-- True while an NPC event (dialog, cutscene) is running.
input.event_active = event_active;

--[[
* Returns true if another addon's ImGui text box is being typed in. (ImGui still
* reports our own box for a frame after it closes, so that is ignored briefly.)
--]]
local function other_text_input()
    if (input.active) then
        return false;
    end
    local just_closed = input.closed_at ~= nil and (os.clock() - input.closed_at) < 0.3;
    return imgui.GetIO().WantTextInput and not just_closed;
end

--[[
* Returns true while slowedchat owns the '/' key.
*
* '/' has no use in the game other than opening its chat line, so while the
* game's own text input is closed it is always hidden from the game, at every
* input layer, with no menu checks. (Conditional blocking lost races.)
--]]
local function owns_slash(s)
    return s.custom_input and GetPlayerEntity() ~= nil and not game_input_state();
end

--[[
* Returns true if Enter should open our input instead of going to the game.
--]]
local function can_open(s)
    if (not s.custom_input or input.active) then
        return false;
    end
    if (GetPlayerEntity() == nil) then
        return false;
    end
    if (game_input_state()) then
        return false;
    end
    if (other_text_input()) then
        return false;
    end
    -- Leave Enter alone while a game menu or NPC event needs it. Menus the game
    -- has opened its chat line from before are learned in input.update..
    local menu = input.menu_name();
    if (menu ~= '' and not (s.chat_menus and s.chat_menus[menu])) then
        input.last_refusal = ('game menu "%s"'):fmt(menu);
        return false;
    end
    if (event_active()) then
        input.last_refusal = 'NPC event active';
        return false;
    end
    return true;
end

input.open = function (prefill)
    input.active = true;
    input.focus = true;
    input.to_end = true;
    input.hist_pos = 0;
    if (prefill ~= nil) then
        input.buf[1] = prefill;
    end
end

--[[
* Hides a DirectInput key from the game until it is physically released, so a
* key that just opened/closed our input isn't also seen by the game.
--]]
local function hold(...)
    for _, dik in ipairs({ ... }) do
        input.held[dik] = true;
    end
    input.held_at = os.clock();
end

--[[
* Opens our input from the '/' key, prefilled with '/'. The '/' character
* message that follows the key press is dropped in on_key.
--]]
local function open_slash()
    if (input.active or input.takeover ~= nil) then
        return;
    end
    input.open('/');
    input.slash_opened_at = os.clock();
end

input.close = function (clear)
    input.active = false;
    input.closed_at = os.clock();
    if (clear) then
        input.buf[1] = '';
    end
end

local function send(cmd)
    -- AshitaParse (-1): Ashita and addons (/schat, /addon ...) see the command
    -- first; anything they don't handle is forwarded to the game.
    -- {Phrase} becomes a real auto-translate code; the rest goes to Shift-JIS..
    AshitaCore:GetChatManager():QueueCommand(-1, at.encode(cmd));
end

--[[
* Sets the sticky channel and remembers it in the settings.
--]]
local function set_channel(s, ch, target)
    input.dirty = input.dirty or s.chat_channel ~= ch or (target ~= nil and s.tell_target ~= target);
    input.channel = ch;
    s.chat_channel = ch;
    if (target ~= nil) then
        input.tell_target = target;
        s.tell_target = target;
    end
end

--[[
* Restores the sticky channel from the settings. (Load / character switch.)
--]]
input.restore = function (s)
    input.channel = s.chat_channel or 'say';
    input.tell_target = (s.tell_target ~= nil and #s.tell_target > 0) and s.tell_target or nil;
    if (CHANNELS[input.channel] == nil or (input.channel == 'tell' and input.tell_target == nil)) then
        input.channel = 'say';
    end
end

--[[
* Handles a submitted line.
--]]
local function submit(s, text)
    text = text:gsub('^%s+', ''):gsub('%s+$', ''):gsub('^//', '/');
    if (#text == 0 or text == '/') then
        return;
    end

    table.insert(input.history, text);
    if (#input.history > 50) then
        table.remove(input.history, 1);
    end

    local cmd, rest = text:match('^(/%S+)%s*(.*)$');
    if (cmd == nil) then
        local ch = CHANNELS[input.channel];
        if (input.channel == 'tell') then
            send(('/t %s %s'):fmt(input.tell_target, text));
        else
            send(('%s %s'):fmt(ch.cmd, text));
        end
        return;
    end

    local ch = ALIASES[cmd:lower()];

    if (ch == 'reply') then
        if (input.reply_to == nil) then
            print(chat.header(addon.name):append(chat.error('No one to reply to yet.')));
            return;
        end
        ch = 'tell';
        rest = input.reply_to .. ' ' .. rest;
    end

    if (ch == 'tell') then
        local name, msg = rest:match('^(%S+)%s*(.*)$');
        if (name ~= nil) then
            set_channel(s, 'tell', name);
            if (#msg > 0) then
                send(('/t %s %s'):fmt(name, msg));
            end
        end
        return;
    end

    if (ch ~= nil) then
        -- Emotes are one-off; every other channel becomes sticky..
        if (ch ~= 'emote') then
            set_channel(s, ch);
        end
        if (#rest > 0) then
            send(('%s %s'):fmt(CHANNELS[ch].cmd, rest));
        end
        return;
    end

    -- Any other command. (/ma, /addon, /schat ...)
    send(text);
end

--[[
* Steps through sent history. (dir: -1 older, 1 newer)
*
* ImGui ignores buffer changes while an input is active, so the input is given a
* new id and refocused to pick up the new text. (InputText callbacks are avoided;
* they truncated the typed text with Ashita's binding.)
--]]
--[[
* Returns the auto-translate token being typed: text after the last unclosed '{'.
* (braced = true), or nil when there isn't one.
--]]
local function open_brace(text)
    local open = text:match('.*(){[^{}]*$');
    if (open == nil) then
        return nil, nil;
    end
    return text:sub(1, open - 1), text:sub(open + 1);
end

--[[
* Replaces the input text and refocuses so ImGui picks it up. (ImGui ignores
* buffer changes while an input is active; a new id makes it re-read.)
--]]
local function set_text(text)
    input.buf[1] = text;
    input.gen = input.gen + 1;
    input.focus = true;
    input.to_end = true;
end

--[[
* Tab: completes the auto-translate phrase being typed ('{war' or 'war'),
* cycling through matches on repeated presses, like the game's own chat.
--]]
local function complete(text)
    local c = input.cycle;
    if (c ~= nil and c.result == text) then
        c.i = (c.i % #c.list) + 1;
    else
        local base, token = open_brace(text);
        if (base == nil) then
            base, token = text:match('^(.-)(%S*)$');
        end
        local list = (#token > 0) and at.matches(token, 30) or { };
        if (#list == 0) then
            input.cycle = nil;
            set_text(text);
            return;
        end
        c = { base = base, list = list, i = 1 };
        input.cycle = c;
    end
    c.result = ('%s{%s} '):fmt(c.base, c.list[c.i].name);
    set_text(c.result);
end

--[[
* Draws the phrase suggestions above the input while a '{' phrase is typed.
--]]
local function draw_suggestions(x, y, typed)
    local _, token = open_brace(typed);
    if (token == nil or #token == 0) then
        return;
    end
    local list = at.matches(token, 6);
    if (#list == 0) then
        return;
    end

    local dl = imgui.GetForegroundDrawList();
    local font, fs = imgui.GetFont(), imgui.GetFontSize();
    local lh = imgui.GetTextLineHeight();
    local row = lh + 4;
    local w = 0;
    for _, e in ipairs(list) do
        w = math.max(w, imgui.CalcTextSize('{' .. e.name .. '}'));
    end
    w = w + 60;
    local h = #list * row + 6;
    local top = y - h - 4;

    dl:AddRectFilled({ x, top }, { x + w, top + h }, imgui.GetColorU32({ 0.05, 0.05, 0.07, 0.95 }), 5.0);
    dl:AddRect({ x, top }, { x + w, top + h }, imgui.GetColorU32({ 1, 1, 1, 0.12 }), 5.0, ImDrawFlags_None, 1.0);
    local green = imgui.GetColorU32(palette.get('autotrans') or { 0.56, 0.89, 0.63, 1 });
    for i, e in ipairs(list) do
        local ry = top + 3 + (i - 1) * row;
        if (i == 1) then
            dl:AddRectFilled({ x + 3, ry }, { x + w - 3, ry + row }, imgui.GetColorU32({ 1, 1, 1, 0.08 }), 3.0);
            dl:AddText(font, fs, { x + w - 34, ry + 2 }, imgui.GetColorU32({ 0.6, 0.6, 0.65, 1 }), 'Tab');
        end
        dl:AddText(font, fs, { x + 8, ry + 2 }, green, '{' .. e.name .. '}');
    end
end

local function history_step(dir)
    local n = #input.history;
    if (n == 0) then
        return;
    end

    if (dir < 0) then
        input.hist_pos = (input.hist_pos == 0) and n or math.max(1, input.hist_pos - 1);
    else
        if (input.hist_pos == 0) then
            return;
        end
        input.hist_pos = input.hist_pos + 1;
        if (input.hist_pos > n) then
            input.hist_pos = 0;
        end
    end

    input.buf[1] = (input.hist_pos == 0) and '' or input.history[input.hist_pos];
    input.gen = input.gen + 1;
    input.focus = true;
    input.to_end = true;
end

--[[
* Remembers who sent the last tell so '/r' can reply.
--]]
input.on_line = function (mode, text)
    if (mode == 12) then
        local name = text:match('^(%S+)>>');
        if (name ~= nil) then
            input.reply_to = name;
        end
    end
end

--[[
* Returns the height the input bar needs at the bottom of the window.
--]]
input.height = function ()
    return input.active and imgui.GetFrameHeightWithSpacing() or 0;
end

--[[
* Renders the input bar. Call inside the Chat window after the tabs.
--]]
input.render = function (s)
    if (not input.active) then
        return;
    end

    -- Preview where the line will go, updating as a '/' command is typed..
    local key = input.channel;
    local label;
    local typed = input.buf[1];
    if (typed:sub(1, 1) == '/') then
        local alias = ALIASES[(typed:match('^(/%S+)%s') or ''):lower()];
        if (alias == 'reply' and input.reply_to ~= nil) then
            key, label = 'tell', ('Tell %s:'):fmt(input.reply_to);
        elseif (alias == 'tell') then
            local name = typed:match('^/%S+%s+(%S+)%s');
            key, label = 'tell', name and ('Tell %s:'):fmt(name) or 'Tell:';
        elseif (alias ~= nil and alias ~= 'reply') then
            key, label = alias, CHANNELS[alias].label .. ':';
        else
            key, label = 'system', 'Command:';
        end
    elseif (key == 'tell') then
        label = ('Tell %s:'):fmt(input.tell_target);
    else
        label = (CHANNELS[key] or CHANNELS.say).label .. ':';
    end
    local color = palette.get(key, s.colors) or { 1, 1, 1, 1 };

    -- Channel pill..
    label = label:gsub(':$', '');
    local dl = imgui.GetWindowDrawList();
    local fh = imgui.GetFrameHeight();
    local lh = imgui.GetTextLineHeight();
    local px, py = imgui.GetCursorScreenPos();
    local pw = imgui.CalcTextSize(label) + 16;
    dl:AddRectFilled({ px, py }, { px + pw, py + fh }, imgui.GetColorU32({ color[1], color[2], color[3], 0.16 }), 4.0);
    dl:AddRect({ px, py }, { px + pw, py + fh }, imgui.GetColorU32({ color[1], color[2], color[3], 0.45 }), 4.0, ImDrawFlags_None, 1.0);
    dl:AddText(imgui.GetFont(), imgui.GetFontSize(), { px + 8, py + (fh - lh) * 0.5 }, imgui.GetColorU32(color), label);
    imgui.Dummy({ pw, fh });
    imgui.SameLine(0, 6);

    imgui.PushItemWidth(-1);
    imgui.PushStyleVar(ImGuiStyleVar_FrameRounding, 4.0);
    imgui.PushStyleVar(ImGuiStyleVar_FrameBorderSize, 1.0);
    imgui.PushStyleColor(ImGuiCol_Text, color);
    imgui.PushStyleColor(ImGuiCol_Border, { color[1], color[2], color[3], 0.35 });
    imgui.PushStyleColor(ImGuiCol_FrameBgHovered, { 0.0, 0.0, 0.0, 0.55 });
    imgui.PushStyleColor(ImGuiCol_FrameBgActive, { 0.0, 0.0, 0.0, 0.55 });
    imgui.PushStyleColor(ImGuiCol_FrameBg, { 0.0, 0.0, 0.0, 0.55 });
    if (input.focus) then
        imgui.SetKeyboardFocusHere();
        input.focus = false;
    end

    -- AllowTabInput: Tab types a '\t' (caught below for completion) instead of
    -- moving focus out of the input.
    local iflags = bit.bor(ImGuiInputTextFlags_EnterReturnsTrue, ImGuiInputTextFlags_AllowTabInput);
    local entered = imgui.InputText(('##slowedchat_input%d'):fmt(input.gen), input.buf, MAX_INPUT, iflags);
    local is_active = imgui.IsItemActive();
    local deactivated = imgui.IsItemDeactivated();

    -- Tab pressed: complete the auto-translate phrase..
    if (input.buf[1]:find('\t', 1, true)) then
        imgui.PopStyleColor(5);
        imgui.PopStyleVar(2);
        imgui.PopItemWidth();
        complete((input.buf[1]:gsub('\t', '')));
        return;
    end

    if (is_active and not entered) then
        -- Never let the suggestion list break the input bar..
        pcall(draw_suggestions, px, py, input.buf[1]);
    end

    imgui.PopStyleColor(5);
    imgui.PopStyleVar(2);
    imgui.PopItemWidth();

    if (is_active) then
        -- Focusing from code selects all text; press End so the next key adds
        -- to any prefilled text instead of replacing it..
        if (input.to_end) then
            input.to_end = false;
            if (#input.buf[1] > 0) then
                local io = imgui.GetIO();
                io:AddKeyEvent(ImGuiKey_End, true);
                io:AddKeyEvent(ImGuiKey_End, false);
            end
        end
        if (imgui.IsKeyPressed(ImGuiKey_UpArrow)) then
            history_step(-1);
            return;
        elseif (imgui.IsKeyPressed(ImGuiKey_DownArrow)) then
            history_step(1);
            return;
        end
    end

    if (entered) then
        local text = input.buf[1]:gsub('\t', '');
        input.cycle = nil;
        input.close(true);
        hold(DIK_RETURN, DIK_NUMPADENT);
        submit(s, text);
    elseif (imgui.IsKeyPressed(ImGuiKey_Escape)) then
        input.close(true);
        hold(DIK_ESCAPE);
    elseif (deactivated) then
        -- Clicked away: close but keep what was typed..
        input.close(false);
    end
end

--[[
* event: key (WndProc)
--]]
input.on_key = function (e, s)
    local vk = e.wparam;
    local down = bit.band(e.lparam, 0x80000000) == 0;

    if (vk == VK_RETURN) then
        if (not down) then
            return;
        end
        if (not input.active) then
            input.last_enter_menu = input.menu_name();
            input.last_enter_time = os.clock();
        end
        if (input.takeover ~= nil) then
            -- The game's line is being closed; don't let it send. Send from ours instead..
            input.takeover.submit = true;
            hold(DIK_RETURN, DIK_NUMPADENT);
            e.blocked = true;
        elseif (input.held[DIK_RETURN]) then
            e.blocked = true;
        elseif (can_open(s)) then
            hold(DIK_RETURN, DIK_NUMPADENT);
            input.open();
            e.blocked = true;
        end
    elseif (vk == VK_OEM_2) then
        -- The key press never reaches the game. (Typed '/' characters come from a
        -- separate character message, so typing '/' in our bar still works.)
        if (other_text_input() or not owns_slash(s)) then
            return;
        end
        e.blocked = true;
        if (down and not input.active) then
            open_slash();
        end
    elseif (vk == VK_CHAR_SLASH and input.slash_opened_at ~= nil and (os.clock() - input.slash_opened_at) < 0.25) then
        -- The '/' character message that follows the key press; the game must not
        -- see it either. (The input was already opened with a '/'.)
        input.slash_opened_at = nil;
        e.blocked = true;
    end
end

--[[
* event: key_data (DirectInput buffered keyboard, what the game uses to open its chat line)
--]]
input.on_key_data = function (e, s)
    if (e.key == nil) then
        return;
    end

    if (e.key == DIK_RETURN or e.key == DIK_NUMPADENT) then
        if (e.down and input.takeover ~= nil) then
            input.takeover.submit = true;
            hold(DIK_RETURN, DIK_NUMPADENT);
        elseif (e.down and not input.held[e.key] and can_open(s)) then
            hold(DIK_RETURN, DIK_NUMPADENT);
            input.open();
        end
    elseif (e.key == DIK_SLASH and owns_slash(s)) then
        e.blocked = true;
        if (e.down and not input.active and not other_text_input()) then
            open_slash();
        end
        return;
    end

    -- Keep keys from reaching the game while typing, or until released..
    if (input.active or input.held[e.key] or input.takeover ~= nil and (e.key == DIK_RETURN or e.key == DIK_NUMPADENT)) then
        e.blocked = true;
    end
end

--[[
* event: key_state (DirectInput keyboard state)
--]]
input.on_key_state = function (e, s)
    if (e.data_raw == nil) then
        return;
    end
    local keys = ffi.cast('uint8_t*', e.data_raw);

    -- The game never sees '/' while we own it. (See owns_slash)
    if (owns_slash(s)) then
        keys[DIK_SLASH] = 0;
    end

    -- Release held keys once DirectInput itself reports them up. (Windows'
    -- key-up can arrive a frame earlier, and the game would see a fresh press.)
    for dik, _ in pairs(input.held) do
        if (bit.band(keys[dik], 0x80) == 0) then
            input.held[dik] = nil;
        else
            keys[dik] = 0;
        end
    end

    if (input.active) then
        ffi.fill(keys, 256, 0);
    end

    -- Press Escape for the game to close its chat line. (See input.update)
    if (input.inject_esc > 0) then
        keys[DIK_ESCAPE] = 0x80;
        input.inject_esc = input.inject_esc - 1;
    end
end

local WM_KEYDOWN = 0x0100;
local WM_KEYUP   = 0x0101;
local VK_ESCAPE  = 0x1B;

--[[
* Called every frame. Fallback for when the game's chat line opens anyway (a
* menu we don't recognize, a keybind, etc.): copy its text, close it with
* Escape, then open slowedchat's input with that text.
--]]
local function native_text()
    local _, text = cleaner.parse(AshitaCore:GetChatManager():GetInputTextParsed() or '');
    return text;
end

input.update = function (s, on_learn)
    local open, is_chat = game_input_state();

    -- Safety: never keep a key hidden from the game for long, even if the
    -- DirectInput state event stops arriving..
    if (next(input.held) ~= nil and os.clock() - input.held_at > 1.5) then
        input.held = { };
    end

    local t = input.takeover;
    if (t ~= nil) then
        t.frames = t.frames + 1;
        if (open) then
            -- Keep anything typed while the game's line is still closing..
            t.text = native_text();
            -- The window-message Escape did not close it; try a DirectInput one..
            if (t.frames == 6) then
                input.inject_esc = 2;
            end
        end
        -- Wait two frames so our input doesn't also see the Escape we sent..
        if ((not open and t.frames >= 2) or t.frames >= 15) then
            input.takeover = nil;
            if (open) then
                return;
            end
            if (t.keep_ours) then
                -- Our bar was already open; just give it focus back..
                input.focus = true;
            elseif (t.submit and #t.text > 0) then
                -- Enter was pressed while the game's line was closing: send it from here..
                submit(s, t.text);
            else
                input.open(#t.text > 0 and t.text or nil);
            end
        end
        return;
    end

    if (not open) then
        input.tried = false;
        return;
    end
    if (not is_chat) then
        return;
    end

    -- Only try once per opening so a failed close can't loop..
    if (not s.custom_input or input.tried or GetPlayerEntity() == nil) then
        return;
    end
    input.tried = true;

    -- If Enter just opened the game's chat line, Enter means "chat" in that menu.
    -- Remember it so we can take Enter directly next time. (Only for Enter: '/'
    -- or Space can open chat from real menus where Enter must still confirm.)
    local m = input.last_enter_menu;
    local by_enter = input.last_enter_time ~= nil and (os.clock() - input.last_enter_time) < 0.5;
    if (by_enter and m ~= nil and m ~= '' and not m:find('inline', 1, true) and not (s.chat_menus and s.chat_menus[m])) then
        s.chat_menus = s.chat_menus or T{ };
        s.chat_menus[m] = true;
        if (on_learn ~= nil) then
            on_learn(m);
        end
    end

    input.takeover = { text = native_text(), frames = 0, keep_ours = input.active };

    local hwnd = AshitaCore:GetProperties():GetFinalFantasyHwnd();
    AshitaCore:SendMessageA(hwnd, WM_KEYDOWN, VK_ESCAPE, 0x00010001);
    AshitaCore:SendMessageA(hwnd, WM_KEYUP, VK_ESCAPE, 0xC0010001);
end

return input;
