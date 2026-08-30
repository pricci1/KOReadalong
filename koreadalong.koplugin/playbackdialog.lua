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

local function state_label(state)
    if state == "playing" then
        return _("Playing")
    elseif state == "paused" then
        return _("Paused")
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
    return _("Start")
end

function PlaybackDialog:init()
    self.scheduler = self.scheduler or UIManager
    self.title = _("Read along")
    self.title_align = "center"
    self.use_info_style = false

    local status_width = math.floor(
        math.min(Device.screen:getWidth(), Device.screen:getHeight()) * 0.72
    )
    self.status_text = TextBoxWidget:new{
        text = _("Ready") .. "\n— / —",
        width = status_width,
        alignment = "center",
        face = Font:getFace("smallinfofont"),
    }
    self.progress_bar = ProgressWidget:new{
        width = status_width,
        height = Device.screen:scaleBySize(14),
        percentage = 0,
    }
    self.status_group = VerticalGroup:new{
        not_focusable = true,
        self.status_text,
        VerticalSpan:new{ width = Device.screen:scaleBySize(8) },
        self.progress_bar,
    }
    self._added_widgets = { self.status_group }

    self.buttons = {
        {
            {
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
                    self:_run(function()
                        return self.coordinator:toggle()
                    end)
                end,
            },
            {
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
                text = _("Stop"),
                enabled_func = function()
                    return self.coordinator:isStopEnabled()
                end,
                callback = function()
                    self:_run(function()
                        return self.coordinator:stop()
                    end)
                end,
            },
            {
                text = _("Hide"),
                callback = function()
                    UIManager:close(self)
                end,
            },
        },
    }

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

function PlaybackDialog:_run(action)
    local ok, error_message = action()
    if not ok and self.coordinator:getState() ~= "error"
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
    self.status_text:setText(string.format(
        "%s\n%s / %s",
        state_label(status.state),
        format_time(position),
        format_time(duration)
    ))

    local percentage = 0
    if type(position) == "number" and type(duration) == "number"
        and duration > 0 then
        percentage = math.max(0, math.min(1, position / duration))
    end
    self.progress_bar:setPercentage(percentage)

    local toggle_button = self:getButtonById("toggle")
    toggle_button:setText(action_label(status.state), toggle_button.width)

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
