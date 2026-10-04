--[[
* slowedchat - Hides the game's own chat log windows.
*
* Adapted from HXIUIBegone by DragoHorse (GPL-3.0-or-later), which builds on
* atom0s's hideparty (Ashita Development Team, GPL-3.0-or-later):
*   https://github.com/ryuutatsuo23-max/HXIUIBegone
*
* The chat windows are UI primitives reached through slots found next to the
* party list signature. Each primitive has two visibility bytes (+0x69, +0x6A)
* that are cleared every frame while hiding and restored when hiding stops.
* Every address is checked with VirtualQuery before it is read or written.
--]]

require 'common';

local ffi = require 'ffi';

ffi.cdef[[
    typedef struct {
        void*    BaseAddress;
        void*    AllocationBase;
        uint32_t AllocationProtect;
        size_t   RegionSize;
        uint32_t State;
        uint32_t Protect;
        uint32_t Type;
    } SLOWEDCHAT_MBI;
    size_t __stdcall VirtualQuery(const void* address, void* buffer, size_t length);
]];

local PARTY_SIGNATURE = '66C78182000000????C7818C000000????????C781900000';
local WINDOWS = {
    chat1 = 0x0F,   -- Main chat log.
    chat2 = 0x37,   -- Second (split) chat log.
};

-- Addons that write the same bytes; never fight them.
local CONFLICTS = { 'hxiuibegone', 'ogui' };

local mbi = ffi.new('SLOWEDCHAT_MBI[1]');

local nativechat = {
    slots   = nil,      -- [key] = slot address, once found.
    owned   = { },      -- [key] = { object, original = { a, b } } while hidden.
    session = 0,
    status  = 'Off',
};

--[[
* Returns true if [address, address + size) is committed memory with the needed access.
--]]
local function valid(address, size, writable)
    if (type(address) ~= 'number' or address < 0x10000 or address + size > 0x100000000) then
        return false;
    end
    if (ffi.C.VirtualQuery(ffi.cast('const void*', address), mbi, ffi.sizeof(mbi[0])) == 0) then
        return false;
    end
    local r = mbi[0];
    local protect = tonumber(r.Protect);
    local base = tonumber(ffi.cast('uintptr_t', r.BaseAddress));
    if (r.State ~= 0x1000 or bit.band(protect, 0x100) ~= 0 or address + size > base + tonumber(r.RegionSize)) then
        return false;
    end
    local access = bit.band(protect, 0xFF);
    if (writable) then
        return access == 0x04 or access == 0x08 or access == 0x40 or access == 0x80;
    end
    return access == 0x02 or access == 0x04 or access == 0x08 or access == 0x20 or access == 0x40 or access == 0x80;
end

local function in_module(address, size)
    local base = ashita.memory.get_base('FFXiMain.dll');
    local length = ashita.memory.get_size('FFXiMain.dll');
    return base ~= 0 and address >= base and address + size <= base + length;
end

local function read32(address)
    return valid(address, 4, false) and ashita.memory.read_uint32(address) or 0;
end

--[[
* Finds the chat window slots. Requires exactly one signature match.
--]]
local function initialize()
    nativechat.slots = { };

    local match = ashita.memory.find('FFXiMain.dll', 0, PARTY_SIGNATURE, 0, 0);
    if (match == 0 or ashita.memory.find('FFXiMain.dll', 0, PARTY_SIGNATURE, 0, 1) ~= 0) then
        nativechat.status = 'Unavailable - chat window signature not found';
        return;
    end

    for key, offset in pairs(WINDOWS) do
        if (in_module(match + offset, 4)) then
            local slot = read32(match + offset);
            if (slot ~= 0 and in_module(slot, 4)) then
                nativechat.slots[key] = slot;
            end
        end
    end
end

--[[
* Returns the UI object for a chat window, or nil if it isn't available right now.
--]]
local function object_for(key)
    local slot = nativechat.slots and nativechat.slots[key];
    if (slot == nil) then
        return nil;
    end
    local first = read32(slot);
    if (first == 0) then
        return nil;
    end
    local object = read32(first + 0x08);
    if (object == 0 or not valid(object + 0x69, 2, true)) then
        return nil;
    end
    return object;
end

--[[
* Restores a window, but only on the same object we hid and only bytes still
* carrying our hidden value.
--]]
local function release(key)
    local own = nativechat.owned[key];
    if (own == nil) then
        return;
    end
    nativechat.owned[key] = nil;

    local object = object_for(key);
    if (object ~= nil and object == own.object) then
        for i = 1, 2 do
            local address = object + 0x68 + i;
            if (ashita.memory.read_uint8(address) == 0) then
                ashita.memory.write_uint8(address, own.original[i]);
            end
        end
    end
end

local function hide(key)
    local object = object_for(key);
    if (object == nil) then
        nativechat.owned[key] = nil;
        return;
    end

    local own = nativechat.owned[key];
    if (own == nil or own.object ~= object) then
        local a = ashita.memory.read_uint8(object + 0x69);
        local b = ashita.memory.read_uint8(object + 0x6A);
        if (not ((a == 0 or a == 1) and (b == 0 or b == 1))) then
            error('unexpected chat window data');
        end
        nativechat.owned[key] = { object = object, original = { a, b } };
    end

    -- The game can refresh these each frame..
    if (ashita.memory.read_uint8(object + 0x69) ~= 0) then
        ashita.memory.write_uint8(object + 0x69, 0);
    end
    if (ashita.memory.read_uint8(object + 0x6A) ~= 0) then
        ashita.memory.write_uint8(object + 0x6A, 0);
    end
end

--[[
* Shows every window we hid.
--]]
nativechat.restore = function ()
    for key, _ in pairs(WINDOWS) do
        pcall(release, key);
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

--[[
* Called every frame.
*
* @param {boolean} wanted - True to hide the game's chat windows.
--]]
nativechat.tick = function (wanted)
    -- Restore on logout / character change; UI objects belong to a session..
    local memory = AshitaCore:GetMemoryManager();
    local session = (memory:GetPlayer():GetLoginStatus() == 2) and memory:GetParty():GetMemberServerId(0) or 0;
    if (session ~= nativechat.session) then
        nativechat.restore();
        nativechat.session = session;
    end
    if (session == 0) then
        return;
    end

    if (not wanted) then
        nativechat.restore();
        nativechat.stopped = false;
        nativechat.status = 'Off';
        return;
    end

    -- After an error, stay stopped until the option is toggled off and on..
    if (nativechat.stopped) then
        return;
    end

    local other = conflict();
    if (other ~= nil) then
        nativechat.restore();
        nativechat.status = ('Paused - %s is loaded and handles this'):fmt(other);
        return;
    end

    if (nativechat.slots == nil) then
        initialize();
    end
    if (next(nativechat.slots) == nil) then
        nativechat.status = 'Unavailable - chat window signature not found';
        return;
    end

    nativechat.status = 'Hiding';
    for key, _ in pairs(WINDOWS) do
        local ok, err = pcall(hide, key);
        if (not ok) then
            nativechat.restore();
            nativechat.stopped = true;
            nativechat.status = 'Stopped - ' .. tostring(err);
            return;
        end
    end
end

-- Readable/writable check, shared with menu research. (See '/schat menudump')
nativechat.valid = valid;

return nativechat;
