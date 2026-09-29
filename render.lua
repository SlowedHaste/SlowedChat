--[[
* slowedchat - Draws chat lines as word-wrapped, multi-colored text.
*
* Each entry is laid out once into runs ({ x, row, text, key }) and cached
* until the wrap width, font size or display options change. Lines outside the
* scroll region only reserve space and are not drawn.
--]]

require 'common';

local imgui   = require 'imgui';
local palette = require 'palette';

local render = { };

-- Bumped whenever an option that changes layout (timestamps, mode ids) changes.
render.version = 0;

--[[
* Returns the spans to lay out for an entry, including any prefixes.
--]]
local function display_spans(e, s)
    local out = { };
    if (s.timestamps) then
        out[#out + 1] = { text = os.date(s.timestamp_fmt, e.time) .. ' ', key = 'timestamp' };
    end
    if (s.show_mode_ids) then
        out[#out + 1] = { text = ('[%d] '):fmt(e.mode), key = 'modeid' };
    end
    for _, v in ipairs(e.spans) do
        out[#out + 1] = v;
    end
    return out;
end

--[[
* Lays an entry out into runs for the given wrap width.
--]]
local function layout(e, s, wrap, fs)
    local runs = { };
    local x, row = 0, 0;
    local indent = s.wrap_indent;

    local function add(tok, key)
        local w = imgui.CalcTextSize(tok);
        local line_start = (row == 0) and 0 or indent;

        if (x + w > wrap and x > line_start) then
            row = row + 1;
            x = indent;
            tok = tok:gsub('^%s+', '');
            w = imgui.CalcTextSize(tok);
        end

        -- Merge into the previous run when it continues on the same row with the same color..
        local last = runs[#runs];
        if (last ~= nil and last.row == row and last.key == key) then
            last.text = last.text .. tok;
        else
            runs[#runs + 1] = { x = x, row = row, text = tok, key = key };
        end
        x = x + w;
    end

    for _, sp in ipairs(display_spans(e, s)) do
        local first = true;
        for part in (sp.text .. '\n'):gmatch('(.-)\n') do
            if (not first) then
                row = row + 1;
                x = indent;
            end
            first = false;
            for tok in part:gmatch('%s*%S+%s*') do
                add(tok, sp.key);
            end
        end
    end

    e.layout = { wrap = wrap, fs = fs, ver = render.version, rows = row + 1, runs = runs };
    return e.layout;
end

--[[
* Draws the lines of a tab. Must be called inside a child window.
*
* @param {table} lines - The entries to draw.
* @param {table} s - The addon settings.
* @param {function} on_copy - Called with an entry when it is right-clicked.
--]]
render.lines = function (lines, s, on_copy)
    local dl    = imgui.GetWindowDrawList();
    local font  = imgui.GetFont();
    local fs    = imgui.GetFontSize();
    local lh    = imgui.GetTextLineHeight();
    local wrap  = imgui.GetContentRegionAvail();
    local _, wy = imgui.GetWindowPos();
    local wh    = imgui.GetWindowHeight();

    -- Resolve colors once per frame..
    local colors = { };
    local function u32(key, base)
        -- Inline FFXI colors fall back to the line color when unknown or disabled..
        local k = key;
        if (k == 'base' or (k:sub(1, 2) == 'fx' and (not s.inline_colors or palette.ffxi[k] == nil))) then
            k = base;
        end
        local c = colors[k];
        if (c == nil) then
            local rgba = palette.get(k, s.colors) or { 1, 1, 1, 1 };
            c = imgui.GetColorU32(rgba);
            colors[k] = c;
        end
        return c;
    end
    local shadow = imgui.GetColorU32({ 0.0, 0.0, 0.0, 0.85 });
    local hover  = imgui.GetColorU32({ 1.0, 1.0, 1.0, 0.06 });

    for _, e in ipairs(lines) do
        local l = e.layout;
        if (l == nil or l.wrap ~= wrap or l.fs ~= fs or l.ver ~= render.version) then
            l = layout(e, s, wrap, fs);
        end

        local h = l.rows * lh;
        local sx, sy = imgui.GetCursorScreenPos();
        imgui.Dummy({ wrap, h });

        if (sy + h >= wy and sy <= wy + wh) then
            if (imgui.IsItemHovered()) then
                dl:AddRectFilled({ sx - 2, sy }, { sx + wrap, sy + h }, hover, 2.0);
                if (imgui.IsMouseClicked(1)) then
                    on_copy(e);
                end
            end

            for _, r in ipairs(l.runs) do
                local px, py = sx + r.x, sy + r.row * lh;
                if (s.text_shadow) then
                    dl:AddText(font, fs, { px + 1, py + 1 }, shadow, r.text);
                end
                dl:AddText(font, fs, { px, py }, u32(r.key, e.style), r.text);
            end
        end
    end
end

return render;
