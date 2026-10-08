local ButtonDialog = require("ui/widget/buttondialog")
local Device = require("device")
local Font = require("ui/font")
local ProgressWidget = require("ui/widget/progresswidget")
local TextBoxWidget = require("ui/widget/textboxwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local _ = require("gettext")

local REFRESH_INTERVAL = 1
local SEEK_INTERVAL = 15

local PlaybackDialog = ButtonDialog:extend{}

local function format_time(seconds)
    if type(seconds) ~= "number" or seconds < 0 then
        return "—"
    end
    seconds = math.floor(seconds)
    local hours = math.floor(seconds / 3600)
    local minutes = math.floor((seconds % 3600) / 60)
    local remaining_seconds = seconds % 60
    if hours > 0 then
        return string.format("%d:%02d:%02d", hours, minutes, remaining_seconds)
    end
    return string.format("%d:%02d", minutes, remaining_seconds)
end

local function state_label(state, follow_state)
    if state == "playing" then
        if follow_state == "browsing" then
            return _("Playing · browsing")
        end
        return _("Playing · following")
    elseif state == "paused" then
        if follow_state == "browsing" then
            return _("Paused · browsing")
        end
        return _("Paused · following")
    elseif state == "loading" then
        return _("Loading…")
    elseif state == "stopping" then
        return _("Stopping…")
    elseif state == "ended" then
        return _("Finished")
    elseif state == "error" then
        return _("Unavailable")
    end
    return _("Ready")
end

local function action_label(state)
    if state == "playing" then
        return _("Pause")
    elseif state == "paused" then
        return _("Resume")
    elseif state == "loading" then
        return _("Loading…")
    elseif state == "stopping" then
        return _("Stopping…")
    elseif state == "error" then
        return _("Unavailable")
    end
    return _("Start here")
end

function PlaybackDialog:_get_follow_state()
    if type(self.get_follow_state) == "function" then
        return self.get_follow_state()
    end
    return "following"
end

function PlaybackDialog:_can_return()
    return type(self.get_return_enabled) == "function"
        and self.get_return_enabled() == true
end

function PlaybackDialog:onFollowStateChanged()
    if self.is_open then
        self:_refresh(true)
    end
end

function PlaybackDialog:onReturnAvailabilityChanged()
    if self.is_open then
        -- The row remains visible and only changes enabled state.  Refresh the
        -- dialog once when a valid range appears or disappears; narration
        -- polling does not call this for unchanged availability.
        self:_refresh(true)
    end
end

function PlaybackDialog:init()
    if self.status_group then
        ButtonDialog.init(self)
        return
    end
    self.scheduler = self.scheduler or UIManager
    self.title = _("Read along")
    self.title_align = "center"
    self.use_info_style = false
    self.anchor = function()
        return { x = math.floor((Device.screen:getWidth() - self.width) / 2),
            y = Device.screen:getHeight() - Device.screen:scaleBySize(8),
            w = self.width, h = 0 }
    end

    local status_width = math.floor(
        math.min(Device.screen:getWidth(), Device.screen:getHeight()) * 0.72
    )
    self.status_text = TextBoxWidget:new{
        text = state_label("paused", "browsing")
            .. "\n" .. string.format(_("Track time: %s / %s"), "00:00:00", "00:00:00")
            .. "\n" .. string.format(_("Book (overlays): %s / %s"), "00:00:00", "00:00:00")
            .. "\n" .. string.format(_("Narrated chapter: %s / %s"), "9999", "9999") .. "\n"
            .. _("Text highlighting unavailable"),
        width = status_width,
        alignment = "center",
        face = Font:getFace("smallinfofont"),
    }
    -- Reserve the hint's measured height: parent groups cache their layout.
    self.status_text.height = self.status_text:getSize().h
    self.status_text:setText(state_label("idle", self:_get_follow_state()) .. "\n— / —")
    self.progress_bar = ProgressWidget:new{
        width = status_width,
        height = Device.screen:scaleBySize(14),
        percentage = 0,
    }
    self.status_group = VerticalGroup:new{
        -- ButtonDialog:reinit preserves added widgets identified by parent.
        parent = self,
        not_focusable = true,
        self.status_text,
        VerticalSpan:new{ width = Device.screen:scaleBySize(8) },
        self.progress_bar,
    }
    self._added_widgets = { self.status_group }

    local start_choices = {
        {
            id = "start_here",
            text = _("Start here"),
            enabled_func = function()
                return type(self.coordinator.canChooseStart) ~= "function"
                    or self.coordinator:canChooseStart()
            end,
            callback = function()
                self:_run(function()
                    return self.coordinator:startHere()
                end, function()
                    if type(self.on_start) == "function" then
                        self.on_start()
                    end
                end)
            end,
        },
    }
    if type(self.coordinator.canResume) == "function" then
        table.insert(start_choices, 1, {
            id = "resume",
            text = _("Resume"),
            enabled_func = function()
                return self.coordinator:canResume()
            end,
            callback = function()
                self:_run(function()
                    return self.coordinator:resumeSaved()
                end, function()
                    if type(self.on_start) == "function" then
                        self.on_start()
                    end
                end)
            end,
        })
    end
    if type(self.coordinator.startOver) == "function" then
        start_choices[#start_choices + 1] = {
            id = "start_over",
            text = _("Start over"),
            enabled_func = function()
                return type(self.coordinator.canChooseStart) ~= "function"
                    or self.coordinator:canChooseStart()
            end,
            callback = function()
                self:_run(function()
                    return self.coordinator:startOver()
                end, function()
                    if type(self.on_start) == "function" then
                        self.on_start()
                    end
                end)
            end,
        }
    end

    self.buttons = {
        {
            {
                id = "seek_back",
                text = _("−15 s"),
                enabled_func = function()
                    return self.coordinator:isSeekEnabled()
                end,
                callback = function()
                    self:_run(function()
                        return self.coordinator:seekBy(-SEEK_INTERVAL)
                    end)
                end,
            },
            {
                id = "toggle",
                text = action_label(self.coordinator:getState()),
                enabled_func = function()
                    return self.coordinator:isActionEnabled()
                end,
                callback = function()
                    local state_before = self.coordinator:getState()
                    self:_run(function()
                        return self.coordinator:toggle()
                    end, function()
                        if state_before == "idle" or state_before == "ended" then
                            if type(self.on_start) == "function" then
                                self.on_start()
                            end
                        end
                    end)
                end,
            },
            {
                id = "seek_forward",
                text = _("+15 s"),
                enabled_func = function()
                    return self.coordinator:isSeekEnabled()
                end,
                callback = function()
                    self:_run(function()
                        return self.coordinator:seekBy(SEEK_INTERVAL)
                    end)
                end,
            },
        },
        {
            {
                id = "stop",
                text = _("Stop"),
                enabled_func = function()
                    return self.coordinator:isStopEnabled()
                end,
                callback = function()
                    self:_run(function()
                        return self.coordinator:stop()
                    end, function()
                        if type(self.on_stop) == "function" then
                            self.on_stop()
                        end
                    end)
                end,
            },
            {
                id = "hide",
                text = _("Hide"),
                callback = function()
                    UIManager:close(self)
                end,
            },
        },
        start_choices,
        {
            {
                id = "follow",
                text = _("Follow: on"),
                enabled_func = function()
                    local state = self.coordinator:getState()
                    return type(self.on_follow) == "function"
                        and (state == "playing" or state == "paused")
                end,
                callback = function()
                    self:_run(function()
                        return self.on_follow()
                    end)
                end,
            },
            {
                id = "return_to_narration",
                text = _("Return to narration"),
                enabled_func = function()
                    return self:_can_return()
                end,
                callback = function()
                    self:_run(function()
                        if type(self.on_return) ~= "function" then
                            return nil, _("There is no current narrated text to return to")
                        end
                        return self.on_return()
                    end)
                end,
            },
        },
    }

    local rows = self.buttons
    self.compact_buttons = { rows[1], { rows[4][1], rows[2][2], {
        id = "more", text = _("More"), callback = function() self:_toggle_more() end,
    } } }
    self.expanded_buttons = { rows[1], self.compact_buttons[2],
        { rows[2][1], rows[4][2] }, rows[3] }
    self.buttons = self.compact_buttons

    self.refresh_action = function()
        self.refresh_scheduled = false
        if not self.is_open then
            return
        end
        self:_refresh(false)
        self:_schedule_refresh()
    end

    ButtonDialog.init(self)
end

function PlaybackDialog:_toggle_more()
    self.expanded = not self.expanded
    self.compact_buttons[2][3].text = self.expanded and _("Less") or _("More")
    self.buttons = self.expanded and self.expanded_buttons or self.compact_buttons
    self.layout = nil
    self:reinit()
    self:_refresh(true)
    -- A collapsed panel must also erase the old, taller footprint.
    UIManager:setDirty("all", "ui")
end

function PlaybackDialog:_run(action, on_success)
    local ok, error_message, error_reported = action()
    if ok and type(on_success) == "function" then
        on_success()
    end
    if not ok and not error_reported
        and self.coordinator:getState() ~= "error"
        and type(self.on_error) == "function" then
        self.on_error(error_message)
    end
    self:_refresh(true)
    self:_schedule_refresh()
end

function PlaybackDialog:_schedule_refresh()
    local state = self.coordinator:getState()
    local needs_refresh = state == "playing" or state == "loading"
        or state == "stopping"
    if needs_refresh and not self.refresh_scheduled and self.is_open then
        self.refresh_scheduled = true
        self.scheduler:scheduleIn(REFRESH_INTERVAL, self.refresh_action)
    elseif not needs_refresh and self.refresh_scheduled then
        self.scheduler:unschedule(self.refresh_action)
        self.refresh_scheduled = false
    end
end

function PlaybackDialog:_refresh(full_refresh)
    local status = self.coordinator:getPlaybackStatus()
    local position = status.position
    local duration = status.duration
    local status_text = string.format(
        "%s\n" .. _("Track time: %s / %s")
            .. "\n" .. _("Book (overlays): %s / %s")
            .. "\n" .. _("Narrated chapter: %s / %s"),
        state_label(status.state, self:_get_follow_state()),
        format_time(position),
        format_time(duration),
        format_time(status.book_position), format_time(status.book_duration),
        status.chapter or "—", status.chapter_count or "—"
    )
    if (status.state == "playing" or status.state == "paused")
        and status.has_text_range == false then
        status_text = status_text .. "\n" .. _("Text highlighting unavailable")
    end
    local layout_changed = false
    if self.status_text.text ~= status_text then
        -- Very long durations/localized labels can exceed the initial reserve.
        -- Measure unbounded text before updating the cached parent layout.
        local measured = TextBoxWidget:new{
            text = status_text, width = self.status_text.width,
            alignment = "center", face = self.status_text.face,
        }
        local height = measured:getSize().h
        measured:free()
        if height > self.status_text.height then
            self.status_text.height = height
            layout_changed = true
        end
    end
    self.status_text:setText(status_text)
    if layout_changed then
        self.status_group:resetLayout()
        self.layout = nil
        self:reinit()
        UIManager:setDirty("all", "ui")
    end

    local percentage = 0
    position, duration = status.book_position, status.book_duration
    if type(position) == "number" and type(duration) == "number"
        and duration > 0 then
        percentage = math.max(0, math.min(1, position / duration))
    end
    self.progress_bar:setPercentage(percentage)

    local toggle_button = self:getButtonById("toggle")
    toggle_button:setText(action_label(status.state), toggle_button.width)
    local follow_button = self:getButtonById("follow")
    follow_button:setText(self:_get_follow_state() == "browsing"
        and _("Follow: off") or _("Follow: on"), follow_button.width)

    if full_refresh or self.last_state ~= status.state then
        UIManager:setDirty(self, "ui", self.movable.dimen)
    elseif self.status_group.dimen then
        UIManager:setDirty(self, "fast", self.status_group.dimen)
    end
    self.last_state = status.state
end

function PlaybackDialog:onShow()
    self.is_open = true
    ButtonDialog.onShow(self)
    self:_refresh(false)
    self:_schedule_refresh()
end

function PlaybackDialog:onCloseWidget()
    self.is_open = false
    if self.refresh_scheduled then
        self.scheduler:unschedule(self.refresh_action)
        self.refresh_scheduled = false
    end
    if type(self.on_close) == "function" then
        self.on_close()
    end
    ButtonDialog.onCloseWidget(self)
end

return PlaybackDialog
