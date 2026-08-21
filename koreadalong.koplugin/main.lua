local WidgetContainer = require("ui/widget/container/widgetcontainer")
local FragmentResolver = require("fragmentresolver")
local Materializer = require("materializer")
local MediaOverlays = require("mediaoverlays")
local MpvAudio = require("mpvaudio")
local PlaybackCoordinator = require("playbackcoordinator")
local Timeline = require("timeline")
local UnderlineOverlay = require("underlineoverlay")
local Event = require("ui/event")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local _ = require("gettext")

local KoReadalong = WidgetContainer:extend({
    name = "koreadalong",
    is_doc_only = true,
})

local function refresh_overlay(self)
    if self.overlay then
        self.overlay:refresh()
    end
end

local function follow_range(self, pos0, pos1)
    if self.document:isXPointerInCurrentPage(pos0)
        or self.document:isXPointerInCurrentPage(pos1) then
        return
    end
    self.ui:handleEvent(Event:new("GotoXPointer", pos0))
    refresh_overlay(self)
end

local function selected_xpointers(highlight)
    local selected_text = highlight and highlight.selected_text
    if not selected_text
        or type(selected_text.pos0) ~= "string"
        or selected_text.pos0 == ""
        or type(selected_text.pos1) ~= "string"
        or selected_text.pos1 == "" then
        return nil
    end
    return selected_text.pos0, selected_text.pos1
end

local function close_highlight(highlight)
    if type(highlight.onClose) == "function" then
        highlight:onClose()
    elseif type(highlight.clear) == "function" then
        highlight:clear()
    end
end

function KoReadalong:_show_error(error_message)
    UIManager:show(InfoMessage:new{
        text = _("Read along: ") .. tostring(error_message),
    })
end

function KoReadalong:_read_document_file(path)
    return self.document:getDocumentFileContent(path)
end

function KoReadalong:_register_highlight_action()
    local highlight = self.ui and self.ui.highlight
    if not highlight
        or type(highlight.addToHighlightDialog) ~= "function" then
        return
    end

    highlight:addToHighlightDialog("12_read_from_here", function(this)
        return {
            text = _("Read from here"),
            show_in_highlight_dialog_func = function()
                local pos0, pos1 = selected_xpointers(this)
                if not pos0 then
                    return false
                end
                local can_jump = self.coordinator
                    and self.coordinator.canPlayFromXPointer
                if type(can_jump) ~= "function" then
                    return false
                end
                local ok, accepted = pcall(
                    can_jump,
                    self.coordinator,
                    pos0,
                    pos1
                )
                return ok and accepted == true
            end,
            callback = function()
                if type(this.highlightFromHoldPos) == "function" then
                    this:highlightFromHoldPos()
                end
                local pos0, pos1 = selected_xpointers(this)
                close_highlight(this)
                if not pos0 then
                    self:_show_error(_("no word is selected"))
                    return
                end

                local called, started, error_message = pcall(
                    self.coordinator.playFromXPointer,
                    self.coordinator,
                    pos0,
                    pos1
                )
                if not called then
                    self:_show_error(started)
                elseif not started then
                    local state = type(self.coordinator.getState) == "function"
                        and self.coordinator:getState()
                    if state ~= "error" then
                        self:_show_error(error_message)
                    end
                end
            end,
        }
    end)
end

function KoReadalong:onReaderReady()
    if self.probed then
        return
    end
    self.probed = true

    if not self.document
        or self.document.provider ~= "crengine"
        or type(self.document.getDocumentFileContent) ~= "function" then
        return
    end

    local ok, clips = pcall(function()
        return MediaOverlays.load(function(path)
            return self:_read_document_file(path)
        end)
    end)
    if not ok or type(clips) ~= "table" or #clips == 0 then
        return
    end

    local timeline = Timeline.new(clips)
    if not timeline then
        return
    end

    self.overlay = UnderlineOverlay.new{
        dialog = self.dialog,
        document = self.document,
        ui = self.ui,
        view = self.view,
    }
    self.overlay:register()

    self.coordinator = PlaybackCoordinator.new{
        adapter = MpvAudio.new{ timer = UIManager },
        scheduler = UIManager,
        archive_reader = function(path)
            return self:_read_document_file(path)
        end,
        materializer = Materializer.new{},
        timeline = timeline,
        resolver = FragmentResolver,
        document = self.document,
        overlay = self.overlay,
        clips = clips,
        on_range = function(pos0, pos1)
            follow_range(self, pos0, pos1)
        end,
        on_error = function(error_message)
            self:_show_error(error_message)
        end,
    }
    self:_register_highlight_action()
    self.ui.menu:registerToMainMenu(self)
end

function KoReadalong:addToMainMenu(menu_items)
    menu_items.read_along = {
        text = _("Read along"),
        sorting_hint = "more_tools",
        sub_item_table_func = function()
            return {
                {
                    text_func = function()
                        return self.coordinator:getActionLabel()
                    end,
                    enabled_func = function()
                        return self.coordinator:isActionEnabled()
                    end,
                    callback = function()
                        self.coordinator:toggle()
                    end,
                },
                {
                    text = _("Stop"),
                    enabled_func = function()
                        return self.coordinator:isStopEnabled()
                    end,
                    callback = function()
                        self.coordinator:stop()
                    end,
                },
            }
        end,
    }
end

function KoReadalong:onPageUpdate()
    refresh_overlay(self)
end

function KoReadalong:onPosUpdate()
    refresh_overlay(self)
end

function KoReadalong:onDocumentRerendered()
    refresh_overlay(self)
end

function KoReadalong:onSetDimensions()
    refresh_overlay(self)
end

function KoReadalong:onSetRotationMode()
    refresh_overlay(self)
end

function KoReadalong:onRotationUpdate()
    refresh_overlay(self)
end

function KoReadalong:onZoomUpdate()
    refresh_overlay(self)
end

function KoReadalong:onFontSizeUpdate()
    refresh_overlay(self)
end

function KoReadalong:onDocumentPartiallyRerendered()
    if self.overlay then
        self.overlay:invalidate()
    end
end

function KoReadalong:onCloseDocument()
    if self.coordinator then
        self.coordinator:close()
    elseif self.overlay then
        self.overlay:deactivate()
    end
end

function KoReadalong:onCloseWidget()
    self:onCloseDocument()
end

return KoReadalong
