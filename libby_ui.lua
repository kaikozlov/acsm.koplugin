local ConfirmBox = require("ui/widget/confirmbox")
local DataStorage = require("datastorage")
local ButtonDialog = require("ui/widget/buttondialog")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local Menu = require("ui/widget/menu")
local Notification = require("ui/widget/notification")
local NetworkMgr = require("ui/network/manager")
local Trapper = require("ui/trapper")
local UIManager = require("ui/uimanager")
local ffiUtil = require("ffi/util")
local util = require("util")
local _ = require("gettext")
local T = ffiUtil.template

local LibbyClient = require("libby_client")
local OverDriveClient = require("overdrive_client")

local LibbyUI = {}
LibbyUI.__index = LibbyUI

local function trimError(err)
    if type(err) == "table" then
        if err.upstream and err.upstream.userExplanation then
            return err.upstream.userExplanation
        end
        if err.result then
            return tostring(err.result)
        end
    end
    if type(err) ~= "string" then
        return tostring(err)
    end
    return err:gsub("^.-: ", "")
end

local function countItems(state, key)
    if type(state) ~= "table" or type(state[key]) ~= "table" then
        return 0
    end
    return #state[key]
end

local function sanitizeFileComponent(text)
    text = tostring(text or "loan")
    text = text:gsub("[/%z\r\n\t]", " ")
    text = text:gsub("[\\:*?\"<>|]", "-")
    text = text:gsub("%s+", " ")
    text = util.trim(text)
    if text == "" then
        text = "loan"
    end
    if #text > 80 then
        text = text:sub(1, 80)
    end
    return text
end

local function formatDateText(value)
    if type(value) ~= "string" then
        return _("Unknown")
    end
    local y, m, d = value:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)")
    if not y then
        return value
    end
    return string.format("%s-%s-%s", y, m, d)
end

