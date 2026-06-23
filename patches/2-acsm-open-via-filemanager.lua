-- Route ACSM files opened via external launchers through the FileManager
-- dispatch path, which knows how to handle plugin-style providers.
-- Without this, KOReader tries to open .acsm as a document and crashes.

local ReaderUI = require("apps/reader/readerui")
local FileManager = require("apps/filemanager/filemanager")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local util = require("util")

local orig_showReader = ReaderUI.showReader

local function isAcsm(file)
    return type(file) == "string" and file:lower():match("%.acsm$") ~= nil
end

ReaderUI.showReader = function(self, file, provider, seamless, is_provider_forced, after_open_callback)
    if not isAcsm(file) then
        return orig_showReader(self, file, provider, seamless, is_provider_forced, after_open_callback)
    end

    logger.info("[ACSM patch] intercepted external open:", file)

    -- Already in a book, and ACSM plugin instance exists → dispatch directly.
    if ReaderUI.instance and ReaderUI.instance.acsm then
        logger.info("[ACSM patch] dispatching via active ReaderUI plugin")
        return ReaderUI.instance.acsm:openFile(file)
    end

    -- FileManager already running → use its provider dispatch.
    if FileManager.instance and FileManager.instance.acsm then
        logger.info("[ACSM patch] dispatching via active FileManager plugin")
        return FileManager.instance:openFile(file, nil, nil, nil, after_open_callback)
    end

    -- Cold start: open FileManager in the file's directory so plugins load,
    -- then dispatch the ACSM through FileManager.
    logger.info("[ACSM patch] cold start, spinning up FileManager")
    local dir = util.splitFilePathName(file)
    FileManager:showFiles(dir, file)

    UIManager:nextTick(function()
        if FileManager.instance and FileManager.instance.acsm then
            FileManager.instance:openFile(file, nil, nil, nil, after_open_callback)
        else
            -- Plugin disabled or missing — fall back to original behavior.
            logger.warn("[ACSM patch] ACSM plugin not found, falling back")
            orig_showReader(self, file, provider, seamless, is_provider_forced, after_open_callback)
        end
    end)
end
