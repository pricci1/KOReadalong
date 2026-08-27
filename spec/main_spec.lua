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
            "mediaoverlays",
            "timeline",
            "fragmentresolver",
            "underlineoverlay",
            "materializer",
            "mpvaudio",
            "playbackcoordinator",
            "playbackdialog",
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
        }
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
            return { new = function() return {} end }
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
                isXPointerInCurrentPage = function()
                    return range_visible
                end,
            },
            ui = {
                highlight = highlight,
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
            "mediaoverlays",
            "timeline",
            "fragmentresolver",
            "underlineoverlay",
            "materializer",
            "mpvaudio",
            "playbackcoordinator",
            "playbackdialog",
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

    it("silently leaves ordinary documents untouched", function()
        overlays_available = false
        assert.are.equal(1, dispatcher.register_count)
        assert.are.same({
            category = "none",
            event = "ShowReadAlongControls",
            title = "KoReadalong: show playback controls",
            reader = true,
        }, dispatcher.actions.koreadalong_show_controls)
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

    it("shows the selection action only for usable XPointers and routes its callback", function()
        plugin:onReaderReady()
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
end)
