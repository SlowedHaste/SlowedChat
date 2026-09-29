--[[
* slowedchat - Draws chat lines as word-wrapped, multi-colored text.
*
* Each entry is laid out once into runs ({ x, row, text, key, strong }) and
* cached until the wrap width, font or display options change. Lines outside
* the scroll region only reserve space and are not drawn.
--]]

require 'common';

local imgui   = require 'imgui';
local palette = require 'palette';

local render = { };

-- Bumped whenever an option that changes layout (timestamps, fonts, style) changes.
render.version = 0;

--[[
* Returns the spans to lay out for an entry, including any prefixes.
*
* The speaker is drawn either as the game prints it ("(Name) ", "<Name> ") or
* WoW-style ("[Party] Name: ", "Name says: ").
--]]
local function display_spans(e, s)
    local out = { };
    if (s.timestamps) then
        out[#out + 1] = { text = os.date(s.timestamp_fmt, e.time) .. ' ', key = 'timestamp' };
    end
    if (s.show_mode_ids) then
        out[#out + 1] = { text = ('[%d] '):fmt(e.mode), key = 'modeid' };
    end

    local sp = e.speaker;
    if (sp ~= nil) then
        if (s.message_style == 'wow') then
            if (sp.label:sub(-1) == 's') then
                out[#out + 1] = { text = sp.name, key = 'speaker', strong = true };
                out[#out + 1] = { text = (' %s: '):fmt(sp.label), key = 'base' };
            else
                out[#out + 1] = { text = ('[%s] '):fmt(sp.label), key = 'base' };
                out[#out + 1] = { text = sp.name, key = 'speaker', strong = true };
                out[#out + 1] = { text = ': ', key = 'base' };
            end
        else
            out[#out + 1] = { text = sp.prefix, key = 'speaker', strong = true };
        end
    end

    for _, v in ipairs(e.spans) do
        out[#out + 1] = v;
    end
    return out;
end

--[[
* Lays an entry out into runs for the given wrap width.
--]]
local function layout(e, s, wrap, f)
    local runs = { };
    local x, row = 0, 0;
    local indent = s.wrap_indent;

    local function measure(tok, strong)
        if (strong and f.strong ~= nil) then
            imgui.PushFont(f.strong, f.size);
            local w = imgui.CalcTextSize(tok);
            imgui.PopFont();
            return w;
        end
        return imgui.CalcTextSize(tok);
    end

    local function add(tok, key, strong)
        local w = measure(tok, strong);
        local line_start = (row == 0) and 0 or indent;

        if (x + w > wrap and x > line_start) then
            row = row + 1;
            x = indent;
            tok = tok:gsub('^%s+', '');
            w = measure(tok, strong);
        end

        -- Merge into the previous run when it continues on the same row in the same style..
        local last = runs[#runs];
        if (last ~= nil and last.row == row and last.key == key and last.strong == strong) then
            last.text = last.text .. tok;
        else
            runs[#runs + 1] = { x = x, row = row, text = tok, key = key, strong = strong };
        end
        x = x + w;
    end

    for _, sp in ipairs(display_spans(e, s)) do
        local strong = (sp.strong == true and s.speaker_names) or nil;
        local first = true;
        for part in (sp.text .. '\n'):gmatch('(.-)\n') do
            if (not first) then
                row = row + 1;
                x = indent;
            end
            first = false;
            for tok in part:gmatch('%s*%S+%s*') do
                add(tok, sp.key, strong);
            end
        end
    end

    e.layout = { wrap = wrap, size = f.size, ver = render.version, rows = row + 1, runs = runs };
    return e.layout;
end

-- Offsets for the text effects. (Outline: 4 cardinal + 4 diagonal, soft.)
local OUTLINE = { { -1, 0 }, { 1, 0 }, { 0, -1 }, { 0, 1 }, { -1, -1 }, { 1, -1 }, { -1, 1 }, { 1, 1 } };

--[[
* Draws the lines of a tab. Must be called inside a child window.
*
* @param {table} lines - The entries to draw.
* @param {table} s - The addon settings.
* @param {function} on_copy - Called with an entry when it is right-clicked.
* @param {table} f - Fonts: { regular = ImFont, strong = ImFont|nil, size = number }
--]]
render.lines = function (lines, s, on_copy, f)
    local dl    = imgui.GetWindowDrawList();
    local lh    = imgui.GetTextLineHeight();
    local wrap  = imgui.GetContentRegionAvail();
    local _, wy = imgui.GetWindowPos();
    local wh    = imgui.GetWindowHeight();

    -- Resolve colors once per frame..
    local colors = { };
    local function u32(key, base)
        -- Inline FFXI colors fall back to the line color when unknown or disabled..
        local k = key;
        if (k == 'base' or (k:sub(1, 2) == 'fx' and (not s.inline_colors or palette.ffxi[k] == nil))
            or (k == 'speaker' and not s.speaker_names)) then
            k = base;
        end

        -- Speaker names are the line color, lifted toward white..
        local ck = (k == 'speaker') and ('speaker|' .. base) or k;
        local c = colors[ck];
        if (c == nil) then
            local rgba = palette.get(k == 'speaker' and base or k, s.colors) or { 1, 1, 1, 1 };
            if (k == 'speaker') then
                rgba = {
                    rgba[1] + (1 - rgba[1]) * 0.35,
                    rgba[2] + (1 - rgba[2]) * 0.35,
                    rgba[3] + (1 - rgba[3]) * 0.35,
                    rgba[4],
                };
            end
            c = imgui.GetColorU32(rgba);
            colors[ck] = c;
        end
        return c;
    end

    local effect  = s.text_effect;
    local shadow  = imgui.GetColorU32({ 0.0, 0.0, 0.0, 0.85 });
    local outline = imgui.GetColorU32({ 0.0, 0.0, 0.0, 0.55 });
    local hover   = imgui.GetColorU32({ 1.0, 1.0, 1.0, 0.05 });
    local mention = imgui.GetColorU32({ 1.00, 0.82, 0.00, 0.10 });
    local mbar    = imgui.GetColorU32({ 1.00, 0.82, 0.00, 0.85 });

    for _, e in ipairs(lines) do
        local l = e.layout;
        if (l == nil or l.wrap ~= wrap or l.size ~= f.size or l.ver ~= render.version) then
            l = layout(e, s, wrap, f);
        end

        local h = l.rows * lh;
        local sx, sy = imgui.GetCursorScreenPos();
        imgui.Dummy({ wrap, h });

        if (sy + h >= wy and sy <= wy + wh) then
            -- Someone said your name: soft gold wash with a bar at the left edge..
            if (e.mention and s.mention_highlight) then
                dl:AddRectFilled({ sx - 4, sy - 1 }, { sx + wrap, sy + h + 1 }, mention, 2.0);
                dl:AddRectFilled({ sx - 4, sy - 1 }, { sx - 2, sy + h + 1 }, mbar);
            end

            if (imgui.IsItemHovered()) then
                dl:AddRectFilled({ sx - 4, sy - 1 }, { sx + wrap, sy + h + 1 }, hover, 2.0);
                if (imgui.IsMouseClicked(1)) then
                    on_copy(e);
                end
            end

            for _, r in ipairs(l.runs) do
                local font = (r.strong and f.strong) or f.regular;
                local px, py = sx + r.x, sy + r.row * lh;
                if (effect == 'outline') then
                    for _, o in ipairs(OUTLINE) do
                        dl:AddText(font, f.size, { px + o[1], py + o[2] }, outline, r.text);
                    end
                elseif (effect == 'shadow') then
                    dl:AddText(font, f.size, { px + 1, py + 1 }, shadow, r.text);
                end
                dl:AddText(font, f.size, { px, py }, u32(r.key, e.style), r.text);
            end
        end
    end
end

return render;
