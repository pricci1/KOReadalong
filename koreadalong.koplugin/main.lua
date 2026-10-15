local WidgetContainer = require("ui/widget/container/widgetcontainer")
local Device = require("device")
local Dispatcher = require("dispatcher")
local FragmentResolver = require("fragmentresolver")
local Materializer = require("materializer")
local MediaOverlays = require("mediaoverlays")
local PlaybackCoordinator = require("playbackcoordinator")
local PlaybackDialog = require("playbackdialog")
local NarrationState = require("narrationstate")
local Timeline = require("timeline")
local UnderlineOverlay = require("underlineoverlay")
local Event = require("ui/event")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local _ = require("gettext")

local KINAMP_BUSY_ERROR = "KinAMP is busy"
local FOLLOWING = "following"
local BROWSING = "browsing"
local EXPECTED_NAVIGATION_SECONDS = 1
local EXPECTED_NAVIGATION_EVENTS = 8
local INPUT_NAVIGATION_SECONDS = 0.75
local RENDER_SUPPRESSION_SECONDS = 0.75

local KINAMP_BUSY_HELP = _([[KinAMP is busy.

Another client is playing or paused. KOReadalong has left it untouched. Stop that playback when you are ready, then press Start again.]])

local KINAMP_HELP = _([[KinAMP setup and help

Install and enable the official KinAMP plugin and player separately, then restart KOReader.

Read along starts KinAMP automatically. Closing a book stops narration; reopening never starts audio.

Bluetooth setup opens KinAMP’s existing settings. KOReadalong leaves the radio and other clients alone.

Opus-in-MP4: experimental PW6-tested source branch, not a binary release:
https://github.com/pricci1/KinAMP-fork/tree/prototype/opus-mp4

Official KinAMP documentation:
https://github.com/kbarni/KinAMP/blob/master/README.md]])

local KOReadalong = WidgetContainer:extend({
    name = "koreadalong",
    is_doc_only = true,
})

function KOReadalong:onDispatcherRegisterActions()
    Dispatcher:registerAction("koreadalong_show_controls", {
        category = "none",
        event = "ShowReadAlongControls",
        title = _("KOReadalong: show playback controls"),
        reader = true,
    })
    Dispatcher:registerAction("koreadalong_return_to_narration", {
        category = "none",
        event = "ReturnToNarration",
        title = _("KOReadalong: return to narration"),
        reader = true,
    })
end

function KOReadalong:init()
    self.follow_state = FOLLOWING
    self.input_sequence = 0
    self.input_pending = false
    self.navigation_serial = 0
    self.render_serial = 0
    self:onDispatcherRegisterActions()
end

local function refresh_overlay(self)
    if self.overlay then
        self.overlay:refresh()
    end
end

local function valid_xpointer(pointer)
    return type(pointer) == "string" and pointer ~= ""
end

local function active_narration(self)
    if not self.coordinator
        or type(self.coordinator.getState) ~= "function" then
        return false
    end
    local state = self.coordinator:getState()
    return state == "playing" or state == "paused"
end

local function current_xpointer(self)
    if not self.document or type(self.document.getXPointer) ~= "function" then
        return nil
    end
    local ok, pointer = pcall(self.document.getXPointer, self.document)
    if ok and valid_xpointer(pointer) then
        return pointer
    end
    return nil
end

local function pointer_visible(self, pointer)
    if not valid_xpointer(pointer)
        or not self.document
        or type(self.document.isXPointerInCurrentPage) ~= "function" then
        return false
    end
    local ok, visible = pcall(
        self.document.isXPointerInCurrentPage,
        self.document,
        pointer
    )
    return ok and visible == true
end

function KOReadalong:_cancel_navigation_guard()
    if self.expected_navigation_action and type(UIManager.unschedule) == "function" then
        UIManager:unschedule(self.expected_navigation_action)
    end
    self.expected_navigation = nil
    self.expected_navigation_action = nil
end

function KOReadalong:_cancel_navigation_candidate()
    if self.navigation_candidate_action and type(UIManager.unschedule) == "function" then
        UIManager:unschedule(self.navigation_candidate_action)
    end
    self.navigation_candidate = nil
    self.navigation_candidate_action = nil
end

function KOReadalong:_clear_render_suppression()
    if self.render_action and type(UIManager.unschedule) == "function" then
        UIManager:unschedule(self.render_action)
    end
    self.render_action = nil
    self.rendering = nil
end

function KOReadalong:_set_follow_state(state)
    if self.follow_state == state then
        return
    end
    self.follow_state = state
    if self.playback_dialog
        and type(self.playback_dialog.onFollowStateChanged) == "function" then
        self.playback_dialog:onFollowStateChanged()
    end
end

function KOReadalong:_notify_return_availability_changed(was_available)
    if was_available == self:canReturnToNarration() then
        return
    end
    if self.playback_dialog
        and type(self.playback_dialog.onReturnAvailabilityChanged) == "function" then
        self.playback_dialog:onReturnAvailabilityChanged()
    end
end

function KOReadalong:_reset_navigation()
    self:_cancel_navigation_guard()
    self:_cancel_navigation_candidate()
    self:_clear_render_suppression()
    if self.input_expiry_action and type(UIManager.unschedule) == "function" then
        UIManager:unschedule(self.input_expiry_action)
    end
    self.input_expiry_action = nil
    self.latest_range = nil
    self.input_pending = false
    self.last_xpointer = current_xpointer(self)
    self:_set_follow_state(FOLLOWING)
end

function KOReadalong:_begin_following()
    self:_cancel_navigation_guard()
    self:_cancel_navigation_candidate()
    self:_clear_render_suppression()
    self.input_pending = false
    if self.input_expiry_action and type(UIManager.unschedule) == "function" then
        UIManager:unschedule(self.input_expiry_action)
    end
    self.input_expiry_action = nil
    self.latest_range = nil
    self:_set_follow_state(FOLLOWING)
end

function KOReadalong:_set_browsing()
    self:_cancel_navigation_candidate()
    self:_cancel_navigation_guard()
    self.input_pending = false
    if self.input_expiry_action and type(UIManager.unschedule) == "function" then
        UIManager:unschedule(self.input_expiry_action)
    end
    self.input_expiry_action = nil
    self:_set_follow_state(BROWSING)
end

function KOReadalong:_schedule_input_expiry(sequence)
    if self.input_expiry_action and type(UIManager.unschedule) == "function" then
        UIManager:unschedule(self.input_expiry_action)
    end
    self.input_expiry_action = function()
        if self.input_sequence == sequence then
            self.input_pending = false
            self.input_expiry_action = nil
        end
    end
    if type(UIManager.scheduleIn) == "function" then
        UIManager:scheduleIn(INPUT_NAVIGATION_SECONDS, self.input_expiry_action)
    end
end

function KOReadalong:_onInputFrame()
    self.input_sequence = self.input_sequence + 1
    self.input_pending = true
    self:_schedule_input_expiry(self.input_sequence)
end

function KOReadalong:_register_input_hook()
    local event_hook = UIManager.event_hook
    if not event_hook or type(event_hook.register) ~= "function" then
        return
    end
    self.input_hook = function()
        self:_onInputFrame()
    end
    event_hook:register("InputEvent", self.input_hook)
end

function KOReadalong:_unregister_input_hook()
    local event_hook = UIManager.event_hook
    if self.input_hook and event_hook and type(event_hook.unregister) == "function" then
        event_hook:unregister("InputEvent", self.input_hook)
    end
    self.input_hook = nil
end

function KOReadalong:_expect_navigation(pointer)
    self:_cancel_navigation_guard()
    self.navigation_serial = self.navigation_serial + 1
    local guard = {
        pointer = pointer,
        input_sequence = self.input_sequence,
        remaining = EXPECTED_NAVIGATION_EVENTS,
        serial = self.navigation_serial,
    }
    if self.document then
        if type(self.document.getPageFromXPointer) == "function" then
            local ok, page = pcall(
                self.document.getPageFromXPointer,
                self.document,
                pointer
            )
            if ok and type(page) == "number" then
                guard.page = page
            end
        end
        if type(self.document.getPosFromXPointer) == "function" then
            local ok, position = pcall(
                self.document.getPosFromXPointer,
                self.document,
                pointer
            )
            if ok and type(position) == "number" then
                guard.position = position
            end
        end
    end
    self.expected_navigation = guard
    self.expected_navigation_action = function()
        if self.expected_navigation == guard then
            self.expected_navigation = nil
            self.expected_navigation_action = nil
        end
    end
    if type(UIManager.scheduleIn) == "function" then
        UIManager:scheduleIn(
            EXPECTED_NAVIGATION_SECONDS,
            self.expected_navigation_action
        )
    end
end

local function close_enough(left, right)
    return type(left) == "number" and type(right) == "number"
        and math.abs(left - right) <= 1
end

function KOReadalong:_expected_navigation_matches(kind, value)
    local guard = self.expected_navigation
    if not guard then
        return false
    end
    if guard.input_sequence ~= self.input_sequence then
        self:_cancel_navigation_guard()
        return false
    end
    local matches = false
    if kind == "page" then
        matches = guard.page ~= nil and value == guard.page
    elseif kind == "position" then
        matches = close_enough(value, guard.position)
    end
    matches = matches or pointer_visible(self, guard.pointer)
    if not matches then
        self:_cancel_navigation_guard()
        return false
    end
    guard.remaining = guard.remaining - 1
    if guard.remaining <= 0 then
        self:_cancel_navigation_guard()
    end
    self.input_pending = false
    return true
end

function KOReadalong:_schedule_browse_candidate(logical_changed, pointer)
    if self.follow_state ~= FOLLOWING or not active_narration(self) then
        return
    end
    pointer = pointer or current_xpointer(self)
    local input_navigation = self.input_pending
    if not logical_changed and not input_navigation then
        return
    end
    self.navigation_serial = self.navigation_serial + 1
    local serial = self.navigation_serial
    self.navigation_candidate = {
        pointer = pointer,
        logical_changed = logical_changed,
        input_navigation = input_navigation,
        serial = serial,
    }
    self.navigation_candidate_action = function()
        local candidate = self.navigation_candidate
        if not candidate or candidate.serial ~= serial then
            return
        end
        self.navigation_candidate = nil
        self.navigation_candidate_action = nil
        if self.follow_state ~= FOLLOWING or not active_narration(self) then
            return
        end
        if self.rendering and candidate.pointer == self.rendering.pointer then
            return
        end
        if candidate.logical_changed or candidate.input_navigation then
            self:_set_browsing()
        end
    end
    if type(UIManager.nextTick) == "function" then
        UIManager:nextTick(self.navigation_candidate_action)
    else
        self.navigation_candidate_action()
    end
end

function KOReadalong:_observe_position(kind, value)
    local expected = self:_expected_navigation_matches(kind, value)
    local pointer = current_xpointer(self)
    local logical_changed = pointer ~= self.last_xpointer
    self.last_xpointer = pointer
    if not expected then
        self:_schedule_browse_candidate(logical_changed, pointer)
    end
end

function KOReadalong:_mark_rendering()
    self:_cancel_navigation_candidate()
    self.render_serial = self.render_serial + 1
    local serial = self.render_serial
    self.rendering = {
        pointer = current_xpointer(self),
        serial = serial,
    }
    if self.render_action and type(UIManager.unschedule) == "function" then
        UIManager:unschedule(self.render_action)
    end
    self.render_action = function()
        if self.rendering and self.rendering.serial == serial then
            self.rendering = nil
            self.render_action = nil
        end
    end
    if type(UIManager.scheduleIn) == "function" then
        UIManager:scheduleIn(RENDER_SUPPRESSION_SECONDS, self.render_action)
    end
end

function KOReadalong:_follow_range(pos0, pos1)
    if self.follow_state ~= FOLLOWING or not active_narration(self) then
        return
    end
    if pointer_visible(self, pos0) or pointer_visible(self, pos1) then
        return
    end
    self:_expect_navigation(pos0)
    self.ui:handleEvent(Event:new("GotoXPointer", pos0))
    refresh_overlay(self)
end

function KOReadalong:_latest_range()
    if type(self.latest_range) == "table"
        and valid_xpointer(self.latest_range.pos0)
        and valid_xpointer(self.latest_range.pos1) then
        return {
            pos0 = self.latest_range.pos0,
            pos1 = self.latest_range.pos1,
        }
    end
    if self.coordinator and type(self.coordinator.getCurrentRange) == "function" then
        local ok, range = pcall(self.coordinator.getCurrentRange, self.coordinator)
        if ok and type(range) == "table"
            and valid_xpointer(range.pos0)
            and valid_xpointer(range.pos1) then
            return {
                pos0 = range.pos0,
                pos1 = range.pos1,
            }
        end
    end
    return nil
end

function KOReadalong:canReturnToNarration()
    return self.follow_state == BROWSING
        and active_narration(self)
        and self:_latest_range() ~= nil
end

function KOReadalong:toggleFollowing()
    if not active_narration(self) then
        return nil, _("Narration is not active")
    end
    if self.follow_state == FOLLOWING then
        self:_set_browsing()
        return true
    end
    if self:_latest_range() then
        return self:returnToNarration()
    end
    self:_cancel_navigation_guard()
    self:_cancel_navigation_candidate()
    self:_set_follow_state(FOLLOWING)
    return true
end

function KOReadalong:returnToNarration()
    if not active_narration(self) then
        return nil, _("Narration is not active")
    end
    local range = self:_latest_range()
    if not range then
        return nil, _("There is no current narrated text to return to")
    end
    self:_expect_navigation(range.pos0)
    self.ui:handleEvent(Event:new("GotoXPointer", range.pos0))
    refresh_overlay(self)
    self:_cancel_navigation_candidate()
    self:_set_follow_state(FOLLOWING)
    return true
end

function KOReadalong:onReturnToNarration()
    local ok, error_message = self:returnToNarration()
    if not ok and error_message then
        self:_show_error(error_message)
    end
    return ok
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

local function new_audio_adapter()
    if Device:isKindle() then
        return require("kindleaudio").new{ timer = UIManager }
    end
    return require("mpvaudio").new{ timer = UIManager }
end

function KOReadalong:_show_error(error_message)
    local message = tostring(error_message)
    if Device:isKindle() then
        if message == KINAMP_BUSY_ERROR then
            UIManager:show(InfoMessage:new{
                text = KINAMP_BUSY_HELP,
            })
            return
        end
        if message == "Bluetooth audio is not connected" then
            self:_show_kinamp_help(_([[No Bluetooth audio device is connected.

Open Bluetooth setup to connect your audio device, then press Start again. Pair new devices in Kindle settings.]]))
            return
        end
    end
    UIManager:show(InfoMessage:new{
        text = _("Read along: ") .. message,
    })
end

function KOReadalong:_show_kinamp_help(message)
    UIManager:show(require("ui/widget/confirmbox"):new{
        text = message or KINAMP_HELP,
        ok_text = _("Bluetooth setup"),
        ok_callback = function()
            require("kinampservice").shared.get_bluetooth()
            local ok, settings = pcall(require, "kinamp_btdevices")
            if ok and type(settings.open) == "function" then
                settings.open()
            else
                self:_show_error(_("KinAMP Bluetooth settings are unavailable. Install and enable the official KinAMP plugin, then restart KOReader."))
            end
        end,
    })
end

function KOReadalong:_read_document_file(path)
    return self.document:getDocumentFileContent(path)
end

function KOReadalong:_show_playback_controls()
    if self.playback_dialog then
        return
    end
    self.playback_dialog = PlaybackDialog:new{
        coordinator = self.coordinator,
        scheduler = UIManager,
        get_follow_state = function()
            return self.follow_state
        end,
        get_return_enabled = function()
            return self:canReturnToNarration()
        end,
        on_follow = function()
            return self:toggleFollowing()
        end,
        on_return = function()
            return self:returnToNarration()
        end,
        on_start = function()
            self:_begin_following()
        end,
        on_stop = function()
            self:_reset_navigation()
        end,
        on_error = function(error_message)
            self:_show_error(error_message)
        end,
        on_close = function()
            self.playback_dialog = nil
        end,
    }
    UIManager:show(self.playback_dialog)
end

function KOReadalong:onShowReadAlongControls()
    if not self.coordinator then
        return false
    end
    self:_show_playback_controls()
    return true
end

function KOReadalong:_register_highlight_action()
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

                -- A same-resource jump reports its new range synchronously;
                -- enter Following before asking the coordinator to seek so
                -- that explicit Read from here also navigates to the target.
                self:_begin_following()

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

function KOReadalong:onReaderReady()
    if self.probed then
        return
    end
    self.probed = true

    if not self.document
        or self.document.provider ~= "crengine"
        or type(self.document.getDocumentFileContent) ~= "function" then
        return
    end

    local ok, clips, load_error, skipped_clips = pcall(function()
        return MediaOverlays.load(function(path)
            return self:_read_document_file(path)
        end)
    end)
    if not ok or load_error or type(clips) ~= "table" then
        return
    end

    local timeline
    if #clips > 0 then
        timeline = Timeline.new(clips)
        if not timeline then
            return
        end
    end
    if skipped_clips and skipped_clips > 0 then
        local message = string.format(_([[KOReadalong skipped narration clips with an end time at or before their start time.
Skipped clips: %d.]]), skipped_clips)
        if timeline then
            message = message .. "\n\n" .. _("The remaining narration is available through Read along. Some text will not be synchronized.")
        else
            message = message .. "\n\n" .. _("No valid narration clips remain. Read along is unavailable for this book.")
        end
        UIManager:show(InfoMessage:new{ text = message })
    end
    if not timeline then
        return
    end

    local state_store = NarrationState.new{
        settings = self.ui.doc_settings,
        clips = clips,
    }

    self.overlay = UnderlineOverlay.new{
        dialog = self.dialog,
        document = self.document,
        ui = self.ui,
        view = self.view,
    }
    self.overlay:register()

    self.coordinator = PlaybackCoordinator.new{
        adapter = new_audio_adapter(),
        scheduler = UIManager,
        speed = self.ui.doc_settings:readSetting("koreadalong_playback_speed"),
        on_speed = function(speed)
            self.ui.doc_settings:saveSetting("koreadalong_playback_speed", speed)
            self.ui.doc_settings:flush()
        end,
        archive_reader = function(path)
            return self:_read_document_file(path)
        end,
        materializer = Materializer.new{},
        timeline = timeline,
        resolver = FragmentResolver,
        document = self.document,
        state_store = state_store,
        get_current_xpointer = function()
            return self.document:getXPointer()
        end,
        overlay = self.overlay,
        clips = clips,
        on_range = function(pos0, pos1)
            if valid_xpointer(pos0) and valid_xpointer(pos1) then
                local was_return_available = self:canReturnToNarration()
                self.latest_range = {
                    pos0 = pos0,
                    pos1 = pos1,
                }
                self:_follow_range(pos0, pos1)
                self:_notify_return_availability_changed(was_return_available)
            end
        end,
        on_range_cleared = function(reason)
            local was_return_available = self:canReturnToNarration()
            self.latest_range = nil
            if reason == "stop" or reason == "ended"
                or reason == "close" or reason == "error" then
                self:_reset_navigation()
            else
                self:_notify_return_availability_changed(was_return_available)
            end
        end,
        on_error = function(error_message)
            self:_reset_navigation()
            self:_show_error(error_message)
        end,
    }
    self.last_xpointer = current_xpointer(self)
    self:_register_input_hook()
    self:_register_highlight_action()
    self.ui.menu:registerToMainMenu(self)
end

function KOReadalong:addToMainMenu(menu_items)
    menu_items.read_along = {
        text = _("Read along"),
        sorting_hint = "more_tools",
        callback = function()
            self:_show_playback_controls()
        end,
    }
    if Device:isKindle() then
        menu_items.kinamp_help = {
            text = _("KinAMP setup and help"),
            sorting_hint = "more_tools",
            callback = function()
                self:_show_kinamp_help()
            end,
        }
    end
end

function KOReadalong:onPageUpdate(new_page)
    self:_observe_position("page", new_page)
    refresh_overlay(self)
end

function KOReadalong:onPosUpdate(new_pos, new_page)
    self:_observe_position("position", new_pos)
    refresh_overlay(self)
end

function KOReadalong:onDocumentRerendered()
    self:_mark_rendering()
    refresh_overlay(self)
end

function KOReadalong:onSetDimensions()
    self:_mark_rendering()
    refresh_overlay(self)
end

function KOReadalong:onSetRotationMode()
    self:_mark_rendering()
    refresh_overlay(self)
end

function KOReadalong:onRotationUpdate()
    self:_mark_rendering()
    refresh_overlay(self)
end

function KOReadalong:onZoomUpdate()
    self:_mark_rendering()
    refresh_overlay(self)
end

function KOReadalong:onFontSizeUpdate()
    self:_mark_rendering()
    refresh_overlay(self)
end

function KOReadalong:onDocumentPartiallyRerendered()
    self:_mark_rendering()
    if self.overlay then
        self.overlay:invalidate()
    end
end

function KOReadalong:onCloseDocument()
    self:_unregister_input_hook()
    self:_reset_navigation()
    if self.playback_dialog then
        UIManager:close(self.playback_dialog)
        self.playback_dialog = nil
    end
    if self.coordinator then
        self.coordinator:close()
    elseif self.overlay then
        self.overlay:deactivate()
    end
end

function KOReadalong:onCloseWidget()
    self:onCloseDocument()
end

function KOReadalong:onExit()
    -- KinAMP can quit paused audio during this broadcast, before the reader's
    -- deferred CloseDocument event. Cancel our active callbacks now.
    self:onCloseDocument()
end

-- Power-off/reboot announces Close instead of Exit.
KOReadalong.onClose = KOReadalong.onExit

return KOReadalong
