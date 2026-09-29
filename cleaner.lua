--[[
* slowedchat - Parses raw FFXI chat text into colored UTF-8 spans for ImGui.
--]]

require 'common';

local ffi = require 'ffi';

ffi.cdef[[
    int MultiByteToWideChar(uint32_t CodePage, uint32_t dwFlags, const char* lpMultiByteStr, int cbMultiByte, wchar_t* lpWideCharStr, int cchWideChar);
    int WideCharToMultiByte(uint32_t CodePage, uint32_t dwFlags, const wchar_t* lpWideCharStr, int cchWideChar, char* lpMultiByteStr, int cbMultiByte, const char* lpDefaultChar, bool* lpUsedDefaultChar);
]];

local CP_SJIS = 932;
local CP_UTF8 = 65001;

local cleaner = { };

--[[
* Converts a Shift-JIS string to UTF-8.
--]]
local function sjis_to_utf8(str)
    -- Plain ASCII needs no conversion..
    if (not str:find('[\128-\255]')) then
        return str;
    end

    local wlen = ffi.C.MultiByteToWideChar(CP_SJIS, 0, str, #str, nil, 0);
    if (wlen <= 0) then
        return str;
    end
    local wbuf = ffi.new('wchar_t[?]', wlen);
    ffi.C.MultiByteToWideChar(CP_SJIS, 0, str, #str, wbuf, wlen);

    local len = ffi.C.WideCharToMultiByte(CP_UTF8, 0, wbuf, wlen, nil, 0, nil, nil);
    if (len <= 0) then
        return str;
    end
    local buf = ffi.new('char[?]', len);
    ffi.C.WideCharToMultiByte(CP_UTF8, 0, wbuf, wlen, buf, len, nil, nil);
    return ffi.string(buf, len);
end

--[[
* Converts a UTF-8 string to Shift-JIS. (For text typed into ImGui and sent to the game.)
--]]
cleaner.to_sjis = function (str)
    if (not str:find('[\128-\255]')) then
        return str;
    end

    local wlen = ffi.C.MultiByteToWideChar(CP_UTF8, 0, str, #str, nil, 0);
    if (wlen <= 0) then
        return str;
    end
    local wbuf = ffi.new('wchar_t[?]', wlen);
    ffi.C.MultiByteToWideChar(CP_UTF8, 0, str, #str, wbuf, wlen);

    local len = ffi.C.WideCharToMultiByte(CP_SJIS, 0, wbuf, wlen, nil, 0, nil, nil);
    if (len <= 0) then
        return str;
    end
    local buf = ffi.new('char[?]', len);
    ffi.C.WideCharToMultiByte(CP_SJIS, 0, wbuf, wlen, buf, len, nil, nil);
    return ffi.string(buf, len);
end

local function is_sjis_lead(b)
    return (b >= 0x81 and b <= 0x9F) or (b >= 0xE0 and b <= 0xFC);
end

--[[
* Parses a raw chat message into spans.
*
* @param {string} raw - The raw message. (e.message_modified)
* @return {table} Array of { text = string, fx = string|nil } where fx is an
*                 inline color key ('fx1:n' / 'fx2:n') or nil for the line color.
* @return {string} The plain text of the whole message.
--]]
cleaner.parse = function (raw)
    -- Expand auto-translate phrases into text..
    local msg = AshitaCore:GetChatManager():ParseAutoTranslate(raw, true);

    local spans = { };
    local buf = { };
    local fx = nil;
    local at_saved = nil;

    local function flush()
        if (#buf > 0) then
            spans[#spans + 1] = { text = sjis_to_utf8(table.concat(buf)), fx = fx };
            buf = { };
        end
    end

    local i, n = 1, #msg;
    while (i <= n) do
        -- Copy plain ASCII runs in one go..
        local j = msg:find('[%z\1-\31\127-\255]', i);
        if (j == nil) then
            buf[#buf + 1] = msg:sub(i);
            break;
        end
        if (j > i) then
            buf[#buf + 1] = msg:sub(i, j - 1);
        end

        local b = msg:byte(j);
        local c = msg:byte(j + 1);

        if (b == 0x1E or b == 0x1F) then
            -- Color code: \30\01 resets to the line color..
            flush();
            if (c == nil or (b == 0x1E and c == 1)) then
                fx = nil;
            else
                fx = ('fx%d:%d'):fmt(b - 0x1D, c);
            end
            i = j + 2;
        elseif (b == 0x7F) then
            -- Prompt / control markers..
            i = j + 2;
        elseif (b == 0xEF and c ~= nil and c >= 0x1F and c <= 0x2E) then
            -- Auto-translate brackets (the phrase gets its own span, see palette
            -- 'autotrans') and element icons..
            if (c == 0x27) then
                flush();
                at_saved = fx;
                fx = 'autotrans';
                buf[#buf + 1] = '{';
            elseif (c == 0x28) then
                buf[#buf + 1] = '}';
                flush();
                fx = at_saved;
            end
            i = j + 2;
        elseif (is_sjis_lead(b) and c ~= nil) then
            buf[#buf + 1] = msg:sub(j, j + 1);
            i = j + 2;
        elseif (b == 0x07 or b == 0x0A) then
            buf[#buf + 1] = '\n';
            i = j + 1;
        elseif (b < 0x20) then
            i = j + 1;
        else
            buf[#buf + 1] = string.char(b);
            i = j + 1;
        end
    end
    flush();

    -- Trim leading/trailing whitespace from the whole message..
    while (#spans > 0) do
        spans[1].text = spans[1].text:gsub('^%s+', '');
        if (#spans[1].text > 0) then break; end
        table.remove(spans, 1);
    end
    while (#spans > 0) do
        spans[#spans].text = spans[#spans].text:gsub('%s+$', '');
        if (#spans[#spans].text > 0) then break; end
        table.remove(spans);
    end

    local plain = { };
    for k, v in ipairs(spans) do
        plain[k] = v.text;
    end

    return spans, table.concat(plain);
end

return cleaner;
