--[[
* slowedchat - The game's compass/clock HUD, and Vana'diel time.
*
* Compass: the game draws it unless one code byte is cleared. Signature and
* byte from FancyCompass (purya-mochimochi), with HXIUIBegone's safety rules:
* exactly one signature match, only patch the expected value, restore the page
* protection right after writing, and only restore a byte we changed.
*   https://github.com/purya-mochimochi/FancyCompass
*   https://github.com/ryuutatsuo23-max/HXIUIBegone
*
* Clock: the game's own '/clock off' / '/clock on' commands.
*
* Vana'diel time: read from the game's clock (signature via FancyCompass /
* GlamourUI), falling back to the standard formula from the PC clock.
--]]

require 'common';

local ffi = require 'ffi';

ffi.cdef[[
    void* GetCurrentProcess(void);
    int FlushInstructionCache(void* process, const void* address, size_t size);
]];

local COMPASS_SIGNATURE = '33C0668B81????????483DE3000000';
local COMPASS_OFFSET    = 0x24;
local TIME_SIGNATURE    = 'B0015EC390518B4C24088D4424005068';
local VANA_OFFSET       = 92514960;     -- Earth seconds -> Vana'diel clock base.

-- Addons that manage the same compass byte / clock; never fight them.
local CONFLICTS = { 'fancycompass', 'hxiuibegone' };

local hud = {
    compass     = nil,      -- Address of the compass byte, once found.
    owned       = false,    -- We cleared the compass byte.
    clock_off   = false,    -- We sent '/clock off' this session.
    clock_at    = nil,      -- When to send '/clock off' after login.
    session     = 0,
    status      = 'Off',
    time_ptr    = nil,
};

local function find_unique(signature)
    local first = ashita.memory.find('FFXiMain.dll', 0, signature, 0, 0);
    if (first == 0 or ashita.memory.find('FFXiMain.dll', 0, signature, 0, 1) ~= 0) then
        return nil;
    end
    return first;
end

--[[
* Writes one code byte: unprotect, write, flush, restore protection.
--]]
local function patch8(address, value)
    local ok, previous = ashita.memory.unprotect(address, 1);
    if (not ok or previous == nil) then
        error('could not change code page protection');
    end
    local wrote, err = pcall(function ()
        ashita.memory.write_uint8(address, value);
        ffi.C.FlushInstructionCache(ffi.C.GetCurrentProcess(), ffi.cast('const void*', address), 1);
    end);
    ashita.memory.protect(address, 1, previous);
    if (not wrote) then
        error(err);
    end
    if (ashita.memory.read_uint8(address) ~= value) then
        error('compass byte write did not take effect');
    end
end

local function conflict()
    for _, name in ipairs(CONFLICTS) do
        local ok, loaded = pcall(function () return AddonManager:IsLoaded(name); end);
        if (ok and loaded) then
            return name;
        end
    end
    return nil;
end

local function show_compass()
    if (hud.owned and hud.compass ~= nil) then
        hud.owned = false;
        if (ashita.memory.read_uint8(hud.compass) == 0) then
            pcall(patch8, hud.compass, 1);
        end
    end
end

local function hide_compass()
    if (hud.compass == nil) then
        local match = find_unique(COMPASS_SIGNATURE);
        if (match == nil) then
            hud.status = 'Unavailable - compass signature not found';
            return;
        end
        hud.compass = match + COMPASS_OFFSET;
    end

    if (hud.owned) then
        return;
    end
    local b = ashita.memory.read_uint8(hud.compass);
    if (b == 0) then
        hud.status = 'Compass already hidden by something else';
        return;
    end
    if (b ~= 1) then
        hud.status = 'Unavailable - unexpected compass code';
        return;
    end
    hud.owned = true;   -- Keep restore responsibility even if the write half-fails.
    local ok, err = pcall(patch8, hud.compass, 0);
    if (not ok) then
        show_compass();
        hud.status = 'Stopped - ' .. tostring(err);
        hud.stopped = true;
    end
end

local function clock_command(off)
    AshitaCore:GetChatManager():QueueCommand(-1, off and '/clock off' or '/clock on');
    hud.clock_off = off;
end

--[[
* Shows everything we hid. (Unload / option off.)
--]]
hud.restore = function ()
    show_compass();
    if (hud.clock_off) then
        pcall(clock_command, false);
    end
    hud.clock_at = nil;
end

--[[
* Called every frame.
*
* @param {boolean} wanted - True to hide the game's compass and clock.
--]]
hud.tick = function (wanted)
    local memory = AshitaCore:GetMemoryManager();
    local logged_in = memory:GetPlayer():GetLoginStatus() == 2;
    local session = logged_in and memory:GetParty():GetMemberServerId(0) or 0;

    if (session ~= hud.session) then
        -- New login: the game turns its clock back on, so resend after it settles..
        hud.session = session;
        hud.clock_off = false;
        hud.clock_at = (session ~= 0) and (os.clock() + 3.0) or nil;
    end
    if (session == 0) then
        return;
    end

    if (not wanted) then
        if (hud.owned or hud.clock_off) then
            hud.restore();
        end
        hud.stopped = false;
        hud.status = 'Off';
        return;
    end

    local other = conflict();
    if (other ~= nil) then
        hud.restore();
        hud.status = ('Paused - %s is loaded and handles this'):fmt(other);
        return;
    end

    if (not hud.stopped) then
        hud.status = 'Hiding';
        hide_compass();
    end

    if (not hud.clock_off and (hud.clock_at == nil or os.clock() >= hud.clock_at)) then
        hud.clock_at = nil;
        clock_command(true);
    end
end

--[[
* Returns the Vana'diel time as hour, minute, day index (0 = Firesday .. 7 = Darksday).
--]]
hud.vana_time = function ()
    local t = nil;

    if (hud.time_ptr == nil) then
        local match = find_unique(TIME_SIGNATURE);
        hud.time_ptr = match and (match + 0x34) or false;
    end
    if (hud.time_ptr) then
        local p = ashita.memory.read_uint32(hud.time_ptr);
        if (p ~= 0) then
            local raw = ashita.memory.read_uint32(p + 0x0C);
            if (raw ~= 0) then
                t = raw + VANA_OFFSET;
            end
        end
    end
    if (t == nil) then
        t = os.time() + VANA_OFFSET;
    end

    return math.floor(t / 144) % 24, math.floor((t % 144) / 2.4), math.floor(t / 3456) % 8;
end

hud.DAYS = {
    [0] = { 'Firesday',     { 1.00, 0.36, 0.30 } },
    [1] = { 'Earthsday',    { 0.95, 0.85, 0.30 } },
    [2] = { 'Watersday',    { 0.35, 0.60, 1.00 } },
    [3] = { 'Windsday',     { 0.40, 0.85, 0.40 } },
    [4] = { 'Iceday',       { 0.70, 0.88, 1.00 } },
    [5] = { 'Lightningday', { 0.90, 0.45, 1.00 } },
    [6] = { 'Lightsday',    { 0.95, 0.95, 0.95 } },
    [7] = { 'Darksday',     { 0.62, 0.52, 0.80 } },
};

return hud;
