--[[
* slowedchat - Chat mode classification and line styling.
*
* Maps FFXI chat modes (the low byte of e.mode_modified) to categories. The
* combat ranges are best-effort; use '/schat debug' to see a line's mode id and
* '/schat map <mode> <category>' to move it somewhere else.
--]]

require 'common';

local modes = { };

-- Every category, in display order.
modes.categories = T{
    'say', 'shout', 'yell', 'emote', 'tell', 'party',
    'linkshell', 'linkshell2', 'unity', 'npc', 'combat', 'system',
};

modes.valid = { };
for _, v in ipairs(modes.categories) do
    modes.valid[v] = true;
end

local map = { };

local function set(cat, ...)
    for _, v in ipairs({ ... }) do
        map[v] = cat;
    end
end

local function range(cat, lo, hi)
    for v = lo, hi do
        map[v] = cat;
    end
end

-- Player chat. (First id is your own outgoing line, second is others.)
set('say',        1, 9);
set('shout',      2, 10);
set('yell',       11);
set('tell',       4, 12);
set('party',      5, 13);
set('linkshell',  6, 14);
set('linkshell2', 213, 214);
set('emote',      7, 15);
set('unity',      211, 212);
set('say',        220, 221, 222, 223); -- Assist channels.

-- NPC dialog.
set('npc',        150, 151, 152);

-- Battle messages. (Best-effort ranges.)
range('combat',   20, 44);
range('combat',   50, 69);
range('combat',   100, 114);

--[[
* Returns the category for the given chat mode.
*
* @param {number} mode - The chat mode id. (Low byte.)
* @param {table} overrides - User overrides keyed by tostring(mode).
* @return {string} The category name.
--]]
modes.classify = function (mode, overrides)
    local o = overrides and overrides[tostring(mode)];
    if (o ~= nil and modes.valid[o]) then
        return o;
    end
    return map[mode] or 'system';
end

local function has(s, ...)
    for _, p in ipairs({ ... }) do
        if (s:find(p, 1, true)) then
            return true;
        end
    end
    return false;
end

--[[
* Returns true if the line starts with one of the given names.
--]]
local function starts_with_name(text, names)
    for _, n in ipairs(names) do
        if (text:sub(1, #n) == n) then
            local nx = text:sub(#n + 1, #n + 1);
            if (nx == ' ' or nx == '\'') then
                return true;
            end
        end
    end
    return false;
end

local function mentions_name(text, names)
    for _, n in ipairs(names) do
        if (text:find(n, 1, true)) then
            return true;
        end
    end
    return false;
end

--[[
* Returns the style key for a line. Channel lines use their category color;
* combat and system lines are colored by what the message says.
*
* @param {string} cat - The line category.
* @param {string} text - The plain line text.
* @param {table} party - Names of the player's party/alliance members.
* @return {string} The style key. (See palette.defaults)
--]]
modes.style = function (cat, text, party)
    if (cat ~= 'combat' and cat ~= 'system') then
        return cat;
    end

    local t = text:lower();

    -- Rewards can show up in either category..
    if (has(t, 'experience point', 'limit point', 'capacity point', 'exemplar point', 'job point', 'merit point', 'attains level', 'level up')) then
        return 'xp';
    end
    if (t:find('%d+ gil')) then
        return 'gil';
    end
    if (has(t, 'obtain', 'you find', 'lot for', 'treasure pool', 'was lost')) then
        return 'loot';
    end

    if (cat == 'system') then
        if (has(t, 'cannot', 'unable to', 'can\'t', 'too far', 'out of range', 'not enough', 'invalid', 'failed')) then
            return 'error';
        end
        return 'system';
    end

    if (has(t, 'skillchain', 'magic burst')) then
        return 'skillchain';
    end
    if (has(t, 'defeats', 'falls to the ground', 'was defeated')) then
        return 'defeat';
    end
    if (has(t, 'critical hit')) then
        return 'crit';
    end
    if (has(t, ' miss', 'resists', 'no effect', 'evades', 'parries', 'parried', 'anticipates', 'shadow', 'fails', 'interrupted')) then
        return 'miss';
    end
    if (has(t, 'wears off', 'no longer')) then
        return 'fade';
    end
    if (has(t, 'recovers', 'restores', 'regains')) then
        return 'heal';
    end
    if (has(t, 'gains the effect', 'receives the effect')) then
        return 'buff';
    end

    local s = text:gsub('^%s+', '');
    local takes = has(t, ' takes ');
    if (takes or t:find('%d+ points? of damage')) then
        local ours = starts_with_name(s, party);
        if (takes) then
            -- "X takes N damage": X is the target..
            return ours and 'taken' or 'dealt';
        end
        if (ours) then
            return 'dealt';
        end
        return mentions_name(s, party) and 'taken' or 'combat';
    end

    if (has(t, ' readies ', ' uses ')) then
        return 'ability';
    end
    if (has(t, ' casts ', 'starts casting')) then
        return 'spell';
    end

    return 'combat';
end

return modes;