local function dedupeStrings(values)
    local items = {}
    local seen = {}
    for _, value in ipairs(values or {}) do
        value = tostring(value or "")
        if value ~= "" and not seen[value] then
            items[#items + 1] = value
            seen[value] = true
        end
    end
    return items
end

local function chunkList(values, chunk_size)
    local chunks = {}
    local current = {}
    for _, value in ipairs(values or {}) do
        current[#current + 1] = value
        if #current >= chunk_size then
            chunks[#chunks + 1] = current
            current = {}
        end
    end
    if #current > 0 then
        chunks[#chunks + 1] = current
    end
    return chunks
end

local function sortLoans(loans)
    table.sort(loans, function(a, b)
        return tostring(a.checkoutDate or "") > tostring(b.checkoutDate or "")
    end)
    return loans
end

local function sortHolds(holds)
    table.sort(holds, function(a, b)
        local a_borrowable = LibbyClient.canBorrowHold(a)
        local b_borrowable = LibbyClient.canBorrowHold(b)
        if a_borrowable ~= b_borrowable then
            return a_borrowable
        end
        local a_date = tostring(a.placedDate or a.createdDate or "")
        local b_date = tostring(b.placedDate or b.createdDate or "")
        if a_date ~= b_date then
            return a_date > b_date
        end
        return tostring(a.title or "") < tostring(b.title or "")
    end)
    return holds
end

local function availabilityText(site)
    if type(site) ~= "table" then
        return _("Unknown")
    end
    if site.isAvailable then
        return _("Available")
    end
    local lucky_copies = tonumber(site.luckyDayAvailableCopies) or 0
    if lucky_copies > 0 then
        return _("Lucky day")
    end
    local wait_days = tonumber(site.estimatedWaitDays)
    if wait_days and wait_days > 0 then
        return T(_("%1 days"), tostring(wait_days))
    end
    return _("Unavailable")
end

local function mediaTitle(media)
    return tostring(media.title or media.sortTitle or _("Untitled"))
end

local function mediaAuthor(media)
    return tostring(media.firstCreatorName or _("Unknown author"))
end

function LibbyUI:new(opts)
    local instance = setmetatable({}, self)
    instance.plugin = assert(opts.plugin)
    instance.store = assert(opts.store)
    instance.state = assert(opts.state)
    instance.acsm_service = opts.acsm_service
    instance.loans_menu = nil
    instance.holds_menu = nil
    instance.search_menu = nil
    return instance
end

function LibbyUI:createClient()
    return LibbyClient:new{
        identity_token = self.store:getIdentityToken(),
    }
end

function LibbyUI:createOverDriveClient()
    return OverDriveClient:new()
end

function LibbyUI:getSyncState()
    return self.state.synced_state or self.store:getSyncState() or {}
end

function LibbyUI:getLibraries(sync_state)
    sync_state = sync_state or self:getSyncState()
    return sync_state.libraries or {}
end

function LibbyUI:getStatusText()
    if self.store:isConfigured() then
        return _("Libby account: ready")
    end
    return _("Libby account: not set")
end

function LibbyUI:closeMenu(field_name)
    if self[field_name] then
        UIManager:close(self[field_name])
        self[field_name] = nil
    end
end

function LibbyUI:refreshOpenMenus()
    self:refreshLoansMenu()
    self:refreshHoldsMenu()
    self:refreshSearchMenu()
end

function LibbyUI:getSubMenuItems()
    local sync_state = self:getSyncState()
    local loans = countItems(sync_state, "loans")
    local holds = countItems(sync_state, "holds")
    local cards = countItems(sync_state, "cards")

    return {
        {
            text_func = function()
                return self:getStatusText()
            end,
            enabled_func = function()
                return false
            end,
        },
        {
            text_func = function()
                return T(_("Cached cards: %1"), cards)
            end,
            enabled_func = function()
                return false
            end,
        },
        {
            text_func = function()
                return T(_("Cached loans: %1"), loans)
            end,
            enabled_func = function()
                return false
            end,
        },
        {
            text_func = function()
                return T(_("Cached holds: %1"), holds)
            end,
            enabled_func = function()
                return false
            end,
        },
        {
            text = _("Set up or reconnect Libby"),
            callback = function()
                self:showSetupDialog()
            end,
        },
        {
            text = _("Refresh Libby data"),
            enabled_func = function()
                return self.store:isConfigured()
            end,
            callback = function()
                self:refreshSyncInteractive()
            end,
        },
        {
            text = _("Browse loans"),
            enabled_func = function()
                return self.store:isConfigured()
            end,
            callback = function()
                self:showLoansMenu()
            end,
        },
        {
            text = _("Browse holds"),
            enabled_func = function()
                return self.store:isConfigured()
            end,
            callback = function()
                self:showHoldsMenu()
            end,
        },
        {
            text = _("Search linked libraries"),
            enabled_func = function()
                return self.store:isConfigured()
            end,
            callback = function()
                self:showSearchDialog()
            end,
        },
        {
            text_func = function()
                return self:getSearchLibrarySummaryText()
            end,
            enabled_func = function()
                return self.store:isConfigured()
            end,
            sub_item_table_func = function()
                return self:getSearchLibraryMenuItems()
            end,
        },
        {
            text = _("Forget Libby account"),
            enabled_func = function()
                return self.store:isConfigured()
            end,
            callback = function()
                self:confirmForgetAccount()
            end,
        },
    }
end

function LibbyUI:parseCredentialInput(input)
    input = util.trim(input or "")
    if input == "" then
        return nil, "empty"
    end

    local token = input:match([["libby_token"%s*:%s*"([^"]+)"]])
    if not token then
        token = input:match("^[Bb]earer%s+(.+)$")
    end
    if token then
        return { kind = "token", value = util.trim(token) }
    end

    if LibbyClient.isValidSyncCode(input) then
        return { kind = "setup_code", value = input }
    end

    if not input:find("%s") and #input > 32 then
        return { kind = "token", value = input }
    end

    return nil, "invalid"
end

function LibbyUI:getDownloadDir()
    return DataStorage:getDataDir() .. "/libby"
end

function LibbyUI:ensureDownloadDir()
    local download_dir = self:getDownloadDir()
    local ok, err = util.makePath(download_dir)
    if not ok then
        return nil, err
    end
    return download_dir
end

function LibbyUI:getCardById(card_id)
    local sync_state = self:getSyncState()
    for _, card in ipairs(sync_state.cards or {}) do
        if card.cardId == card_id then
            return card
        end
    end
    return nil
end

function LibbyUI:getLibraryByWebsiteId(website_id)
    if website_id == nil then
        return nil
    end
    for _, library in ipairs(self:getLibraries()) do
        if tostring(library.websiteId) == tostring(website_id) then
            return library
        end
    end
    return nil
end

function LibbyUI:getLibraryByKey(library_key)
    for _, library in ipairs(self:getLibraries()) do
        if tostring(library.preferredKey or library.advantageKey or "") == tostring(library_key or "") then
            return library
        end
    end
    return nil
end

function LibbyUI:getCardLibrary(card)
    if type(card) ~= "table" then
        return nil
    end
    local website_id = util.tableGetValue(card, "library", "websiteId") or card.websiteId
    return self:getLibraryByWebsiteId(website_id) or card.library
end

function LibbyUI:getCardsForLibraryKey(library_key)
    local sync_state = self:getSyncState()
    local cards = {}
    local website_ids = {}

    for _, library in ipairs(self:getLibraries(sync_state)) do
        if tostring(library.preferredKey or "") == tostring(library_key or "") then
            website_ids[tostring(library.websiteId)] = true
        end
    end

    for _, card in ipairs(sync_state.cards or {}) do
        local website_id = util.tableGetValue(card, "library", "websiteId") or card.websiteId
        if card.advantageKey == library_key or website_ids[tostring(website_id or "")] then
            cards[#cards + 1] = card
        end
    end

    table.sort(cards, function(a, b)
        return tostring(a.cardName or a.advantageKey or "") < tostring(b.cardName or b.advantageKey or "")
    end)
    return cards
end

function LibbyUI:getAvailableSearchLibraryKeys(sync_state)
    sync_state = sync_state or self:getSyncState()
    local keys = {}
    for _, library in ipairs(self:getLibraries(sync_state)) do
        keys[#keys + 1] = library.preferredKey or library.advantageKey
    end
    if #keys == 0 then
        for _, card in ipairs(sync_state.cards or {}) do
            keys[#keys + 1] = card.advantageKey
        end
    end
    keys = dedupeStrings(keys)
    table.sort(keys)
    return keys
end

function LibbyUI:normalizeSelectedSearchLibraries(sync_state)
    local available = self:getAvailableSearchLibraryKeys(sync_state)
    local available_set = {}
    for _, key in ipairs(available) do
        available_set[key] = true
    end

    local selected = {}
    for _, key in ipairs(self.store:getSelectedSearchLibraries() or {}) do
        if available_set[key] then
            selected[#selected + 1] = key
        end
    end
    selected = dedupeStrings(selected)

    if #selected == 0 then
        for index = 1, math.min(#available, OverDriveClient.MAX_PER_PAGE) do
            selected[#selected + 1] = available[index]
        end
    end
    while #selected > OverDriveClient.MAX_PER_PAGE do
        table.remove(selected)
    end

    self.store:setSelectedSearchLibraries(selected)
    return selected, available
end

function LibbyUI:getSelectedSearchLibraries(sync_state)
    local selected = {}
    for _, key in ipairs(self:normalizeSelectedSearchLibraries(sync_state)) do
        selected[#selected + 1] = key
    end
    return selected
end

function LibbyUI:getSearchLibraryLabel(library_key)
    local library = self:getLibraryByKey(library_key)
    if library and library.name and library.name ~= "" then
        return tostring(library.name) .. " (" .. tostring(library_key) .. ")"
    end
    return tostring(library_key)
end

function LibbyUI:getSearchLibrarySummaryText()
    local available = self:getAvailableSearchLibraryKeys()
    local selected = self:getSelectedSearchLibraries()
    if #available == 0 then
        return _("Search libraries: none linked")
    end
    return T(_("Search libraries: %1 of %2 selected"), tostring(#selected), tostring(#available))
end

function LibbyUI:toggleSearchLibrary(library_key)
    local selected, available = self:normalizeSelectedSearchLibraries()
    local selected_set = {}
    for _, key in ipairs(selected) do
        selected_set[key] = true
    end

    if selected_set[library_key] then
        if #selected <= 1 then
            UIManager:show(InfoMessage:new{
                text = _("Keep at least one search library selected."),
            })
            return
        end
        local remaining = {}
        for _, key in ipairs(selected) do
            if key ~= library_key then
                remaining[#remaining + 1] = key
            end
        end
        self.store:setSelectedSearchLibraries(remaining)
    else
        if #selected >= OverDriveClient.MAX_PER_PAGE then
            UIManager:show(InfoMessage:new{
                text = T(_("Libby search is limited to %1 libraries at once."), tostring(OverDriveClient.MAX_PER_PAGE)),
            })
            return
        end
        selected[#selected + 1] = library_key
        table.sort(selected)
        self.store:setSelectedSearchLibraries(selected)
    end
    self.store:flush()

    if #available > OverDriveClient.MAX_PER_PAGE then
        UIManager:show(Notification:new{
            text = T(_("Search uses up to %1 selected libraries."), tostring(OverDriveClient.MAX_PER_PAGE)),
        })
    end
end

function LibbyUI:getSearchLibraryMenuItems()
    local selected, available = self:normalizeSelectedSearchLibraries()
    local selected_set = {}
    for _, key in ipairs(selected) do
        selected_set[key] = true
    end

    local items = {
        {
            text = self:getSearchLibrarySummaryText(),
            enabled_func = function()
                return false
            end,
        },
    }

    if #available == 0 then
        items[#items + 1] = {
            text = _("No linked libraries available yet."),
            enabled_func = function()
                return false
            end,
        }
        return items
    end

    items[#items + 1] = {
        text = _("Use all linked libraries"),
        callback = function()
            local all_keys = {}
            for index = 1, math.min(#available, OverDriveClient.MAX_PER_PAGE) do
                all_keys[#all_keys + 1] = available[index]
            end
            self.store:setSelectedSearchLibraries(all_keys)
            self.store:flush()
        end,
    }

    for _, library_key in ipairs(available) do
        items[#items + 1] = {
            text = self:getSearchLibraryLabel(library_key),
            checked_func = function()
                local current_selected = self:getSelectedSearchLibraries()
                for _, key in ipairs(current_selected) do
                    if key == library_key then
                        return true
                    end
                end
                return false
            end,
            callback = function()
                self:toggleSearchLibrary(library_key)
            end,
            enabled_func = function()
                return self.store:isConfigured()
            end,
        }
    end

    return items
end

function LibbyUI:getLoanPaths(loan)
    local dir, err = self:ensureDownloadDir()
    if not dir then
        return nil, err
    end

    local title = sanitizeFileComponent(loan.title or loan.sortTitle or "loan")
    local stem = dir .. "/" .. title .. " - " .. tostring(loan.id)
    return {
        directory = dir,
        stem = stem,
        acsm = stem .. ".acsm",
        epub = stem .. ".epub",
    }
end

function LibbyUI:buildLoanMenuItems()
    local sync_state = self:getSyncState()
    local loans = {}
    for _, loan in ipairs(sync_state.loans or {}) do
        loans[#loans + 1] = loan
    end
    sortLoans(loans)

    local items = {}
    for _, loan in ipairs(loans) do
        local card = self:getCardById(loan.cardId)
        local library = self:getCardLibrary(card)
        items[#items + 1] = {
            text = mediaTitle(loan) .. "\n" .. mediaAuthor(loan),
            mandatory = formatDateText(loan.expireDate),
            loan = loan,
            callback = function()
                self:downloadOrOpenLoan(loan)
            end,
            hold_callback = function()
                self:showLoanActions(loan)
            end,
            post_text = tostring((library and library.preferredKey) or (card and card.advantageKey) or _("Unknown library")),
        }
    end

    return items
end

function LibbyUI:buildHoldMenuItems()
    local sync_state = self:getSyncState()
    local holds = {}
    for _, hold in ipairs(sync_state.holds or {}) do
        holds[#holds + 1] = hold
    end
    sortHolds(holds)

    local items = {}
    for _, hold in ipairs(holds) do
        local card = self:getCardById(hold.cardId)
        local library = self:getCardLibrary(card)
        items[#items + 1] = {
            text = mediaTitle(hold) .. "\n" .. mediaAuthor(hold),
            mandatory = availabilityText(hold),
            hold = hold,
            callback = function()
                self:showHoldActions(hold)
            end,
            hold_callback = function()
                self:showHoldActions(hold)
            end,
            post_text = tostring((library and library.preferredKey) or (card and card.advantageKey) or _("Unknown library")),
        }
    end

    return items
end

function LibbyUI:getSearchSites(media, include_unavailable)
    local sites = {}
    for library_key, site in pairs(media.siteAvailabilities or {}) do
        local entry = util.tableDeepCopy(site)
        entry.advantageKey = library_key
        entry.cards = self:getCardsForLibraryKey(library_key)
        entry.library = self:getLibraryByKey(library_key)
        if include_unavailable or (entry.ownedCopies or 0) > 0 or OverDriveClient.isSiteAvailable(entry) then
            sites[#sites + 1] = entry
        end
    end
    table.sort(sites, OverDriveClient.isSiteAvailabilityBetter)
    return sites
end

function LibbyUI:getBestSearchSite(media)
    return self:getSearchSites(media, true)[1]
end

function LibbyUI:buildSearchMenuItems()
    local results = self.state.search_results or {}
    local items = {}
    for _, media in ipairs(results) do
        local best_site = self:getBestSearchSite(media)
        items[#items + 1] = {
            text = mediaTitle(media) .. "\n" .. mediaAuthor(media),
            mandatory = availabilityText(best_site),
            callback = function()
                self:showSearchResultActions(media)
            end,
            hold_callback = function()
                self:showSearchResultActions(media)
            end,
            post_text = best_site and tostring(best_site.advantageKey) or nil,
        }
    end
    return items
end

function LibbyUI:refreshLoansMenu()
    if self.loans_menu then
        self.loans_menu:switchItemTable(_("Libby Loans"), self:buildLoanMenuItems(), 1)
    end
end

function LibbyUI:refreshHoldsMenu()
    if self.holds_menu then
        self.holds_menu:switchItemTable(_("Libby Holds"), self:buildHoldMenuItems(), 1)
    end
end

function LibbyUI:refreshSearchMenu()
    if self.search_menu then
        local title = self.state.last_search_query and T(_("Search: %1"), self.state.last_search_query) or _("Search results")
        self.search_menu:switchItemTable(title, self:buildSearchMenuItems(), 1)
    end
end

function LibbyUI:showManagedMenu(field_name, title, items, refresh_callback)
    local buttons = {
        {
            {
                text = _("Refresh"),
                callback = refresh_callback,
            },
            {
                text = _("Close"),
                callback = function()
                    self:closeMenu(field_name)
                end,
            },
        },
    }

    self:closeMenu(field_name)
    self[field_name] = Menu:new{
        title = title,
        item_table = items,
        is_borderless = true,
        is_popout = false,
        onMenuSelect = function(_, item)
            if item and item.callback then
                item.callback()
            end
        end,
        onMenuHold = function(_, item)
            if item and item.hold_callback then
                item.hold_callback()
            end
        end,
        close_callback = function()
            self[field_name] = nil
        end,
        buttons_table = buttons,
    }
    UIManager:show(self[field_name])
end

function LibbyUI:showLoansMenu()
    if not self.store:isConfigured() then
        UIManager:show(InfoMessage:new{
            text = _("Set up Libby first."),
        })
        return
    end

    local items = self:buildLoanMenuItems()
    if #items == 0 then
        UIManager:show(InfoMessage:new{
            text = _("No Libby loans found in the cached account state."),
        })
        return
    end

    self:showManagedMenu("loans_menu", _("Libby Loans"), items, function()
        self:refreshSyncInteractive(function()
            self:refreshLoansMenu()
        end)
    end)
end

function LibbyUI:showHoldsMenu()
    if not self.store:isConfigured() then
        UIManager:show(InfoMessage:new{
            text = _("Set up Libby first."),
        })
        return
    end

    local items = self:buildHoldMenuItems()
    if #items == 0 then
        UIManager:show(InfoMessage:new{
            text = _("No Libby holds found in the cached account state."),
        })
        return
    end

    self:showManagedMenu("holds_menu", _("Libby Holds"), items, function()
        self:refreshSyncInteractive(function()
            self:refreshHoldsMenu()
        end)
    end)
end

function LibbyUI:showSearchResultsMenu(query)
    local items = self:buildSearchMenuItems()
    if #items == 0 then
        UIManager:show(InfoMessage:new{
            text = _("No linked libraries returned results for that search."),
        })
        return
    end

    self:showManagedMenu("search_menu", T(_("Search: %1"), query), items, function()
        self:showSearchDialog(query)
    end)
end

function LibbyUI:showLoanDetails(loan)
    local card = self:getCardById(loan.cardId)
    local library = self:getCardLibrary(card)
    local lines = {
        mediaTitle(loan),
        "",
        T(_("Author: %1"), mediaAuthor(loan)),
        T(_("Due: %1"), formatDateText(loan.expireDate)),
        T(_("Library: %1"), tostring((library and library.name) or (card and card.advantageKey) or _("Unknown"))),
    }
    local locked = LibbyClient.getLockedInFormat(loan)
    if locked then
        lines[#lines + 1] = T(_("Locked format: %1"), locked)
    end
    UIManager:show(InfoMessage:new{
        text = table.concat(lines, "\n"),
    })
end

function LibbyUI:showHoldDetails(hold)
    local card = self:getCardById(hold.cardId)
    local library = self:getCardLibrary(card)
    local lines = {
        mediaTitle(hold),
        "",
        T(_("Author: %1"), mediaAuthor(hold)),
        T(_("Library: %1"), tostring((library and library.name) or (card and card.advantageKey) or _("Unknown"))),
        T(_("Status: %1"), availabilityText(hold)),
    }
    if hold.placedDate then
        lines[#lines + 1] = T(_("Placed: %1"), formatDateText(hold.placedDate))
    end
    UIManager:show(InfoMessage:new{
        text = table.concat(lines, "\n"),
    })
end

function LibbyUI:showSearchResultDetails(media)
    local lines = {
        mediaTitle(media),
        "",
        T(_("Author: %1"), mediaAuthor(media)),
    }
    local publisher = util.tableGetValue(media, "publisher", "name")
    if publisher then
        lines[#lines + 1] = T(_("Publisher: %1"), tostring(publisher))
    end
    for site_index, site_info in ipairs(self:getSearchSites(media, true)) do
        local name = site_info.library and site_info.library.name or site_info.advantageKey
        lines[#lines + 1] = T(_("%1: %2"), tostring(name), availabilityText(site_info))
    end
    UIManager:show(InfoMessage:new{
        text = table.concat(lines, "\n"),
    })
end

function LibbyUI:showLoanActions(loan)
    local dialog
    local loan_format, format_err = LibbyClient.getLoanFormat(loan)
    dialog = ButtonDialog:new{
        title = mediaTitle(loan),
        buttons = {
            {{
                text = _("Download / Open"),
                callback = function()
                    UIManager:close(dialog)
                    self:downloadOrOpenLoan(loan)
                end,
                enabled = loan_format ~= nil,
                align = "left",
            }},
            {{
                text = _("Return"),
                callback = function()
                    UIManager:close(dialog)
                    self:confirmReturnLoan(loan)
                end,
                align = "left",
            }},
            {{
                text = _("Renew"),
                callback = function()
                    UIManager:close(dialog)
                    self:confirmRenewLoan(loan)
                end,
                enabled = LibbyClient.isRenewable(loan),
                align = "left",
            }},
            {{
                text = _("Details"),
                callback = function()
                    UIManager:close(dialog)
                    self:showLoanDetails(loan)
                end,
                align = "left",
            }},
            format_err and {{
                text = format_err,
                enabled = false,
                align = "left",
            }} or {},
        },
        shrink_unneeded_width = true,
    }
    UIManager:show(dialog)
end

function LibbyUI:showHoldActions(hold)
    local dialog
    local card = self:getCardById(hold.cardId)
    dialog = ButtonDialog:new{
        title = mediaTitle(hold),
        buttons = {
            {{
                text = _("Borrow now"),
                callback = function()
                    UIManager:close(dialog)
                    self:borrowHold(hold)
                end,
                enabled = LibbyClient.canBorrowHold(hold) and LibbyClient.canBorrow(card or {}),
                align = "left",
            }},
            {{
                text = _("Cancel hold"),
                callback = function()
                    UIManager:close(dialog)
                    self:confirmCancelHold(hold)
                end,
                align = "left",
            }},
            {{
                text = _("Details"),
                callback = function()
                    UIManager:close(dialog)
                    self:showHoldDetails(hold)
                end,
                align = "left",
            }},
        },
        shrink_unneeded_width = true,
    }
    UIManager:show(dialog)
end

function LibbyUI:hasLoan(title_id, card_id)
    for _, loan in ipairs(self:getSyncState().loans or {}) do
        if tostring(loan.id) == tostring(title_id) and tostring(loan.cardId) == tostring(card_id) then
            return true
        end
    end
    return false
end

function LibbyUI:hasHold(title_id, card_id)
    for _, hold in ipairs(self:getSyncState().holds or {}) do
        if tostring(hold.id) == tostring(title_id) and tostring(hold.cardId) == tostring(card_id) then
            return true
        end
    end
    return false
end

function LibbyUI:showSearchResultActions(media)
    local dialog
    local buttons = {}

    for site_index, site_info in ipairs(self:getSearchSites(media, true)) do
        for card_index, card_info in ipairs(site_info.cards or {}) do
            local card_label = tostring(card_info.advantageKey or site_info.advantageKey)
            if card_info.cardName and card_info.cardName ~= "" then
                card_label = card_label .. ": " .. tostring(card_info.cardName)
            end
            if OverDriveClient.isSiteAvailable(site_info) then
                buttons[#buttons + 1] = {{
                    text = T(_("Borrow from %1"), card_label),
                    enabled = LibbyClient.canBorrow(card_info) and not self:hasLoan(media.id, card_info.cardId),
                    callback = function()
                        UIManager:close(dialog)
                        self:borrowSearchMedia(media, card_info, site_info)
                    end,
                    align = "left",
                }}
            else
                buttons[#buttons + 1] = {{
                    text = T(_("Place hold at %1"), card_label),
                    enabled = LibbyClient.canPlaceHold(card_info) and not self:hasHold(media.id, card_info.cardId),
                    callback = function()
                        UIManager:close(dialog)
                        self:createHoldFromSearch(media, card_info)
                    end,
                    align = "left",
                }}
            end
        end
    end

    if #buttons == 0 then
        buttons[#buttons + 1] = {{
            text = _("No linked cards can act on this title."),
            enabled = false,
            align = "left",
        }}
    end

    buttons[#buttons + 1] = {{
        text = _("Details"),
        callback = function()
            UIManager:close(dialog)
            self:showSearchResultDetails(media)
        end,
        align = "left",
    }}

    dialog = ButtonDialog:new{
        title = mediaTitle(media),
        buttons = buttons,
        shrink_unneeded_width = true,
        rows_per_page = { 6, 8, 10 },
    }
    UIManager:show(dialog)
end

function LibbyUI:showSetupDialog()
    local dialog
    dialog = InputDialog:new{
        title = _("Libby Setup"),
        description = _("Enter an 8-digit Libby setup code or a raw bearer token."),
        input = self.store:getSetupCode() or "",
        input_hint = _("Setup code or token"),
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = _("Connect"),
                    is_enter_default = true,
                    callback = function()
                        local value = dialog:getInputText()
                        UIManager:close(dialog)
                        self:authenticateInput(value)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function LibbyUI:showSearchDialog(default_query)
    local dialog
    dialog = InputDialog:new{
        title = _("Search linked libraries"),
        description = _("Search across the selected linked Libby libraries."),
        input = default_query or self.state.last_search_query or "",
        input_hint = _("Title, author, or keyword"),
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = _("Search"),
                    is_enter_default = true,
                    callback = function()
                        local query = dialog:getInputText()
                        UIManager:close(dialog)
                        self:searchLinkedLibraries(query)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function LibbyUI:fetchLibraryMetadata(sync_state)
    local website_ids = {}
    for _, card in ipairs(sync_state.cards or {}) do
        website_ids[#website_ids + 1] = util.tableGetValue(card, "library", "websiteId") or card.websiteId
    end
    website_ids = dedupeStrings(website_ids)
    sync_state.libraries = {}

    if #website_ids == 0 then
        return sync_state
    end

    local client = self:createOverDriveClient()
    local libraries = {}
    for chunk_index, website_id_chunk_ids in ipairs(chunkList(website_ids, OverDriveClient.MAX_PER_PAGE)) do
        Trapper:info(_("Refreshing linked library metadata..."), false, true)
        local response, err = client:libraries{
            website_ids = website_id_chunk_ids,
            per_page = math.max(#website_id_chunk_ids, 1),
        }
        if not response then
            return nil, err
        end
        for _, item in ipairs(response.items or {}) do
            libraries[#libraries + 1] = item
        end
    end
    sync_state.libraries = libraries
    return sync_state
end

function LibbyUI:syncAccountState(client, progress_text)
    Trapper:info(progress_text or _("Refreshing Libby data..."), false, true)
    local sync_state, err = client:sync()
    if not sync_state then
        return nil, err
    end

    sync_state, err = self:fetchLibraryMetadata(sync_state)
    if not sync_state then
        return nil, err
    end

    self:normalizeSelectedSearchLibraries(sync_state)

    self.store:setIdentityToken(client.identity_token)
    self.store:setSyncState(sync_state)
    self.store:setLastSyncTime(os.time())
    self.store:flush()

    self.state.synced_state = sync_state
    self.state.last_sync_time = os.time()

    return sync_state
end

function LibbyUI:authenticateInput(input)
    local parsed, parse_err = self:parseCredentialInput(input)
    if not parsed then
        UIManager:show(InfoMessage:new{
            text = parse_err == "empty"
                and _("Enter a Libby setup code or token first.")
                or _("That does not look like a valid Libby setup code or token."),
        })
        return
    end

    if NetworkMgr:willRerunWhenOnline(function() self:authenticateInput(input) end) then
        return
    end

    Trapper:wrap(function()
        Trapper:info(_("Connecting to Libby..."), false, true)

        local client = LibbyClient:new()
        if parsed.kind == "token" then
            client:setIdentityToken(parsed.value)
        else
            local chip, chip_err = client:getChip(true, false)
            if not chip then
                Trapper:reset()
                UIManager:show(InfoMessage:new{
                    text = T(_("Failed to initialize Libby:\n%1"), trimError(chip_err)),
                })
                return
            end

            local cloned, clone_err = client:cloneByCode(parsed.value)
            if not cloned then
                Trapper:reset()
                UIManager:show(InfoMessage:new{
                    text = T(_("Libby setup failed:\n%1"), trimError(clone_err)),
                })
                return
            end
        end

        local sync_state, sync_err = self:syncAccountState(client, _("Syncing Libby account..."))
        if not sync_state then
            Trapper:reset()
            UIManager:show(InfoMessage:new{
                text = T(_("Libby sync failed:\n%1"), trimError(sync_err)),
            })
            return
        end
        if sync_state.result ~= "synchronized" or type(sync_state.cards) ~= "table" or #sync_state.cards == 0 then
            Trapper:reset()
            UIManager:show(InfoMessage:new{
                text = _("Libby did not return a usable account state."),
            })
            return
        end
        self.store:setSetupCode(parsed.kind == "setup_code" and parsed.value or nil)
        self.store:flush()

        Trapper:clear()
        UIManager:show(Notification:new{
            text = _("Libby account connected."),
        })
    end)
end

function LibbyUI:refreshSyncInteractive(on_done)
    if not self.store:isConfigured() then
        UIManager:show(InfoMessage:new{
            text = _("Set up Libby first."),
        })
        return
    end

    if NetworkMgr:willRerunWhenOnline(function() self:refreshSyncInteractive(on_done) end) then
        return
    end

    Trapper:wrap(function()
        local client = self:createClient()
        local sync_state, err = self:syncAccountState(client, _("Refreshing Libby data..."))
        if not sync_state then
            Trapper:reset()
            UIManager:show(InfoMessage:new{
                text = T(_("Libby refresh failed:\n%1"), trimError(err)),
            })
            return
        end

        Trapper:clear()
        self:refreshOpenMenus()
        if on_done then
            on_done(sync_state)
        end
        UIManager:show(Notification:new{
            text = _("Libby data refreshed."),
        })
    end)
end

function LibbyUI:downloadOrOpenLoan(loan)
    local paths, path_err = self:getLoanPaths(loan)
    if not paths then
        UIManager:show(InfoMessage:new{
            text = T(_("Could not prepare download directory:\n%1"), trimError(path_err)),
        })
        return
    end

    if self.acsm_service:getReuseExisting() and util.pathExists(paths.epub) then
        self.plugin:openGeneratedBook(paths.epub)
        return
    end

    local existing_acsm = util.pathExists(paths.acsm)

    if NetworkMgr:willRerunWhenOnline(function() self:downloadOrOpenLoan(loan) end) then
        return
    end

    Trapper:wrap(function()
        local acsm_path = paths.acsm
        if not existing_acsm then
            local format_id, format_err = LibbyClient.getLoanFormat(loan)
            if not format_id then
                Trapper:reset()
                UIManager:show(InfoMessage:new{
                    text = T(_("This loan cannot be downloaded here:\n%1"), trimError(format_err)),
                })
                return
            end

            Trapper:info(_("Downloading loan file..."), false, true)
            local client = self:createClient()
            local contents, err = client:fulfillLoanFile(loan.id, loan.cardId, format_id)
            if not contents then
                Trapper:reset()
                UIManager:show(InfoMessage:new{
                    text = T(_("Failed to download Libby loan:\n%1"), trimError(err)),
                })
                return
            end

            self.store:setIdentityToken(client.identity_token)
            self.store:flush()

            local saved_path, save_err = self.acsm_service:saveLoanFile(acsm_path, contents)
            if not saved_path then
                Trapper:reset()
                UIManager:show(InfoMessage:new{
                    text = T(_("Failed to save ACSM file:\n%1"), trimError(save_err)),
                })
                return
            end
            acsm_path = saved_path
        end

        Trapper:info(_("Preparing loan..."), false, true)
        local result, fulfill_err = self.acsm_service:fulfillLoan(acsm_path, paths.epub, function(text)
            Trapper:info(text, false, true)
        end)
        if not result then
            Trapper:reset()
            UIManager:show(InfoMessage:new{
                text = T(_("Loan fulfillment failed:\n%1"), trimError(fulfill_err)),
            })
            return
        end

        Trapper:clear()
        UIManager:nextTick(function()
            self.plugin:openGeneratedBook(result.outputPath)
        end)
    end)
end

function LibbyUI:confirmReturnLoan(loan)
    UIManager:show(ConfirmBox:new{
        text = T(_("Return \"%1\"?"), mediaTitle(loan)),
        ok_text = _("Return"),
        ok_callback = function()
            self:returnLoan(loan)
        end,
    })
end

function LibbyUI:returnLoan(loan)
    if NetworkMgr:willRerunWhenOnline(function() self:returnLoan(loan) end) then
        return
    end

    Trapper:wrap(function()
        Trapper:info(_("Returning loan..."), false, true)
        local client = self:createClient()
        local _, err = client:returnLoan(loan)
        if err then
            Trapper:reset()
            UIManager:show(InfoMessage:new{
                text = T(_("Failed to return loan:\n%1"), trimError(err)),
            })
            return
        end

        local sync_state, sync_err = self:syncAccountState(client, _("Refreshing Libby data..."))
        if not sync_state then
            Trapper:reset()
            UIManager:show(InfoMessage:new{
                text = T(_("Loan returned, but refresh failed:\n%1"), trimError(sync_err)),
            })
            return
        end

        Trapper:clear()
        self:refreshOpenMenus()
        UIManager:show(Notification:new{
            text = _("Loan returned."),
        })
    end)
end

function LibbyUI:confirmRenewLoan(loan)
    if not LibbyClient.isRenewable(loan) then
        UIManager:show(InfoMessage:new{
            text = _("This loan is not renewable yet."),
        })
        return
    end

    UIManager:show(ConfirmBox:new{
        text = T(_("Renew \"%1\"?"), mediaTitle(loan)),
        ok_text = _("Renew"),
        ok_callback = function()
            self:renewLoan(loan)
        end,
    })
end

function LibbyUI:renewLoan(loan)
    if NetworkMgr:willRerunWhenOnline(function() self:renewLoan(loan) end) then
        return
    end

    Trapper:wrap(function()
        Trapper:info(_("Renewing loan..."), false, true)
        local client = self:createClient()
        local _, err = client:renewLoan(loan, self:getCardById(loan.cardId))
        if err then
            Trapper:reset()
            UIManager:show(InfoMessage:new{
                text = T(_("Failed to renew loan:\n%1"), trimError(err)),
            })
            return
        end

        local sync_state, sync_err = self:syncAccountState(client, _("Refreshing Libby data..."))
        if not sync_state then
            Trapper:reset()
            UIManager:show(InfoMessage:new{
                text = T(_("Loan renewed, but refresh failed:\n%1"), trimError(sync_err)),
            })
            return
        end

        Trapper:clear()
        self:refreshOpenMenus()
        UIManager:show(Notification:new{
            text = _("Loan renewed."),
        })
    end)
end

function LibbyUI:confirmCancelHold(hold)
    UIManager:show(ConfirmBox:new{
        text = T(_("Cancel hold for \"%1\"?"), mediaTitle(hold)),
        ok_text = _("Cancel hold"),
        ok_callback = function()
            self:cancelHold(hold)
        end,
    })
end

function LibbyUI:cancelHold(hold)
    if NetworkMgr:willRerunWhenOnline(function() self:cancelHold(hold) end) then
        return
    end

    Trapper:wrap(function()
        Trapper:info(_("Canceling hold..."), false, true)
        local client = self:createClient()
        local _, err = client:cancelHold(hold)
        if err then
            Trapper:reset()
            UIManager:show(InfoMessage:new{
                text = T(_("Failed to cancel hold:\n%1"), trimError(err)),
            })
            return
        end

        local sync_state, sync_err = self:syncAccountState(client, _("Refreshing Libby data..."))
        if not sync_state then
            Trapper:reset()
            UIManager:show(InfoMessage:new{
                text = T(_("Hold canceled, but refresh failed:\n%1"), trimError(sync_err)),
            })
            return
        end

        Trapper:clear()
        self:refreshOpenMenus()
        UIManager:show(Notification:new{
            text = _("Hold canceled."),
        })
    end)
end

function LibbyUI:borrowHold(hold)
    local card = self:getCardById(hold.cardId)
    if not card then
        UIManager:show(InfoMessage:new{
            text = _("This hold does not have a usable card attached."),
        })
        return
    end

    if NetworkMgr:willRerunWhenOnline(function() self:borrowHold(hold) end) then
        return
    end

    Trapper:wrap(function()
        Trapper:info(_("Borrowing hold..."), false, true)
        local client = self:createClient()
        local _, err = client:borrowMedia(hold, card, hold)
        if err then
            Trapper:reset()
            UIManager:show(InfoMessage:new{
                text = T(_("Failed to borrow hold:\n%1"), trimError(err)),
            })
            return
        end

        local sync_state, sync_err = self:syncAccountState(client, _("Refreshing Libby data..."))
        if not sync_state then
            Trapper:reset()
            UIManager:show(InfoMessage:new{
                text = T(_("Hold borrowed, but refresh failed:\n%1"), trimError(sync_err)),
            })
            return
        end

        Trapper:clear()
        self:refreshOpenMenus()
        UIManager:show(Notification:new{
            text = _("Hold borrowed."),
        })
    end)
end

function LibbyUI:normalizeSearchResults(results)
    local items = results.items or results
    if type(items) ~= "table" then
        return {}
    end

    local normalized = {}
    for _, item in ipairs(items) do
        local media = util.tableDeepCopy(item)
        if (type(media.formats) ~= "table" or #media.formats == 0) and type(media.siteAvailabilities) == "table" then
            local formats = {}
            local seen_format_ids = {}
            for _, site in pairs(media.siteAvailabilities) do
                for _, format in ipairs(site.formats or {}) do
                    if format.id and not seen_format_ids[format.id] then
                        formats[#formats + 1] = format
                        seen_format_ids[format.id] = true
                    end
                end
            end
            if #formats > 0 then
                media.formats = formats
            end
        end
        normalized[#normalized + 1] = media
    end

    table.sort(normalized, function(a, b)
        local best_a = self:getBestSearchSite(a)
        local best_b = self:getBestSearchSite(b)
        if best_a and best_b then
            local better = OverDriveClient.isSiteAvailabilityBetter(best_a, best_b)
            local worse = OverDriveClient.isSiteAvailabilityBetter(best_b, best_a)
            if better ~= worse then
                return better
            end
        elseif best_a or best_b then
            return best_a ~= nil
        end
        return mediaTitle(a) < mediaTitle(b)
    end)

    return normalized
end

function LibbyUI:searchLinkedLibraries(query)
    query = util.trim(query or "")
    if query == "" then
        UIManager:show(InfoMessage:new{
            text = _("Enter something to search for first."),
        })
        return
    end

    local library_keys = self:getSelectedSearchLibraries()
    if #library_keys == 0 then
        UIManager:show(InfoMessage:new{
            text = _("Select at least one linked library first."),
        })
        return
    end

    if NetworkMgr:willRerunWhenOnline(function() self:searchLinkedLibraries(query) end) then
        return
    end

    Trapper:wrap(function()
        Trapper:info(_("Searching linked libraries..."), false, true)
        local client = self:createOverDriveClient()
        local results, err = client:mediaSearch(library_keys, query, {
            max_items = 30,
        })
        if not results then
            Trapper:reset()
            UIManager:show(InfoMessage:new{
                text = T(_("Libby search failed:\n%1"), trimError(err)),
            })
            return
        end

        self.state.last_search_query = query
        self.state.search_results = self:normalizeSearchResults(results)

        Trapper:clear()
        self:showSearchResultsMenu(query)
    end)
end

function LibbyUI:borrowSearchMedia(media, card, availability)
    if NetworkMgr:willRerunWhenOnline(function() self:borrowSearchMedia(media, card, availability) end) then
        return
    end

    Trapper:wrap(function()
        Trapper:info(_("Borrowing title..."), false, true)
        local client = self:createClient()
        local _, err = client:borrowMedia(media, card, availability)
        if err then
            Trapper:reset()
            UIManager:show(InfoMessage:new{
                text = T(_("Failed to borrow title:\n%1"), trimError(err)),
            })
            return
        end

        local sync_state, sync_err = self:syncAccountState(client, _("Refreshing Libby data..."))
        if not sync_state then
            Trapper:reset()
            UIManager:show(InfoMessage:new{
                text = T(_("Title borrowed, but refresh failed:\n%1"), trimError(sync_err)),
            })
            return
        end

        Trapper:clear()
        self:refreshOpenMenus()
        UIManager:show(Notification:new{
            text = _("Title borrowed."),
        })
    end)
end

function LibbyUI:createHoldFromSearch(media, card)
    if NetworkMgr:willRerunWhenOnline(function() self:createHoldFromSearch(media, card) end) then
        return
    end

    Trapper:wrap(function()
        Trapper:info(_("Placing hold..."), false, true)
        local client = self:createClient()
        local _, err = client:createHold(media.id, card.cardId)
        if err then
            Trapper:reset()
            UIManager:show(InfoMessage:new{
                text = T(_("Failed to place hold:\n%1"), trimError(err)),
            })
            return
        end

        local sync_state, sync_err = self:syncAccountState(client, _("Refreshing Libby data..."))
        if not sync_state then
            Trapper:reset()
            UIManager:show(InfoMessage:new{
                text = T(_("Hold placed, but refresh failed:\n%1"), trimError(sync_err)),
            })
            return
        end

        Trapper:clear()
        self:refreshOpenMenus()
        UIManager:show(Notification:new{
            text = _("Hold placed."),
        })
    end)
end

function LibbyUI:confirmForgetAccount()
    UIManager:show(ConfirmBox:new{
        text = _("Forget the saved Libby account and cached data?"),
        ok_text = _("Forget"),
        ok_callback = function()
            self:closeMenu("loans_menu")
            self:closeMenu("holds_menu")
            self:closeMenu("search_menu")
            self.store:clearAccount()
            self.store:flush()
            self.state.synced_state = nil
            self.state.last_sync_time = nil
            self.state.last_search_query = nil
            self.state.search_results = nil
            UIManager:show(Notification:new{
                text = _("Saved Libby account cleared."),
            })
        end,
    })
end

return LibbyUI
