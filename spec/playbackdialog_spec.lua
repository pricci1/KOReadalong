package.path = "./koreadalong.koplugin/?.lua;" .. package.path

describe("playback dialog", function()
    local PlaybackDialog
    local coordinator
    local scheduler
    local ui_manager

    before_each(function()
        package.loaded.playbackdialog = nil

        local button_dialog = {}
        function button_dialog:extend(prototype)
            setmetatable(prototype, self)
            self.__index = self
            return prototype
        end
        function button_dialog:new(options)
            options = options or {}
            setmetatable(options, self)
            self.__index = self
            options:init()
            return options
        end
        function button_dialog:init()
            self.movable = { dimen = { x = 10, y = 10, w = 500, h = 300 } }
            self.button_by_id = {}
            for _, row in ipairs(self.buttons) do
                for _, entry in ipairs(row) do
                    if entry.id then
                        local button = {
                            text = entry.text,
                            width = 100,
                            enabled_func = entry.enabled_func,
                        }
                        function button:setText(text)
                            self.text = text
                        end
                        self.button_by_id[entry.id] = button
                    end
                end
            end
        end
        function button_dialog:getButtonById(id)
            return self.button_by_id[id]
        end
        function button_dialog:onShow()
            self.base_show_count = (self.base_show_count or 0) + 1
        end
        function button_dialog:onCloseWidget()
            self.base_close_count = (self.base_close_count or 0) + 1
        end

        local function simple_widget()
            return {
                new = function(_, options)
                    return options
                end,
            }
        end
        local progress_widget = simple_widget()
        function progress_widget:new(options)
            function options:setPercentage(percentage)
                self.percentage = percentage
            end
            return options
        end
        local text_box_widget = simple_widget()
        function text_box_widget:new(options)
            function options:setText(text)
                self.text = text
            end
            function options:getSize()
                local _, lines = self.text:gsub("\n", "")
                return { w = self.width, h = self.height or (lines + 1) * 20 }
            end
            return options
        end
        local vertical_group = simple_widget()
        function vertical_group:new(options)
            options.dimen = { x = 20, y = 20, w = 400, h = 80 }
            return options
        end

        scheduler = {
            tasks = {},
            schedules = 0,
            unschedules = 0,
        }
        function scheduler:scheduleIn(delay, action)
            self.tasks[action] = delay
            self.schedules = self.schedules + 1
        end
        function scheduler:unschedule(action)
            self.tasks[action] = nil
            self.unschedules = self.unschedules + 1
        end
        function scheduler:fire(action)
            self.tasks[action] = nil
            action()
        end

        ui_manager = {
            dirty = {},
            closed = {},
        }
        function ui_manager:setDirty(widget, refresh_type, dimen)
            self.dirty[#self.dirty + 1] = {
                widget = widget,
                refresh_type = refresh_type,
                dimen = dimen,
            }
        end
        function ui_manager:close(widget)
            self.closed[#self.closed + 1] = widget
            widget:onCloseWidget()
        end

        coordinator = {
            state = "idle",
            position = nil,
            duration = nil,
            seeks = {},
            toggle_count = 0,
            stop_count = 0,
            start_here_count = 0,
            resume_saved_count = 0,
            start_over_count = 0,
            has_resume = false,
        }
        function coordinator:getState()
            return self.state
        end
        function coordinator:getPlaybackStatus()
            return {
                state = self.state,
                position = self.position,
                duration = self.duration,
                can_seek = self:isSeekEnabled(),
                has_text_range = self.has_text_range,
            }
        end
        function coordinator:isSeekEnabled()
            return self.state == "playing" or self.state == "paused"
        end
        function coordinator:isActionEnabled()
            return self.state ~= "loading" and self.state ~= "stopping"
        end
        function coordinator:canResume()
            return self.has_resume and self.state == "idle"
        end
        function coordinator:canChooseStart()
            return self.state == "idle"
        end
        function coordinator:isStopEnabled()
            return self.state == "playing" or self.state == "paused"
        end
        function coordinator:toggle()
            self.toggle_count = self.toggle_count + 1
            if self.state == "playing" then
                self.state = "paused"
            elseif self.state == "paused" then
                self.state = "playing"
            else
                self.state = "loading"
            end
            return true
        end
        function coordinator:seekBy(offset)
            self.seeks[#self.seeks + 1] = offset
            self.position = math.max(0, math.min(
                self.duration,
                self.position + offset
            ))
            return true
        end
        function coordinator:stop()
            self.stop_count = self.stop_count + 1
            self.state = "stopping"
            return true
        end
        function coordinator:startHere()
            self.start_here_count = self.start_here_count + 1
            self.state = "loading"
            return true
        end
        function coordinator:resumeSaved()
            self.resume_saved_count = self.resume_saved_count + 1
            self.state = "loading"
            return true
        end
        function coordinator:startOver()
            self.start_over_count = self.start_over_count + 1
            self.state = "loading"
            return true
        end

        package.preload["ui/widget/buttondialog"] = function()
            return button_dialog
        end
        package.preload.device = function()
            return {
                screen = {
                    getWidth = function() return 600 end,
                    getHeight = function() return 800 end,
                    scaleBySize = function(_, value) return value end,
                },
            }
        end
        package.preload["ui/font"] = function()
            return { getFace = function(_, name) return name end }
        end
        package.preload["ui/widget/progresswidget"] = function()
            return progress_widget
        end
        package.preload["ui/widget/textboxwidget"] = function()
            return text_box_widget
        end
        package.preload["ui/uimanager"] = function()
            return ui_manager
        end
        package.preload["ui/widget/verticalgroup"] = function()
            return vertical_group
        end
        package.preload["ui/widget/verticalspan"] = function()
            return simple_widget()
        end
        package.preload.gettext = function()
            return function(value) return value end
        end

        PlaybackDialog = require("playbackdialog")
    end)

    after_each(function()
        package.loaded.playbackdialog = nil
        for _, module_name in ipairs{
            "ui/widget/buttondialog",
            "device",
            "ui/font",
            "ui/widget/progresswidget",
            "ui/widget/textboxwidget",
            "ui/uimanager",
            "ui/widget/verticalgroup",
            "ui/widget/verticalspan",
            "gettext",
        } do
            package.loaded[module_name] = nil
            package.preload[module_name] = nil
        end
    end)

    it("shows transport controls and updates progress while playing", function()
        local dialog = PlaybackDialog:new{
            coordinator = coordinator,
            scheduler = scheduler,
        }
        dialog:onShow()
        assert.are.equal("Ready\n— / —", dialog.status_text.text)
        assert.are.equal(0, dialog.progress_bar.percentage)
        assert.are.equal("Hide", dialog.buttons[2][2].text)
        assert.are.equal("Start here", dialog:getButtonById("start_here").text)
        assert.are.equal(0, scheduler.schedules)

        dialog.buttons[1][2].callback()
        assert.are.equal(1, coordinator.toggle_count)
        assert.are.equal("Loading…", dialog:getButtonById("toggle").text)
        assert.are.equal(1, scheduler.schedules)

        coordinator.state = "playing"
        coordinator.position = 30
        coordinator.duration = 120
        scheduler:fire(dialog.refresh_action)
        assert.are.equal("Playing · following\n0:30 / 2:00", dialog.status_text.text)
        assert.are.equal(0.25, dialog.progress_bar.percentage)
        assert.are.equal("Pause", dialog:getButtonById("toggle").text)
        scheduler:fire(dialog.refresh_action)
        assert.are.equal("fast", ui_manager.dirty[#ui_manager.dirty].refresh_type)

        dialog.buttons[1][1].callback()
        dialog.buttons[1][3].callback()
        assert.are.same({ -15, 15 }, coordinator.seeks)
    end)

    it("stops refreshes when paused", function()
        coordinator.state = "playing"
        coordinator.position = 10
        coordinator.duration = 20
        local dialog = PlaybackDialog:new{
            coordinator = coordinator,
            scheduler = scheduler,
        }
        dialog:onShow()
        assert.is_true(dialog.refresh_scheduled)
        assert.are.equal("Pause", dialog:getButtonById("toggle").text)

        dialog.buttons[1][2].callback()
        assert.are.equal("paused", coordinator.state)
        assert.are.equal(1, coordinator.toggle_count)
        assert.are.equal("Resume", dialog:getButtonById("toggle").text)
        assert.is_false(dialog.refresh_scheduled)
        assert.is_nil(scheduler.tasks[dialog.refresh_action])
        assert.are.equal(1, scheduler.unschedules)
    end)

    it("hides while playing without changing playback state", function()
        coordinator.state = "playing"
        coordinator.position = 10
        coordinator.duration = 20
        local closed = 0
        local dialog = PlaybackDialog:new{
            coordinator = coordinator,
            scheduler = scheduler,
            on_close = function()
                closed = closed + 1
            end,
        }
        dialog:onShow()
        assert.is_true(dialog.refresh_scheduled)
        assert.are.equal("Hide", dialog.buttons[2][2].text)

        dialog.buttons[2][2].callback()
        assert.are.equal("playing", coordinator.state)
        assert.are.equal(10, coordinator.position)
        assert.are.equal(20, coordinator.duration)
        assert.are.equal(0, coordinator.toggle_count)
        assert.are.equal(0, coordinator.stop_count)
        assert.is_false(dialog.refresh_scheduled)
        assert.is_nil(scheduler.tasks[dialog.refresh_action])
        assert.are.equal(1, scheduler.unschedules)
        assert.are.equal(dialog, ui_manager.closed[1])
        assert.are.equal(1, closed)
        assert.are.equal(1, dialog.base_close_count)
    end)

    it("shows explicit resume, current-position, and start-over choices without autoplay", function()
        coordinator.has_resume = true
        local dialog = PlaybackDialog:new{
            coordinator = coordinator,
            scheduler = scheduler,
        }
        assert.are.equal(0, coordinator.toggle_count)
        assert.are.equal("Resume", dialog:getButtonById("resume").text)
        assert.are.equal("Start here", dialog:getButtonById("start_here").text)
        assert.are.equal("Start over", dialog:getButtonById("start_over").text)

        dialog.buttons[3][1].callback()
        assert.are.equal(1, coordinator.resume_saved_count)
        assert.are.equal(0, coordinator.start_here_count)
        assert.are.equal(0, coordinator.start_over_count)
    end)

    it("keeps start over available after narration reaches the end", function()
        coordinator.state = "ended"
        local dialog = PlaybackDialog:new{
            coordinator = coordinator,
            scheduler = scheduler,
        }

        assert.is_nil(dialog:getButtonById("resume"))
        assert.are.equal("Start over", dialog:getButtonById("start_over").text)
        dialog.buttons[3][2].callback()
        assert.are.equal(1, coordinator.start_over_count)
    end)

    it("hides while paused without changing playback state", function()
        coordinator.state = "paused"
        coordinator.position = 10
        coordinator.duration = 20
        local dialog = PlaybackDialog:new{
            coordinator = coordinator,
            scheduler = scheduler,
        }
        dialog:onShow()
        assert.is_nil(dialog.refresh_scheduled)
        assert.are.equal("Hide", dialog.buttons[2][2].text)

        dialog.buttons[2][2].callback()
        assert.are.equal("paused", coordinator.state)
        assert.are.equal(10, coordinator.position)
        assert.are.equal(20, coordinator.duration)
        assert.are.equal(0, coordinator.toggle_count)
        assert.are.equal(0, coordinator.stop_count)
        assert.are.equal(0, scheduler.unschedules)
        assert.are.equal(dialog, ui_manager.closed[1])
        assert.are.equal(1, dialog.base_close_count)
    end)

    it("does not duplicate an error already reported by the coordinator", function()
        local reported = 0
        function coordinator:toggle()
            self.state = "idle"
            return nil, "KinAMP daemon is unavailable", true
        end
        local dialog = PlaybackDialog:new{
            coordinator = coordinator,
            scheduler = scheduler,
            on_error = function()
                reported = reported + 1
            end,
        }
        dialog:onShow()
        dialog.buttons[1][2].callback()
        assert.are.equal(0, reported)
    end)

    it("shows unavailable text calmly without reporting an audio error", function()
        local errors = 0
        local dialog = PlaybackDialog:new{
            coordinator = coordinator,
            scheduler = scheduler,
            on_error = function() errors = errors + 1 end,
        }
        assert.are.equal(60, dialog.status_text.height)
        coordinator.has_text_range = false
        for _, state in ipairs({ "playing", "paused" }) do
            coordinator.state = state
            dialog:_refresh(true)
            assert.is_truthy(dialog.status_text.text:find("Text highlighting unavailable", 1, true))
            assert.are.equal(60, dialog.status_text:getSize().h)
        end
        coordinator.has_text_range = true
        dialog:_refresh(true)
        assert.is_nil(dialog.status_text.text:find("Text highlighting unavailable", 1, true))
        assert.are.equal(60, dialog.status_text:getSize().h)
        coordinator.state = "error"
        coordinator.has_text_range = false
        dialog:_refresh(true)
        assert.is_truthy(dialog.status_text.text:find("Unavailable", 1, true))
        assert.is_nil(dialog.status_text.text:find("Text highlighting unavailable", 1, true))
        assert.are.equal(0, errors)
    end)

    it("dispatches Follow in playing and paused states without transport actions", function()
        local follow_state = "following"
        local dialog = PlaybackDialog:new{
            coordinator = coordinator,
            scheduler = scheduler,
            get_follow_state = function() return follow_state end,
            on_follow = function()
                follow_state = follow_state == "following" and "browsing" or "following"
                return true
            end,
        }
        for _, state in ipairs({ "playing", "paused" }) do
            coordinator.state = state
            assert.is_true(dialog:getButtonById("follow").enabled_func())
            dialog.buttons[4][1].callback()
            assert.are.equal("Follow: off", dialog:getButtonById("follow").text)
            dialog.buttons[4][1].callback()
            assert.are.equal("Follow: on", dialog:getButtonById("follow").text)
            assert.are.equal(state, coordinator.state)
        end
        assert.are.equal(0, coordinator.toggle_count)
        assert.are.equal(0, coordinator.stop_count)
    end)

    it("shows following and browsing state without changing the transport", function()
        local follow_state = "following"
        coordinator.state = "playing"
        coordinator.position = 30
        coordinator.duration = 120
        local dialog = PlaybackDialog:new{
            coordinator = coordinator,
            scheduler = scheduler,
            get_follow_state = function()
                return follow_state
            end,
            get_return_enabled = function()
                return follow_state == "browsing"
            end,
        }
        dialog:onShow()
        assert.are.equal("Playing · following\n0:30 / 2:00", dialog.status_text.text)

        follow_state = "browsing"
        dialog:onFollowStateChanged()
        assert.are.equal("Playing · browsing\n0:30 / 2:00", dialog.status_text.text)
        assert.are.equal("ui", ui_manager.dirty[#ui_manager.dirty].refresh_type)
        assert.are.equal(dialog.movable.dimen, ui_manager.dirty[#ui_manager.dirty].dimen)

        coordinator.state = "paused"
        follow_state = "following"
        dialog:onFollowStateChanged()
        assert.are.equal("Paused · following\n0:30 / 2:00", dialog.status_text.text)

        follow_state = "browsing"
        dialog:onFollowStateChanged()
        assert.are.equal("Paused · browsing\n0:30 / 2:00", dialog.status_text.text)
    end)

    it("exposes a return action and refreshes its enabled state", function()
        local return_enabled = false
        local returned = 0
        coordinator.state = "playing"
        local dialog = PlaybackDialog:new{
            coordinator = coordinator,
            scheduler = scheduler,
            get_return_enabled = function()
                return return_enabled
            end,
            on_return = function()
                returned = returned + 1
                return true
            end,
        }
        local return_button = dialog.buttons[4][2]
        assert.are.equal("Return to narration", return_button.text)
        assert.is_false(return_button.enabled_func())

        return_enabled = true
        assert.is_true(return_button.enabled_func())
        return_button.callback()
        assert.are.equal(1, returned)
        assert.are.equal(1, #ui_manager.dirty)
    end)

    it("calls start hooks for new starts but preserves browsing on resume", function()
        local started = 0
        local dialog = PlaybackDialog:new{
            coordinator = coordinator,
            scheduler = scheduler,
            get_follow_state = function()
                return "browsing"
            end,
            on_start = function()
                started = started + 1
            end,
        }
        dialog.buttons[3][1].callback()
        assert.are.equal(1, started)

        coordinator.state = "paused"
        dialog = PlaybackDialog:new{
            coordinator = coordinator,
            scheduler = scheduler,
            get_follow_state = function()
                return "browsing"
            end,
            on_start = function()
                started = started + 1
            end,
        }
        dialog.buttons[1][2].callback()
        assert.are.equal(1, started)
        assert.are.equal("playing", coordinator.state)
    end)
end)
