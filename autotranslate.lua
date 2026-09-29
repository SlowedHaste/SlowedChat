--[[
* slowedchat - Auto-translate phrases for the input bar.
*
* The phrase list ships with the addon (autotranslate_data.lua, from Windower's
* Resources). A phrase's chat code is 6 bytes: FD 02 02 <group> <index> FD.
*
* Only real codes are ever decoded: once, one known phrase is decoded with
* Ashita's ParseAutoTranslate to confirm the format on this client. (An earlier
* version decoded every possible code, including ones that don't exist, which
* broke the addon.)
*
* Typing {Phrase} in the input sends the real auto-translate code, and Tab
* completes phrase names. (See input.lua)
--]]

require 'common';

local cleaner = require 'cleaner';
local data    = require 'autotranslate_data';

local at = {
    ready    = false,   -- The list is usable (format confirmed).
    list     = { },     -- { name = 'Warrior', lower = 'warrior', code = '\253...' }, sorted.
    by_name  = { },     -- [lower name] = entry
    checked  = false,   -- The format check has run.
    error    = nil,
};

local function code(id)
    return string.char(0xFD, 0x02, 0x02, math.floor(id / 256), id % 256, 0xFD);
end

-- Build the list. (Plain data; nothing is decoded here.)
for _, row in ipairs(data) do
    local name = row[2];
    local lower = name:lower();
    if (at.by_name[lower] == nil) then
        local entry = { name = name, lower = lower, code = code(row[1]) };
        at.by_name[lower] = entry;
        at.list[#at.list + 1] = entry;
    end
end
table.sort(at.list, function (a, b)
    if (#a.name ~= #b.name) then
        return #a.name < #b.name;
    end
    return a.lower < b.lower;
end);

--[[
* Confirms the code format on this client by decoding one known phrase.
* Call per frame while logged in; runs once.
--]]
at.step = function ()
    if (at.checked) then
        return;
    end
    at.checked = true;

    local ok, text = pcall(function ()
        return AshitaCore:GetChatManager():ParseAutoTranslate(code(257), false);
    end);
    if (ok and type(text) == 'string' and text:find('Nice to meet you', 1, true)) then
        at.ready = true;
    else
        at.error = ('format check failed (got %q)'):fmt(ok and tostring(text) or 'an error');
    end
end

--[[
* Returns up to 'limit' phrases starting with prefix (then containing it).
--]]
at.matches = function (prefix, limit)
    local out = { };
    if (not at.ready) then
        return out;
    end
    local p = prefix:lower();
    for _, e in ipairs(at.list) do
        if (e.lower:sub(1, #p) == p) then
            out[#out + 1] = e;
            if (#out >= limit) then
                return out;
            end
        end
    end
    if (#p >= 2) then
        for _, e in ipairs(at.list) do
            if (e.lower:sub(1, #p) ~= p and e.lower:find(p, 1, true)) then
                out[#out + 1] = e;
                if (#out >= limit) then
                    break;
                end
            end
        end
    end
    return out;
end

--[[
* Converts typed UTF-8 text into the game's encoding, turning {Phrase} into
* real auto-translate codes. Unknown {words} are sent as typed.
--]]
at.encode = function (text)
    if (not at.ready) then
        return cleaner.to_sjis(text);
    end
    local out = { };
    local pos = 1;
    for a, name, b in text:gmatch('(){([^{}]+)}()') do
        local e = at.by_name[name:lower()];
        if (e ~= nil) then
            out[#out + 1] = cleaner.to_sjis(text:sub(pos, a - 1));
            out[#out + 1] = e.code;
            pos = b;
        end
    end
    out[#out + 1] = cleaner.to_sjis(text:sub(pos));
    return table.concat(out);
end

return at;
