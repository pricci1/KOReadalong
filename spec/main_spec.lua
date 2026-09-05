package.path = "./koreadalong.koplugin/?.lua;" .. package.path

describe("KoReadalong lifecycle and menu", function()
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
    local goto_events
    local range_visible
    local current_xpointer
    local is_kindle
    local adapter_module_loads
    local mpv_adapter
    local kindle_adapter

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
        registered_menu_widget = nil
        goto_events = {}
        range_visible = true
        current_xpointer = "/body/DocFragment[1]/body/p/text().0"
        is_kindle = false
        adapter_module_loads = {
            mpv = 0,
            kindle = 0,
        }
        mpv_adapter = {}
        kindle_adapter = {}
        function overlay.new(options)
            overlay.new_count = overlay.new_count + 1
            overlay.options = options
            local instance = {}
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
        package.preload["gettext"] = function()
            return function(value) return value end
        end
        package.preload["mediaoverlays"] = function()
            return {
                load = function()
                    return overlays_available and clips or {}
                end,
            }
        end

        local KoReadalong = require("main")
        plugin = KoReadalong:new{
            dialog = "dialog",
            document = {
                provider = "crengine",
                getDocumentFileContent = function() return "bytes" end,
                getXPointer = function()
                    return current_xpointer
                end,
                getPageFromXPointer = function(_, pointer)
                    return pointer == "narrated" and 1 or 2
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
                doc_settings = {},
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
        plugin:onReaderReady()

        assert.are.equal(current_xpointer, coordinator.options.get_current_xpointer())
        assert.are.equal(
            plugin.ui.doc_settings,
            coordinator.options.state_store.settings
        )
        assert.are.equal("idle", coordinator:getState())
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
            title = "KoReadalong: show playback controls",
            reader = true,
        }, dispatcher.actions.koreadalong_show_controls)
        assert.are.same({
            category = "none",
            event = "ReturnToNarration",
            title = "KoReadalong: return to narration",
            reader = true,
        }, dispatcher.actions.koreadalong_return_to_narration)
        assert.is_false(plugin:onShowReadAlongControls())
        plugin:onReaderReady()
        assert.is_nil(plugin.overlay)
        assert.is_nil(registered_menu_widget)
        assert.are.equal(0, highlight.add_count)
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

        local items = {}
        plugin:addToMainMenu(items)
        assert.are.equal("Read along", items.read_along.text)
        assert.is_nil(items.kinamp_help)
        assert.is_function(items.read_along.callback)
        items.read_along.callback()
        items.read_along.callback()
        assert.are.equal(1, playback_dialog.new_count)
        assert.are.equal(1, #ui_manager.shown)
        assert.are.equal("playback_dialog", ui_manager.shown[1].kind)
        assert.are.equal(coordinator, ui_manager.shown[1].coordinator)

        ui_manager.shown[1].on_close()
        assert.is_true(plugin:onShowReadAlongControls())
        assert.are.equal(2, playback_dialog.new_count)
        assert.are.equal(2, #ui_manager.shown)
    end)

    it("shows Kindle KinAMP recovery guidance and persistent setup help", function()
        is_kindle = true
        plugin:onReaderReady()

        local items = {}
        plugin:addToMainMenu(items)
        assert.are.equal("KinAMP setup and help", items.kinamp_help.text)
        assert.is_function(items.kinamp_help.callback)
        items.kinamp_help.callback()
        assert.are.equal(1, #ui_manager.shown)
        assert.matches("official KOReader plugin", ui_manager.shown[1].text)
        assert.matches("installation", ui_manager.shown[1].text)
        assert.matches("daemon lifecycle", ui_manager.shown[1].text)
        assert.matches("Bluetooth", ui_manager.shown[1].text)
        assert.matches("playlists", ui_manager.shown[1].text)
        assert.matches("management", ui_manager.shown[1].text)
        assert.matches("never launches, kills, quits", ui_manager.shown[1].text)
        assert.matches(
            "https://github.com/kbarni/KinAMP/blob/master/README.md",
            ui_manager.shown[1].text
        )

        plugin.coordinator.options.on_error(
            "KinAMP daemon is not running; start KinAMP first"
        )
        assert.are.equal(2, #ui_manager.shown)
        assert.is_truthy(ui_manager.shown[2].text:find(
            "KinAMP isn’t running",
            1,
            true
        ))
        assert.matches("Tools → KinAMP Player", ui_manager.shown[2].text)
        assert.matches("choose Stop playback", ui_manager.shown[2].text)
        assert.is_truthy(ui_manager.shown[2].text:find(
            "still-open EPUB",
            1,
            true
        ))
        assert.matches("press Start again", ui_manager.shown[2].text)
        assert.matches("does not manage KinAMP", ui_manager.shown[2].text)

        plugin.coordinator.options.on_error("KinAMP is busy")
        assert.are.equal(3, #ui_manager.shown)
        assert.matches("Stop the current KinAMP playback", ui_manager.shown[3].text)
        assert.matches("other client", ui_manager.shown[3].text)
        assert.matches("leave KinAMP idle", ui_manager.shown[3].text)
        assert.matches("press Start again", ui_manager.shown[3].text)
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

        plugin:onCloseDocument()
        plugin:onCloseWidget()
        assert.are.equal(1, coordinator.close_count)
    end)

    it("follows an active range only when it is outside the current page", function()
        plugin:onReaderReady()
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
        plugin.last_position_signature = "page:1:nil"

        ui_manager.event_hook:execute("InputEvent")
        current_xpointer = "manual-page"
        plugin:onPageUpdate(2)
        assert.are.equal("following", plugin.follow_state)
        ui_manager:fire(plugin.navigation_candidate_action)
        assert.are.equal("browsing", plugin.follow_state)
    end)

    it("keeps browsing after a paused manual jump and resume", function()
        plugin:onReaderReady()
        coordinator.state = "paused"
        plugin.last_xpointer = current_xpointer
        plugin.last_position_signature = "page:1:nil"

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
        plugin.last_position_signature = "page:1:nil"

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

    it("does not classify rerender, rotation, zoom, or font changes as browsing", function()
        plugin:onReaderReady()
        coordinator.state = "playing"
        current_xpointer = "narrated"
        plugin.last_xpointer = current_xpointer
        plugin.last_position_signature = "page:1:nil"

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
        plugin.last_position_signature = "page:1:nil"

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
