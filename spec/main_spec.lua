package.path = "./koreadalong.koplugin/?.lua;" .. package.path

describe("KoReadalong lifecycle routing", function()
    local plugin
    local overlay

    before_each(function()
        package.loaded["main"] = nil

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

        overlay = {
            new_count = 0,
            register_count = 0,
            refresh_count = 0,
            invalidate_count = 0,
            deactivate_count = 0,
        }
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
            function instance:deactivate()
                overlay.deactivate_count = overlay.deactivate_count + 1
            end
            return instance
        end

        package.preload["ui/widget/container/widgetcontainer"] = function()
            return widget_container
        end
        package.preload["underlineoverlay"] = function()
            return overlay
        end

        local KoReadalong = require("main")
        plugin = KoReadalong:new{
            dialog = "dialog",
            document = "document",
            ui = "ui",
            view = "view",
        }
    end)

    after_each(function()
        package.preload["ui/widget/container/widgetcontainer"] = nil
        package.preload["underlineoverlay"] = nil
        package.loaded["main"] = nil
    end)

    it("registers once and routes every stable invalidation event", function()
        plugin:onReaderReady()
        plugin:onReaderReady()
        assert.are.equal(1, overlay.new_count)
        assert.are.equal(1, overlay.register_count)

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
    end)

    it("drops stale boxes for partial rerenders and deactivates on close", function()
        plugin:onReaderReady()
        plugin:onDocumentPartiallyRerendered()
        plugin:onCloseDocument()
        assert.are.equal(1, overlay.invalidate_count)
        assert.are.equal(1, overlay.deactivate_count)
    end)
end)
