--[[
* slowedchat - Chat fonts.
*
* Fonts are loaded once from the addon's load event (fonts.prewarm) and then
* only looked up. Adding fonts to ImGui's atlas mid-frame (from d3d_present)
* can crash the client, so fonts.get never loads anything.
--]]

require 'common';

local imgui = require 'imgui';

local fonts = { };

-- Selectable families: regular file, and the heavier file used for speaker names.
fonts.families = {
    { name = 'Default',     regular = nil,            strong = nil },     -- Ashita's ImGui font.
    { name = 'Segoe UI',    regular = 'segoeui.ttf',  strong = 'seguisb.ttf' },
    { name = 'Tahoma',      regular = 'tahoma.ttf',   strong = 'tahomabd.ttf' },
    { name = 'Verdana',     regular = 'verdana.ttf',  strong = 'verdanab.ttf' },
    { name = 'Calibri',     regular = 'calibri.ttf',  strong = 'calibrib.ttf' },
    { name = 'Arial',       regular = 'arial.ttf',    strong = 'arialbd.ttf' },
    { name = 'Trebuchet',   regular = 'trebuc.ttf',   strong = 'trebucbd.ttf' },
    { name = 'Consolas',    regular = 'consola.ttf',  strong = 'consolab.ttf' },
};

local loaded = { };     -- [family name] = { regular = ImFont|nil, strong = ImFont|nil }

local function exists(path)
    local f = io.open(path, 'rb');
    if (f ~= nil) then
        f:close();
        return true;
    end
    return false;
end

local function load(file)
    if (file == nil) then
        return nil;
    end
    local path = 'C:\\Windows\\Fonts\\' .. file;
    if (not exists(path)) then
        return nil;
    end
    local ok, font = pcall(imgui.AddFontFromFileTTF, path, 20.0);
    return (ok and font) or nil;
end

--[[
* Loads every family. Call from the load event only.
--]]
fonts.prewarm = function ()
    for _, f in ipairs(fonts.families) do
        if (f.regular ~= nil and loaded[f.name] == nil) then
            local regular = load(f.regular);
            loaded[f.name] = { regular = regular, strong = regular and load(f.strong) or nil };
        end
    end
end

--[[
* Returns the regular and strong fonts for a family. Either can be nil, which
* means "use the current ImGui font".
--]]
fonts.get = function (name)
    local f = loaded[name];
    if (f == nil) then
        return nil, nil;
    end
    return f.regular, f.strong;
end

--[[
* Returns the pixel size to push for a size setting. 0 means "match Ashita's
* ImGui font", read from the style's unscaled base size (PushFont takes an
* unscaled size), falling back to the current font size.
--]]
fonts.size = function (setting)
    if (setting ~= nil and setting > 0) then
        return setting;
    end
    local ok, style = pcall(imgui.GetStyle);
    if (ok and style ~= nil and type(style.FontSizeBase) == 'number' and style.FontSizeBase > 0) then
        return style.FontSizeBase;
    end
    return imgui.GetFontSize();
end

--[[
* Returns true if a family is usable. ('Default' always is.)
--]]
fonts.available = function (name)
    if (name == 'Default') then
        return true;
    end
    local f = loaded[name];
    return f ~= nil and f.regular ~= nil;
end

return fonts;
