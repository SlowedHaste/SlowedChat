--[[
* slowedchat - Color palette.
*
* Style keys map to hex colors. Users can override any key from the settings
* window; overrides are stored as RGBA tables in settings.colors.
--]]

require 'common';

local palette = { };

-- Default colors. (Channel colors follow WoW's defaults where there is an equivalent.)
palette.defaults = {
    -- Channels
    say         = 'FFFFFF',
    emote       = 'FF8040',
    shout       = 'FFA64D',
    yell        = 'FF4040',
    tell        = 'FF80FF',
    party       = 'AAAAFF',
    linkshell   = '40FF40',
    linkshell2  = '40C080',
    unity       = 'FFC0C0',
    npc         = 'FFFF9F',

    -- System
    system      = 'FFF08A',
    loot        = '1EFF00',
    gil         = 'FFD700',
    xp          = '8C8CFF',
    error       = 'FF4D4D',

    -- Combat
    combat      = 'B4B4B4',
    dealt       = 'EDEDED',
    taken       = 'FF7070',
    number      = 'FFE14D',
    miss        = '7F7F7F',
    heal        = '66FF66',
    buff        = '66CCFF',
    fade        = '9A9AC0',
    ability     = 'FFB266',
    spell       = 'C0A6FF',
    crit        = 'FF9933',
    defeat      = 'FFD100',
    skillchain  = 'FF66FF',

    -- Interface
    timestamp   = '808080',
    modeid      = '5A5A5A',
};

-- Groups/labels for the settings window.
palette.groups = {
    { 'Channels', {
        { 'say', 'Say' }, { 'emote', 'Emote' }, { 'shout', 'Shout' }, { 'yell', 'Yell' },
        { 'tell', 'Tell' }, { 'party', 'Party' }, { 'linkshell', 'Linkshell' },
        { 'linkshell2', 'Linkshell 2' }, { 'unity', 'Unity' }, { 'npc', 'NPC' },
    } },
    { 'System', {
        { 'system', 'System' }, { 'loot', 'Loot' }, { 'gil', 'Gil' },
        { 'xp', 'Experience' }, { 'error', 'Errors' },
    } },
    { 'Combat', {
        { 'combat', 'Other combat' }, { 'dealt', 'Damage dealt' }, { 'taken', 'Damage taken' },
        { 'number', 'Numbers' }, { 'miss', 'Miss / resist' }, { 'heal', 'Healing' },
        { 'buff', 'Buffs' }, { 'fade', 'Wears off' }, { 'ability', 'Abilities / WS' },
        { 'spell', 'Spells' }, { 'crit', 'Critical hits' }, { 'defeat', 'Defeats' },
        { 'skillchain', 'Skillchain / MB' },
    } },
    { 'Interface', {
        { 'timestamp', 'Timestamps' }, { 'modeid', 'Mode ids' },
    } },
};

-- FFXI inline color codes. ('\30\xx' -> fx1:xx) Anything not listed keeps the line's color.
palette.ffxi = {
    ['fx1:2']   = '7CFC00', -- Items
    ['fx1:3']   = '9D8CFF', -- Key items
    ['fx1:5']   = 'FF40FF',
    ['fx1:6']   = '00FFFF',
    ['fx1:7']   = 'FFE4B5',
    ['fx1:8']   = 'FF7F50',
    ['fx1:65']  = '8A8A8A',
    ['fx1:67']  = 'A0A0A0',
    ['fx1:68']  = 'FA8072',
    ['fx1:69']  = 'FFFF00',
    ['fx1:71']  = '6A8CFF',
    ['fx1:72']  = 'C050C0',
    ['fx1:73']  = 'EE82EE',
    ['fx1:76']  = 'FF6347',
    ['fx1:77']  = 'FFE4E1',
    ['fx1:78']  = 'EEE8AA',
    ['fx1:79']  = '00FF00',
    ['fx1:80']  = '98FB98',
    ['fx1:81']  = 'B870E8',
    ['fx1:82']  = '00FFFF',
    ['fx1:83']  = '00FF7F',
    ['fx1:85']  = 'E9967A',
    ['fx1:88']  = '00FA9A',
    ['fx1:89']  = '9F80E8',
    ['fx1:90']  = 'F0FFFF',
    ['fx1:92']  = 'E0FFFF',
    ['fx1:96']  = 'FAFAD2',
    ['fx1:104'] = 'FFD75F',
    ['fx1:105'] = 'DDA0DD',
    ['fx1:106'] = 'FFF5C8',
};

local cache = { };

local function hex(h)
    local v = cache[h];
    if (v == nil) then
        v = {
            tonumber(h:sub(1, 2), 16) / 255,
            tonumber(h:sub(3, 4), 16) / 255,
            tonumber(h:sub(5, 6), 16) / 255,
            1.0,
        };
        cache[h] = v;
    end
    return v;
end

--[[
* Returns the RGBA color for a style key, honoring user overrides.
*
* @param {string} key - The style key.
* @param {table} overrides - settings.colors
* @return {table|nil} The RGBA color, or nil if the key is unknown.
--]]
palette.get = function (key, overrides)
    local o = overrides and overrides[key];
    if (o ~= nil) then
        return o;
    end
    local h = palette.defaults[key] or palette.ffxi[key];
    return h and hex(h) or nil;
end

return palette;
