local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local Device = require("device")
local Font = require("ui/font")
local Menu = require("ui/widget/menu")
local TextBoxWidget = require("ui/widget/textboxwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local util = require("util")
local _ = require("gettext")

local RemoteDialog = ButtonDialog:extend{}

local function preview(value, limit)
    -- Packet fields are bounded, but still too long for a small-screen prompt.
    local chars = util.splitToChars(util.fixUtf8(value, "�"))
    if #chars > limit then return table.concat(chars, "", 1, limit) .. "…" end
    return table.concat(chars)
end

function RemoteDialog:_confirm(text, label, action)
    self.child = ConfirmBox:new{
        text = text, ok_text = label,
        cancel_callback = function() self.child = nil end,
        ok_callback = function()
            self.child = nil
            if self.is_open then action() end
        end,
    }
    UIManager:show(self.child)
end

function RemoteDialog:_run(action)
    local ok, err = action()
    if not ok and self.on_error then self.on_error(err) end
    if self.is_open then self:_refresh() end
end

function RemoteDialog:_listen()
    self:_confirm(_([[Listen for Storyteller v3 on this Wi-Fi network?

Use a trusted LAN and the same aligned EPUB on both devices. Discovery is not authentication: other devices can send positions.

Enable Live Reading Sync in the phone app. After listening, play or seek on your phone, then choose its phone/book here. No audio plays on this reader.]]), _("Listen"), function()
        self.follower:stop()
        self:_run(function() return self.follower:start() end)
    end)
end

function RemoteDialog:_choose()
    local items = {}
    local chooser
    for __, peer in ipairs(self.follower:getPeers()) do
        items[#items + 1] = {
            text = peer.host .. " · " .. preview(peer.book, 64),
            mandatory = peer.matches and _("Text matches") or _("No match"),
            callback = function()
                UIManager:close(chooser)
                self.child = nil
                local details = string.format(_([[Follow this phone/book?

Phone: %s
Sender: %s
Book: %s
Text: %s#%s
Last update: %d s ago

Matching text is not proof of book identity. Confirm this is your phone and the same aligned EPUB.]]),
                    peer.host, preview(peer.sender, 40), preview(peer.book, 64),
                    preview(peer.text_path, 80), preview(peer.text_fragment, 64), math.floor(peer.age))
                self:_confirm(details, _("Follow"), function()
                    if self.on_start then self.on_start() end
                    self:_run(function() return self.follower:selectPeer(peer.key) end)
                end)
            end,
        }
    end
    chooser = Menu:new{
        title = _("Choose phone / book"), item_table = items,
        width = math.floor(Device.screen:getWidth() * 0.9),
        height = math.floor(Device.screen:getHeight() * 0.7),
        items_per_page = 6, items_max_lines = 2,
        close_callback = function()
            if self.child == chooser then self.child = nil end
        end,
    }
    self.child = chooser
    UIManager:show(chooser)
end

function RemoteDialog:_correct(step)
    local value = math.max(-5, math.min(2, self.follower:getStatus().correction + step))
    local apply = function()
        self:_run(function() return self.follower:setCorrection(value) end)
    end
    if value > 0 and not self.early_acknowledged then
        self:_confirm(_([[Earlier marks are estimates, not exact audio synchronization.

Storyteller sends sentence positions, not a continuous clock or pause notifications. After steady updates, KOReadalong may predict one next sentence. If updates stop, it returns to the last confirmed sentence.

Use Later for Bluetooth delay. These controls never change phone speed.]]), _("Use estimates"), function()
            self.early_acknowledged = true
            apply()
        end)
    else
        apply()
    end
end

function RemoteDialog:init()
    if self.status_group then
        ButtonDialog.init(self)
        return
    end
    self.scheduler = self.scheduler or UIManager
    self.title = _("Storyteller · remote audio")
    self.title_align = "center"
    self.use_info_style = false
    self.anchor = function()
        return { x = math.floor((Device.screen:getWidth() - self.width) / 2),
            y = Device.screen:getHeight() - Device.screen:scaleBySize(32), w = self.width, h = 0 }
    end
    self.status_text = TextBoxWidget:new{
        text = "\n\n\n\n\n", alignment = "center",
        width = math.floor(math.min(Device.screen:getWidth(), Device.screen:getHeight()) * 0.76),
        face = Font:getFace("smallinfofont"),
    }
    self.status_text.height = self.status_text:getSize().h
    self.status_group = VerticalGroup:new{ parent = self, not_focusable = true, self.status_text }
    self._added_widgets = { self.status_group }
    self.buttons = {
        {
            { id = "listen", text = _("Listen"), callback = function() self:_listen() end },
            {
                id = "choose", text = _("Choose phone / book"),
                enabled_func = function() return #self.follower:getPeers() > 0 end,
                callback = function() self:_choose() end,
            },
        },
        {
            {
                id = "later", text = _("Later 0.25 s"),
                enabled_func = function() return self.follower:getStatus().correction > -5 end,
                callback = function() self:_correct(-0.25) end,
            },
            { id = "reset", text = _("Reset timing"), callback = function()
                self:_run(function() return self.follower:setCorrection(0) end)
            end },
            {
                id = "earlier", text = _("Earlier 0.25 s"),
                enabled_func = function() return self.follower:getStatus().correction < 2 end,
                callback = function() self:_correct(0.25) end,
            },
        },
        {
            {
                id = "follow", text = _("Follow: on"),
                enabled_func = function() return self.follower:isActive() end,
                callback = function() self:_run(self.on_follow) end,
            },
            {
                id = "return_to_narration", text = _("Return to narration"),
                enabled_func = function() return self.get_return_enabled() end,
                callback = function() self:_run(self.on_return) end,
            },
        },
        {
            {
                id = "stop", text = _("Stop following"),
                enabled_func = function() return self.follower:getStatus().host ~= nil end,
                callback = function()
                    self:_run(function() return self.follower:stop() end)
                    if self.on_stop then self.on_stop() end
                end,
            },
            { id = "hide", text = _("Hide"), callback = function() UIManager:close(self) end },
        },
    }
    self.refresh_action = function()
        if self.is_open then
            self:_refresh()
            self.scheduler:scheduleIn(1, self.refresh_action)
        end
    end
    ButtonDialog.init(self)
end

function RemoteDialog:_refresh()
    local status = self.follower:getStatus()
    local labels = {
        idle = _("Stopped · phone audio is independent"),
        listening = _("Listening · choose phone / book"),
        following = _("Following phone positions"),
        waiting = _("Waiting · paused, long passage or network?"),
        mismatch = _("Book/text mismatch · marks cleared"),
        error = _("Network error · retry Listen"),
        closed = _("Closed"),
    }
    local correction = status.correction == 0 and _("Timing: as received")
        or status.correction < 0 and string.format(_("Timing: %.2f s later"), -status.correction)
        or string.format(_("Timing: %.2f s earlier (estimated)"), status.correction)
    local text = (labels[status.state] or status.state) .. "\n"
        .. (status.peer_host and string.format(_("Phone: %s · %g×"), status.peer_host, status.rate or 1)
            or _("Play or seek on the phone after Listen.")) .. "\n"
        .. (status.age and string.format(_("Last update: %d s ago · %s"), math.floor(status.age),
            status.estimated and _("predicted") or _("confirmed"))
            or _("Same EPUB · trusted Wi-Fi · no cloud sync")) .. "\n"
        .. correction .. "\n"
        .. (status.host and string.format(_("Receiver: %s:%d"), status.host, status.port)
            or _("Reader is not listening.")) .. "\n"
        .. (status.age and not status.has_text_range and _("Text highlighting unavailable")
            or _("Pause, seek and speed: use your phone."))
    local follow = self.get_follow_state() == "browsing" and _("Follow: off") or _("Follow: on")
    local signature = text .. follow .. tostring(#self.follower:getPeers())
        .. tostring(self.get_return_enabled())
    if signature == self.last_signature then return end
    self.last_signature = signature
    local measured = TextBoxWidget:new{
        text = text, width = self.status_text.width, face = self.status_text.face, alignment = "center",
    }
    local height = measured:getSize().h
    measured:free()
    local resized = height > self.status_text.height
    if resized then self.status_text.height = height end
    self.status_text:setText(text)
    if resized then
        self.status_group:resetLayout()
        self.layout = nil
        self:reinit()
        UIManager:setDirty("all", "ui")
    end
    local button = self:getButtonById("follow")
    button:setText(follow, button.width)
    button = self:getButtonById("listen")
    button:setText(status.host and _("Restart listening") or _("Listen"), button.width)
    UIManager:setDirty(self, "ui", self.movable.dimen)
end

function RemoteDialog:onFollowStateChanged()
    if self.is_open then self:_refresh() end
end

RemoteDialog.onReturnAvailabilityChanged = RemoteDialog.onFollowStateChanged

function RemoteDialog:onShow()
    self.is_open = true
    ButtonDialog.onShow(self)
    self:_refresh()
    self.scheduler:scheduleIn(1, self.refresh_action)
end

function RemoteDialog:onCloseWidget()
    self.is_open = false
    self.scheduler:unschedule(self.refresh_action)
    if self.child then UIManager:close(self.child); self.child = nil end
    if self.on_close then self.on_close() end
    ButtonDialog.onCloseWidget(self)
end

return RemoteDialog
