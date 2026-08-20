package.path = "./koreadalong.koplugin/?.lua;" .. package.path

describe("KoReadalong lifecycle and menu", function()
    local plugin
    local overlay
    local coordinator
    local ui_manager
    local info_message
    local registered_menu_widget
    local overlays_available

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
            return options
        end

        overlay = {
            new_count = 0,
            register_count = 0,
            refresh_count = 0,
            invalidate_count = 0,
            clear_count = 0,
            deactivate_count = 0,
        }
        overlays_available = true
        registered_menu_widget = nil
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
        }
        function coordinator.new(options)
            coordinator.options = options
            local instance = coordinator
            function instance:getActionLabel()
                if self.state == "playing" then
                    return "Pause"
                elseif self.state == "paused" then
                    return "Resume"
                elseif self.state == "error" then
                    return "Unavailable"
                end
                return "Start"
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
            function instance:close()
                if self.state ~= "closed" then
                    self.close_count = self.close_count + 1
                end
                self.state = "closed"
            end
            return instance
        end

        ui_manager = {
            shown = {},
        }
        function ui_manager:show(message)
            self.shown[#self.shown + 1] = message
        end

        info_message = {}
        function info_message:new(options)
            return options
        end

        package.preload["ui/widget/container/widgetcontainer"] = function()
            return widget_container
        end
        package.preload["underlineoverlay"] = function()
            return overlay
        end
        package.preload["playbackcoordinator"] = function()
            return coordinator
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
            },
            ui = {
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
            "ui/uimanager",
            "ui/widget/infomessage",
            "gettext",
            "ui/widget/container/widgetcontainer",
        } do
            package.preload[module_name] = nil
            package.loaded[module_name] = nil
        end
    end)

    it("silently leaves ordinary documents untouched", function()
        overlays_available = false
        plugin:onReaderReady()
        assert.is_nil(plugin.overlay)
        assert.is_nil(registered_menu_widget)
    end)

    it("capability-gates non-CRe documents", function()
        plugin.document.provider = "pdf"
        plugin:onReaderReady()
        assert.is_nil(plugin.overlay)
        assert.is_nil(registered_menu_widget)
    end)

    it("registers the menu conditionally and exposes dynamic controls", function()
        plugin:onReaderReady()
        plugin:onReaderReady()
        assert.are.equal(1, overlay.new_count)
        assert.are.equal(1, overlay.register_count)
        assert.are.equal(plugin, registered_menu_widget)

        local items = {}
        plugin:addToMainMenu(items)
        local submenu = items.read_along.sub_item_table_func()
        assert.are.equal("Start", submenu[1].text_func())
        assert.is_true(submenu[1].enabled_func())
        assert.is_false(submenu[2].enabled_func())
        coordinator.state = "loading"
        assert.is_false(submenu[2].enabled_func())
        assert.are.equal(0, coordinator.stop_count)
        coordinator.state = "idle"
        submenu[1].callback()
        assert.are.equal("Pause", submenu[1].text_func())
        assert.are.equal("Stop", submenu[2].text)
        assert.is_true(submenu[2].enabled_func())
        submenu[1].callback()
        assert.are.equal("Resume", submenu[1].text_func())
        submenu[2].callback()
        assert.is_false(submenu[2].enabled_func())

        coordinator.state = "error"
        assert.are.equal("Unavailable", submenu[1].text_func())
        assert.is_false(submenu[1].enabled_func())
        assert.is_false(submenu[2].enabled_func())
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
end)
