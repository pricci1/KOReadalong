package.path = "./koreadalong.koplugin/?.lua;" .. package.path

describe("KOReadalong lifecycle and menu", function()
    local plugin
    local overlay
    local highlight
    local coordinator
    local dispatcher
    local playback_dialog
    local ui_manager
    local info_message
    local registered_menu_widget
    local overlays_available
    local skipped_clips
    local goto_events
    local range_visible
    local current_xpointer
    local pointer_pages
    local is_kindle
    local adapter_module_loads
    local mpv_adapter
    local kindle_adapter
    local original_reader_settings

    local clips = {
        {
            text_path = "book/chapter.xhtml",
            text_fragment = "sentence",
            spine_index = 0,
            audio_path = "book/audio.wav",
            clip_begin = 0,
            clip_end = 1,
        },
    }

    before_each(function()
        original_reader_settings = _G.G_reader_settings
        _G.G_reader_settings = {
            readSetting = function(self, key) return self[key] end,
            saveSetting = function(self, key, value) self[key] = value end,
            flush = function() end,
        }
        for _, module_name in ipairs{
            "main",
            "device",
            "mediaoverlays",
            "timeline",
            "fragmentresolver",
            "underlineoverlay",
            "materializer",
            "mpvaudio",
            "kindleaudio",
            "playbackcoordinator",
            "playbackdialog",
            "narrationstate",
        } do
            package.loaded[module_name] = nil
        end

        local widget_container = {}
        function widget_container:extend(prototype)
            setmetatable(prototype, self)
            self.__index = self
            return prototype
        end
        function widget_container:new(options)
            options = options or {}
            setmetatable(options, self)
            self.__index = self
            if options.init then
                options:init()
            end
            return options
        end

        dispatcher = {
            actions = {},
            register_count = 0,
        }
        function dispatcher:registerAction(name, action)
            self.actions[name] = action
            self.register_count = self.register_count + 1
        end

        overlay = {
            new_count = 0,
            register_count = 0,
            refresh_count = 0,
            invalidate_count = 0,
            clear_count = 0,
            deactivate_count = 0,
        }
        highlight = {
            buttons = {},
            add_count = 0,
            highlight_from_hold_count = 0,
            close_count = 0,
            clear_count = 0,
            can_jump = true,
        }
        function highlight:addToHighlightDialog(key, callback)
            self.add_count = self.add_count + 1
            self.buttons[key] = callback
        end
        function highlight:highlightFromHoldPos()
            self.highlight_from_hold_count = self.highlight_from_hold_count + 1
            if self.next_selected_text then
                self.selected_text = self.next_selected_text
            end
        end
        function highlight:onClose()
            self.close_count = self.close_count + 1
            self.selected_text = nil
        end
        function highlight:clear()
            self.clear_count = self.clear_count + 1
            self.selected_text = nil
        end
        overlays_available = true
        skipped_clips = 0
        registered_menu_widget = nil
        goto_events = {}
        range_visible = true
        current_xpointer = "/body/DocFragment[1]/body/p/text().0"
        pointer_pages = { narrated = 1, ["narrated-end"] = 1 }
        is_kindle = false
        adapter_module_loads = {
            mpv = 0,
            kindle = 0,
        }
        mpv_adapter = {}
        kindle_adapter = {}
        function overlay.isRangeVisible()
            return range_visible
        end
        function overlay.new(options)
            overlay.new_count = overlay.new_count + 1
            overlay.options = options
            local instance = { mode = options.mode or "margin" }
            function instance:setMode(mode)
                self.mode = mode
            end
            function instance:register()
                overlay.register_count = overlay.register_count + 1
            end
            function instance:refresh()
                overlay.refresh_count = overlay.refresh_count + 1
            end
            function instance:invalidate()
                overlay.invalidate_count = overlay.invalidate_count + 1
            end
            function instance:clear()
                overlay.clear_count = overlay.clear_count + 1
            end
            function instance:deactivate()
                overlay.deactivate_count = overlay.deactivate_count + 1
            end
            return instance
        end

        coordinator = {
            state = "idle",
            close_count = 0,
            stop_count = 0,
            play_from_calls = {},
            can_jump = true,
            current_range = nil,
        }
        function coordinator.new(options)
            coordinator.options = options
            local instance = coordinator
            function instance:getState()
                return self.state
            end
            function instance:isActionEnabled()
                return self.state ~= "loading"
                    and self.state ~= "stopping"
                    and self.state ~= "error"
            end
            function instance:isStopEnabled()
                return self.state ~= "idle"
                    and self.state ~= "ended"
                    and self.state ~= "loading"
                    and self.state ~= "stopping"
                    and self.state ~= "error"
            end
            function instance:toggle()
                self.state = self.state == "playing" and "paused" or "playing"
            end
            function instance:stop()
                self.stop_count = self.stop_count + 1
                self.state = "idle"
            end
            function instance:canPlayFromXPointer(pos0, pos1)
                self.can_play_arguments = { pos0, pos1 }
                return self.can_jump
            end
            function instance:getCurrentRange()
                return self.current_range
            end
            function instance:playFromXPointer(pos0, pos1)
                self.play_from_calls[#self.play_from_calls + 1] = { pos0, pos1 }
                if self.emit_range_on_play_from then
                    self.options.on_range("selected-start", "selected-end")
                end
                if self.fail_on_play_from then
                    self.state = "error"
                    self.options.on_error(self.fail_on_play_from)
                    return nil, self.fail_on_play_from
                end
                if self.play_from_error then
                    return nil, self.play_from_error
                end
                return true
            end
            function instance:close()
                if self.state ~= "closed" then
                    self.close_count = self.close_count + 1
                end
                self.state = "closed"
            end
            return instance
        end

        playback_dialog = {
            new_count = 0,
        }
        function playback_dialog:new(options)
            self.new_count = self.new_count + 1
            local dialog = options
            dialog.kind = "playback_dialog"
            return dialog
        end

        ui_manager = {
            shown = {},
            closed = {},
            tasks = {},
            event_hook = {
                handlers = {},
            },
        }
        function ui_manager.event_hook:register(name, handler)
            self.handlers[name] = self.handlers[name] or {}
            self.handlers[name][handler] = true
        end
        function ui_manager.event_hook:unregister(name, handler)
            if self.handlers[name] then
                self.handlers[name][handler] = nil
            end
        end
        function ui_manager.event_hook:execute(name)
            for handler in pairs(self.handlers[name] or {}) do
                handler()
            end
        end
        function ui_manager:scheduleIn(_, action)
            self.tasks[action] = true
        end
        function ui_manager:nextTick(action)
            self.tasks[action] = true
        end
        function ui_manager:unschedule(action)
            self.tasks[action] = nil
        end
        function ui_manager:fire(action)
            if self.tasks[action] then
                self.tasks[action] = nil
                action()
            end
        end
        function ui_manager:fire_next()
            local action = next(self.tasks)
            if action then
                self:fire(action)
            end
        end
        function ui_manager:show(message)
            self.shown[#self.shown + 1] = message
        end
        function ui_manager:close(message)
            self.closed[#self.closed + 1] = message
            if message.on_close then
                message.on_close()
            end
        end

        info_message = {}
        function info_message:new(options)
            return options
        end

        package.preload["ui/widget/container/widgetcontainer"] = function()
            return widget_container
        end
        package.preload.dispatcher = function()
            return dispatcher
        end
        package.preload.device = function()
            return {
                isKindle = function()
                    return is_kindle
                end,
            }
        end
        package.preload["underlineoverlay"] = function()
            return overlay
        end
        package.preload["playbackcoordinator"] = function()
            return coordinator
        end
        package.preload["playbackdialog"] = function()
            return playback_dialog
        end
        package.preload["mpvaudio"] = function()
            adapter_module_loads.mpv = adapter_module_loads.mpv + 1
            return {
                new = function()
                    return mpv_adapter
                end,
            }
        end
        package.preload["kindleaudio"] = function()
            adapter_module_loads.kindle = adapter_module_loads.kindle + 1
            return {
                new = function()
                    return kindle_adapter
                end,
            }
        end
        package.preload["materializer"] = function()
            return { new = function() return {} end }
        end
        package.preload["ui/uimanager"] = function()
            return ui_manager
        end
        package.preload["ui/event"] = function()
            return {
                new = function(_, name, ...)
                    return { name = name, args = { ... } }
                end,
            }
        end
        package.preload["ui/widget/infomessage"] = function()
            return info_message
        end
        package.preload["ui/widget/confirmbox"] = function()
            return info_message
        end
        package.preload["gettext"] = function()
            return function(value) return value end
        end
        package.preload["mediaoverlays"] = function()
            return {
                load = function()
                    return overlays_available and clips or {}, nil, skipped_clips
                end,
            }
        end

        local KOReadalong = require("main")
        plugin = KOReadalong:new{
            dialog = "dialog",
            document = {
                provider = "crengine",
                getDocumentFileContent = function() return "bytes" end,
                getXPointer = function()
                    return current_xpointer
                end,
                getPageFromXPointer = function(_, pointer)
                    return pointer_pages[pointer] or 2
                end,
                getPosFromXPointer = function(_, pointer)
                    return pointer == "narrated" and 10 or 20
                end,
                isXPointerInCurrentPage = function()
                    return range_visible
                end,
            },
            ui = {
                highlight = highlight,
                doc_settings = {
                    readSetting = function(self, key) return self[key] end,
                    saveSetting = function(self, key, value) self[key] = value end,
                    flush = function() end,
                },
                handleEvent = function(_, event)
                    goto_events[#goto_events + 1] = event
                    range_visible = true
                end,
                menu = {
                    registerToMainMenu = function(_, widget)
                        registered_menu_widget = widget
                    end,
                },
            },
            view = "view",
        }
    end)

    after_each(function()
        _G.G_reader_settings = original_reader_settings
        for _, module_name in ipairs{
            "main",
            "device",
            "mediaoverlays",
            "timeline",
            "fragmentresolver",
            "underlineoverlay",
            "materializer",
            "mpvaudio",
            "kindleaudio",
            "playbackcoordinator",
            "playbackdialog",
            "narrationstate",
            "ui/uimanager",
            "ui/event",
            "ui/widget/infomessage",
            "ui/widget/confirmbox",
            "kinamp_btdevices",
            "kinampservice",
            "gettext",
            "ui/widget/container/widgetcontainer",
            "dispatcher",
        } do
            package.preload[module_name] = nil
            package.loaded[module_name] = nil
        end
    end)

    it("lazily selects mpv on non-Kindle devices", function()
        assert.is_nil(package.loaded["mpvaudio"])
        assert.is_nil(package.loaded["kindleaudio"])

        plugin:onReaderReady()

        assert.are.equal(1, adapter_module_loads.mpv)
        assert.are.equal(0, adapter_module_loads.kindle)
        assert.is_not_nil(package.loaded["mpvaudio"])
        assert.is_nil(package.loaded["kindleaudio"])
        assert.are.equal(mpv_adapter, coordinator.options.adapter)
    end)

    it("wires the reader position and durable book state without autoplay", function()
        plugin.ui.doc_settings.koreadalong_playback_speed = 1.7
        plugin:onReaderReady()

        assert.are.equal(current_xpointer, coordinator.options.get_current_xpointer())
        assert.are.equal(
            plugin.ui.doc_settings,
            coordinator.options.state_store.settings
        )
        assert.are.equal("idle", coordinator:getState())
        assert.are.equal(1.7, coordinator.options.speed)
        coordinator.options.on_speed(0.8)
        assert.are.equal(0.8, plugin.ui.doc_settings.koreadalong_playback_speed)
    end)

    it("lazily selects Kindle audio on Kindle devices", function()
        is_kindle = true
        assert.is_nil(package.loaded["mpvaudio"])
        assert.is_nil(package.loaded["kindleaudio"])

        plugin:onReaderReady()

        assert.are.equal(0, adapter_module_loads.mpv)
        assert.are.equal(1, adapter_module_loads.kindle)
        assert.is_nil(package.loaded["mpvaudio"])
        assert.is_not_nil(package.loaded["kindleaudio"])
        assert.are.equal(kindle_adapter, coordinator.options.adapter)
    end)

    it("silently leaves ordinary documents untouched", function()
        overlays_available = false
        assert.are.equal(2, dispatcher.register_count)
        assert.are.same({
            category = "none",
            event = "ShowReadAlongControls",
            title = "KOReadalong: show playback controls",
            reader = true,
        }, dispatcher.actions.koreadalong_show_controls)
        assert.are.same({
            category = "none",
            event = "ReturnToNarration",
            title = "KOReadalong: return to narration",
            reader = true,
        }, dispatcher.actions.koreadalong_return_to_narration)
        assert.is_false(plugin:onShowReadAlongControls())
        plugin:onReaderReady()
        assert.is_nil(plugin.overlay)
        assert.is_nil(registered_menu_widget)
        assert.are.equal(0, highlight.add_count)
        assert.are.equal(0, #ui_manager.shown)
    end)

    for _, kindle in ipairs{ false, true } do
        it("warns once and keeps playback available on " .. (kindle and "Kindle" or "desktop"), function()
            is_kindle = kindle
            skipped_clips = 2
            plugin:onReaderReady()
            plugin:onReaderReady()
            plugin:onPageUpdate()
            assert.are.equal(1, #ui_manager.shown)
            assert.matches("Skipped clips: 2", ui_manager.shown[1].text)
            assert.matches("end time at or before their start time", ui_manager.shown[1].text)
            assert.matches("remaining narration", ui_manager.shown[1].text)
            assert.are.equal(plugin, registered_menu_widget)
            assert.is_true(plugin:onShowReadAlongControls())
        end)
    end

    it("explains all-invalid narration once without offering playback", function()
        overlays_available = false
        skipped_clips = 3
        plugin:onReaderReady()
        plugin:onReaderReady()
        plugin:onPageUpdate()
        assert.are.equal(1, #ui_manager.shown)
        assert.matches("Skipped clips: 3", ui_manager.shown[1].text)
        assert.matches("No valid narration clips remain", ui_manager.shown[1].text)
        assert.matches("Read along is unavailable", ui_manager.shown[1].text)
        assert.is_nil(registered_menu_widget)
        assert.is_nil(plugin.coordinator)
        assert.is_false(plugin:onShowReadAlongControls())
    end)

    it("routes the registered Return to narration dispatcher event", function()
        plugin:onReaderReady()
        coordinator.state = "playing"
        plugin.latest_range = { pos0 = "narrated", pos1 = "narrated-end" }
        plugin:_set_browsing()
        range_visible = false

        assert.are.equal("ReturnToNarration",
            dispatcher.actions.koreadalong_return_to_narration.event)
        assert.is_true(plugin:onReturnToNarration())
        assert.are.equal("following", plugin.follow_state)
        assert.are.equal("narrated", goto_events[1].args[1])
    end)

    it("capability-gates non-CRe documents", function()
        plugin.document.provider = "pdf"
        plugin:onReaderReady()
        assert.is_nil(plugin.overlay)
        assert.is_nil(registered_menu_widget)
        assert.are.equal(0, highlight.add_count)
    end)

    it("registers the menu conditionally and opens one playback panel", function()
        plugin:onReaderReady()
        plugin:onReaderReady()
        assert.are.equal(1, overlay.new_count)
        assert.are.equal(1, overlay.register_count)
        assert.are.equal(1, highlight.add_count)
        assert.is_function(highlight.buttons["12_read_from_here"])
        assert.are.equal(plugin, registered_menu_widget)
        assert.are.equal(0, #ui_manager.shown)

        local items = {}
        plugin:addToMainMenu(items)
        assert.are.equal("Read along", items.read_along.text)
        assert.is_nil(items.kinamp_help)
        local controls = items.read_along.sub_item_table[1]
        assert.are.equal("Playback controls", controls.text)
        controls.callback()
        controls.callback()
        assert.are.equal(1, playback_dialog.new_count)
        assert.are.equal(1, #ui_manager.shown)
        assert.are.equal("playback_dialog", ui_manager.shown[1].kind)
        assert.are.equal(coordinator, ui_manager.shown[1].coordinator)

        ui_manager.shown[1].on_close()
        assert.is_true(plugin:onShowReadAlongControls())
        assert.are.equal(2, playback_dialog.new_count)
        assert.are.equal(2, #ui_manager.shown)
    end)

    it("defaults to margin bars and persists all narration mark choices across books", function()
        plugin:onReaderReady()
        local items = {}
        plugin:addToMainMenu(items)
        local marks = items.read_along.sub_item_table[2]
        assert.are.equal("Narration mark", marks.text)
        local choices = marks.sub_item_table
        assert.is_true(choices[1].checked_func())
        for index, mode in ipairs{ "margin", "underline", "off" } do
            choices[index].callback()
            assert.are.equal(mode, G_reader_settings.koreadalong_mark_mode)
            for other_index, choice in ipairs(choices) do
                assert.are.equal(index == other_index, choice.checked_func())
            end
            assert.are.equal("idle", coordinator:getState())
            -- Reinitialize with a fresh book sidecar; the mark is app-wide.
            plugin.probed = false
            plugin.ui.doc_settings.koreadalong_mark_mode = "unrelated book value"
            plugin:onReaderReady()
            assert.are.equal(mode, plugin.overlay.mode)
        end
    end)

    it("explains integrated Kindle startup and opens existing Bluetooth setup", function()
        is_kindle = true
        plugin:onReaderReady()

        local items = {}
        plugin:addToMainMenu(items)
        assert.are.equal("KinAMP setup and help", items.kinamp_help.text)
        assert.is_function(items.kinamp_help.callback)
        items.kinamp_help.callback()
        assert.are.equal(1, #ui_manager.shown)
        assert.matches("official KinAMP plugin", ui_manager.shown[1].text)
        assert.matches("automatically", ui_manager.shown[1].text)
        assert.matches("Bluetooth", ui_manager.shown[1].text)
        assert.matches("Closing a book stops narration; reopening never starts audio", ui_manager.shown[1].text)
        assert.matches(
            "https://github.com/kbarni/KinAMP/blob/master/README.md",
            ui_manager.shown[1].text
        )
        assert.matches("Optional experimental PW6 player", ui_manager.shown[1].text)
        assert.matches("neither is enabled automatically", ui_manager.shown[1].text)
        assert.matches(
            "https://github.com/pricci1/KOReadalong/releases",
            ui_manager.shown[1].text
        )
        assert.are.equal("Bluetooth setup", ui_manager.shown[1].ok_text)
        local opened = 0
        package.loaded.kinamp_btdevices = { open = function() opened = opened + 1 end }
        ui_manager.shown[1].ok_callback()
        assert.are.equal(1, opened)
        package.loaded.kinamp_btdevices = nil
        package.preload.kinamp_btdevices = function() error("not installed") end
        ui_manager.shown[1].ok_callback()
        assert.are.equal(2, #ui_manager.shown)
        assert.matches("Bluetooth settings are unavailable", ui_manager.shown[2].text)

        plugin.coordinator.options.on_error("KinAMP is busy")
        assert.are.equal(3, #ui_manager.shown)
        assert.matches("Another client is playing or paused", ui_manager.shown[3].text)
        assert.matches("left it untouched", ui_manager.shown[3].text)
        assert.matches("press Start again", ui_manager.shown[3].text)
    end)

    it("routes confirmed disconnected audio to the integrated Bluetooth settings", function()
        is_kindle = true
        plugin:onReaderReady()
        plugin.coordinator.options.on_error("Bluetooth audio is not connected")
        assert.are.equal(1, #ui_manager.shown)
        local prompt = ui_manager.shown[1]
        assert.matches("No Bluetooth audio device is connected", prompt.text)
        assert.matches("press Start again", prompt.text)
        assert.are.equal("Bluetooth setup", prompt.ok_text)
        local refreshed = false
        package.loaded.kinampservice = { shared = { get_bluetooth = function()
            refreshed = true
        end } }
        local opened = 0
        package.loaded.kinamp_btdevices = { open = function()
            assert.is_true(refreshed)
            opened = opened + 1
        end }
        prompt.ok_callback()
        assert.are.equal(1, opened)
    end)

    it("shows the selection action only for usable XPointers and routes its callback", function()
        plugin:onReaderReady()
        plugin:_set_browsing()
        highlight.selected_text = {
            pos0 = "word-start",
            pos1 = "word-end",
        }
        local action = highlight.buttons["12_read_from_here"](highlight)
        assert.are.equal("Read from here", action.text)
        assert.is_true(action.show_in_highlight_dialog_func())
        assert.are.same({ "word-start", "word-end" }, coordinator.can_play_arguments)

        action.callback()
        assert.are.equal(1, highlight.highlight_from_hold_count)
        assert.are.equal(1, highlight.close_count)
        assert.are.equal(0, highlight.clear_count)
        assert.are.same({
            { "word-start", "word-end" },
        }, coordinator.play_from_calls)
        assert.are.equal(0, #ui_manager.shown)
        assert.are.equal("following", plugin.follow_state)

        highlight.selected_text = {}
        action = highlight.buttons["12_read_from_here"](highlight)
        assert.is_false(action.show_in_highlight_dialog_func())
    end)

    it("toggles following without changing playing or paused transport", function()
        plugin:onReaderReady()
        for _, state in ipairs({ "playing", "paused" }) do
            coordinator.state = state
            plugin:_set_follow_state("following")
            plugin.latest_range = { pos0 = "active", pos1 = "active-end" }
            range_visible = false
            local count = #goto_events
            assert.is_true(plugin:toggleFollowing())
            assert.are.equal("browsing", plugin.follow_state)
            plugin.coordinator.options.on_range("latest", "latest-end")
            assert.are.equal(count, #goto_events)
            assert.is_true(plugin:toggleFollowing())
            assert.are.equal("following", plugin.follow_state)
            assert.are.equal("latest", goto_events[#goto_events].args[1])
            assert.are.equal(state, coordinator.state)
        end
    end)

    it("enables following without a range and waits for valid text", function()
        plugin:onReaderReady()
        coordinator.state = "playing"
        plugin:_set_browsing()
        local count = #goto_events
        assert.is_true(plugin:toggleFollowing())
        assert.are.equal("following", plugin.follow_state)
        assert.are.equal(count, #goto_events)
        range_visible = false
        plugin.coordinator.options.on_range("next", "next-end")
        assert.are.equal(count + 1, #goto_events)
    end)

    it("does not follow new ranges while browsing", function()
        plugin:onReaderReady()
        coordinator.state = "playing"
        plugin:_set_browsing()
        range_visible = false

        plugin.coordinator.options.on_range("later-start", "later-end")

        assert.are.equal("browsing", plugin.follow_state)
        assert.are.equal(0, #goto_events)
        assert.are.same({
            pos0 = "later-start",
            pos1 = "later-end",
        }, plugin.latest_range)
    end)

    it("keeps browsing through seek and resource handoff without stale jumps", function()
        plugin:onReaderReady()
        coordinator.state = "playing"
        plugin:_set_browsing()
        plugin.latest_range = { pos0 = "first-start", pos1 = "first-end" }
        range_visible = false

        plugin.coordinator.options.on_range_cleared("transition")
        assert.are.equal("browsing", plugin.follow_state)
        assert.is_nil(plugin.latest_range)

        plugin.coordinator.options.on_range("second-start", "second-end")
        assert.are.equal("browsing", plugin.follow_state)
        assert.are.same({
            pos0 = "second-start",
            pos1 = "second-end",
        }, plugin.latest_range)
        assert.are.equal(0, #goto_events)
    end)

    it("updates Return availability when browsing loses or gains a range", function()
        plugin:onReaderReady()
        coordinator.state = "playing"
        plugin:_set_browsing()
        plugin.playback_dialog = {
            availability_updates = 0,
            onReturnAvailabilityChanged = function(self)
                self.availability_updates = self.availability_updates + 1
            end,
        }
        plugin.latest_range = { pos0 = "narrated", pos1 = "narrated-end" }
        plugin.coordinator.options.on_range_cleared("gap")
        assert.are.equal(1, plugin.playback_dialog.availability_updates)

        plugin.coordinator.options.on_range("later-start", "later-end")
        assert.are.equal(2, plugin.playback_dialog.availability_updates)

        plugin.coordinator.options.on_range("later-start", "later-end")
        assert.are.equal(2, plugin.playback_dialog.availability_updates)
    end)

    it("enters following before a same-resource Read from here range callback", function()
        plugin:onReaderReady()
        plugin:_set_browsing()
        coordinator.state = "playing"
        coordinator.emit_range_on_play_from = true
        range_visible = false
        highlight.selected_text = {
            pos0 = "word-start",
            pos1 = "word-end",
        }

        local action = highlight.buttons["12_read_from_here"](highlight)
        action.callback()

        assert.are.equal("following", plugin.follow_state)
        assert.are.equal(1, #goto_events)
        assert.are.equal("selected-start", goto_events[1].args[1])
        assert.are.same({
            pos0 = "selected-start",
            pos1 = "selected-end",
        }, plugin.latest_range)
    end)

    it("does not carry the start control input into Following navigation", function()
        plugin:onReaderReady()
        ui_manager.event_hook:execute("InputEvent")
        assert.is_true(plugin.input_pending)

        plugin:_begin_following()

        assert.is_false(plugin.input_pending)
        assert.is_nil(plugin.input_expiry_action)
    end)

    it("closes the transient selection and reports jump errors", function()
        plugin:onReaderReady()
        highlight.selected_text = {
            pos0 = "word-start",
            pos1 = "word-end",
        }
        coordinator.play_from_error = "no media overlay segment contains the selected word"
        local action = highlight.buttons["12_read_from_here"](highlight)
        action.callback()

        assert.are.equal(1, highlight.highlight_from_hold_count)
        assert.are.equal(1, highlight.close_count)
        assert.is_nil(highlight.selected_text)
        assert.are.equal(1, #ui_manager.shown)
        assert.matches("no media overlay segment", ui_manager.shown[1].text)

        action.callback()
        assert.are.equal(2, highlight.close_count)
        assert.are.equal(2, #ui_manager.shown)
        assert.matches("no word is selected", ui_manager.shown[2].text)
    end)

    it("does not duplicate an error reported by a terminal coordinator failure", function()
        plugin:onReaderReady()
        highlight.selected_text = {
            pos0 = "word-start",
            pos1 = "word-end",
        }
        coordinator.fail_on_play_from = "decoder failed"
        local action = highlight.buttons["12_read_from_here"](highlight)
        action.callback()

        assert.are.equal("error", coordinator:getState())
        assert.are.equal(1, #ui_manager.shown)
        assert.matches("decoder failed", ui_manager.shown[1].text)
    end)

    it("shows explicit coordinator errors and routes rerender lifecycle", function()
        plugin:onReaderReady()
        local report_error = plugin.coordinator.options.on_error
        report_error("cannot load audio")
        assert.are.equal(1, #ui_manager.shown)
        assert.matches("cannot load audio", ui_manager.shown[1].text)

        for _, event in ipairs{
            "onPageUpdate",
            "onPosUpdate",
            "onDocumentRerendered",
            "onSetDimensions",
            "onSetRotationMode",
            "onRotationUpdate",
            "onZoomUpdate",
            "onFontSizeUpdate",
        } do
            plugin[event](plugin)
        end
        assert.are.equal(8, overlay.refresh_count)
        plugin:onDocumentPartiallyRerendered()
        assert.are.equal(1, overlay.invalidate_count)

        coordinator.state = "paused"
        assert.is_nil(plugin:onExit()) -- Do not consume KOReader's Exit broadcast.
        assert.are.equal("closed", coordinator:getState())
        assert.is_nil(plugin:onClose())
        plugin:onCloseDocument()
        plugin:onCloseWidget()
        assert.are.equal(1, coordinator.close_count)
    end)

    it("follows an active range only when it is outside the current page", function()
        plugin:onReaderReady()
        coordinator.state = "playing"
        local on_range = plugin.coordinator.options.on_range

        on_range("visible-start", "visible-end")
        assert.are.equal(0, #goto_events)

        range_visible = false
        on_range("next-start", "next-end")
        assert.are.equal(1, #goto_events)
        assert.are.equal("GotoXPointer", goto_events[1].name)
        assert.are.equal("next-start", goto_events[1].args[1])
        assert.are.equal(1, overlay.refresh_count)
    end)

    it("suspends on a deliberate page turn while narration is playing", function()
        plugin:onReaderReady()
        coordinator.state = "playing"
        plugin.last_xpointer = current_xpointer
        plugin.coordinator.options.on_range("narrated", "narrated-end")

        ui_manager.event_hook:execute("InputEvent")
        current_xpointer = "manual-page"
        plugin:onPageUpdate(2)
        assert.are.equal("following", plugin.follow_state)
        -- An audio poll can arrive before the deferred navigation classification.
        range_visible = false
        plugin.coordinator.options.on_range("narrated", "narrated-end")
        assert.are.equal(0, #goto_events)
        ui_manager:fire(plugin.navigation_candidate_action)
        assert.are.equal("browsing", plugin.follow_state)
    end)

    it("keeps following forward through a multi-page passage, but not beyond it", function()
        plugin:onReaderReady()
        coordinator.state = "playing"
        pointer_pages = { narrated = 3, ["narrated-end"] = 6 }
        current_xpointer = "narrated"
        plugin.last_xpointer = current_xpointer
        plugin.coordinator.options.on_range("narrated", "narrated-end")

        for page = 4, 7 do
            ui_manager.event_hook:execute("InputEvent")
            current_xpointer = "page-" .. page
            pointer_pages[current_xpointer] = page
            plugin:onPageUpdate(page)
            -- One move may emit both notifications before the next tick.
            plugin:onPosUpdate(page * 100, page)
            ui_manager:fire(plugin.navigation_candidate_action)
            assert.are.equal(page <= 6 and "following" or "browsing", plugin.follow_state)
            if page <= 6 then
                plugin.coordinator.options.on_range("narrated", "narrated-end")
                assert.are.equal(0, #goto_events)
            end
        end

        -- Once narration advances, normal automatic following still works.
        assert.is_true(plugin:returnToNarration())
        range_visible = false
        plugin.coordinator.options.on_range("next-start", "next-end")
        assert.are.equal("next-start", goto_events[#goto_events].args[1])
    end)

    it("allows paused continuation but still suspends on backward and same-page jumps", function()
        for _, destination in ipairs{ 2, 1, 3 } do
            plugin:onReaderReady()
            coordinator.state = "paused"
            pointer_pages = { narrated = 1, ["narrated-end"] = 4, source = 2, target = destination }
            current_xpointer = "source"
            plugin:_reset_navigation()
            plugin.coordinator.options.on_range("narrated", "narrated-end")

            ui_manager.event_hook:execute("InputEvent")
            current_xpointer = "target"
            plugin:onPageUpdate(destination)
            ui_manager:fire(plugin.navigation_candidate_action)
            assert.are.equal(destination == 3 and "following" or "browsing", plugin.follow_state)
        end
    end)

    it("keeps browsing after a paused manual jump and resume", function()
        plugin:onReaderReady()
        coordinator.state = "paused"
        plugin.last_xpointer = current_xpointer

        ui_manager.event_hook:execute("InputEvent")
        current_xpointer = "paused-page"
        plugin:onPageUpdate(2)
        ui_manager:fire(plugin.navigation_candidate_action)
        assert.are.equal("browsing", plugin.follow_state)

        coordinator.state = "playing"
        assert.are.equal("browsing", plugin.follow_state)
    end)

    it("classifies same-page TOC, search, and link jumps from input frames", function()
        plugin:onReaderReady()
        coordinator.state = "playing"
        current_xpointer = "narrated"
        plugin.last_xpointer = current_xpointer

        ui_manager.event_hook:execute("InputEvent")
        plugin:onPageUpdate(1)
        plugin:onPosUpdate(10, 1)
        ui_manager:fire(plugin.navigation_candidate_action)
        assert.are.equal("browsing", plugin.follow_state)
    end)

    it("does not classify its own goto or duplicate position events as browsing", function()
        plugin:onReaderReady()
        coordinator.state = "playing"
        range_visible = false
        local on_range = plugin.coordinator.options.on_range
        on_range("narrated", "narrated-end")
        current_xpointer = "narrated"
        plugin:onPageUpdate(1)
        plugin:onPageUpdate(1)
        plugin:onPosUpdate(10, 1)
        assert.are.equal("following", plugin.follow_state)
    end)

    it("does not classify duplicate page and position notifications as browsing", function()
        plugin:onReaderReady()
        coordinator.state = "playing"
        current_xpointer = "narrated"
        plugin.last_xpointer = current_xpointer

        plugin:onPageUpdate(1)
        plugin:onPosUpdate(10, 1)
        assert.is_nil(plugin.navigation_candidate)
        assert.are.equal("following", plugin.follow_state)
    end)

    it("does not classify rerender, rotation, zoom, or font changes as browsing", function()
        plugin:onReaderReady()
        coordinator.state = "playing"
        current_xpointer = "narrated"
        plugin.last_xpointer = current_xpointer

        plugin:onSetDimensions()
        plugin:onPageUpdate(2)
        plugin:onDocumentRerendered()
        plugin:onSetRotationMode()
        plugin:onRotationUpdate()
        plugin:onZoomUpdate()
        plugin:onFontSizeUpdate()
        assert.are.equal("following", plugin.follow_state)
        assert.is_nil(plugin.navigation_candidate)
    end)

    it("returns to the latest range and resumes future following", function()
        plugin:onReaderReady()
        coordinator.state = "playing"
        range_visible = true
        current_xpointer = "narrated"
        plugin.coordinator.options.on_range("narrated", "narrated-end")
        plugin.last_xpointer = current_xpointer

        ui_manager.event_hook:execute("InputEvent")
        current_xpointer = "manual-page"
        plugin:onPageUpdate(2)
        ui_manager:fire(plugin.navigation_candidate_action)
        assert.is_true(plugin:canReturnToNarration())

        local goto_count = #goto_events
        range_visible = false
        assert.is_true(plugin:returnToNarration())
        assert.are.equal("following", plugin.follow_state)
        assert.are.equal(goto_count + 1, #goto_events)
        assert.are.equal("narrated", goto_events[#goto_events].args[1])

        range_visible = false
        plugin.coordinator.options.on_range("future", "future-end")
        assert.are.equal(goto_count + 2, #goto_events)
    end)

    it("disables return and explains when no active range is available", function()
        plugin:onReaderReady()
        coordinator.state = "playing"
        plugin:_set_browsing()
        plugin.latest_range = nil

        assert.is_false(plugin:canReturnToNarration())
        assert.is_nil(plugin:onReturnToNarration())
        assert.are.equal(1, #ui_manager.shown)
        assert.matches("no current narrated text", ui_manager.shown[1].text)
    end)

    it("resets transient navigation for stop, EOF, new start, and close", function()
        plugin:onReaderReady()
        coordinator.state = "playing"
        plugin.latest_range = { pos0 = "narrated", pos1 = "narrated-end" }
        plugin:_set_browsing()
        plugin.coordinator.options.on_range_cleared("stop")
        assert.are.equal("following", plugin.follow_state)
        assert.is_nil(plugin.latest_range)

        plugin.latest_range = { pos0 = "narrated", pos1 = "narrated-end" }
        plugin:_set_browsing()
        plugin.coordinator.options.on_range_cleared("ended")
        assert.are.equal("following", plugin.follow_state)
        assert.is_nil(plugin.latest_range)

        plugin.latest_range = { pos0 = "narrated", pos1 = "narrated-end" }
        plugin:_set_browsing()
        plugin:_begin_following()
        assert.are.equal("following", plugin.follow_state)
        assert.is_nil(plugin.latest_range)

        plugin.latest_range = { pos0 = "narrated", pos1 = "narrated-end" }
        plugin:_set_browsing()
        plugin:onCloseDocument()
        assert.are.equal("following", plugin.follow_state)
        assert.is_nil(plugin.latest_range)
        assert.is_nil(next(ui_manager.event_hook.handlers.InputEvent))
    end)
end)
