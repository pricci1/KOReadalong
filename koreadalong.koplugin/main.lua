local WidgetContainer = require("ui/widget/container/widgetcontainer")
local UnderlineOverlay = require("underlineoverlay")

local KoReadalong = WidgetContainer:extend({
    name = "koreadalong",
    is_doc_only = true,
})

local function refresh_overlay(self)
    if self.overlay then
        self.overlay:refresh()
    end
end

function KoReadalong:onReaderReady()
    if self.overlay then
        return
    end
    self.overlay = UnderlineOverlay.new{
        dialog = self.dialog,
        document = self.document,
        ui = self.ui,
        view = self.view,
    }
    self.overlay:register()
end

function KoReadalong:onPageUpdate()
    refresh_overlay(self)
end

function KoReadalong:onPosUpdate()
    refresh_overlay(self)
end

function KoReadalong:onDocumentRerendered()
    refresh_overlay(self)
end

function KoReadalong:onSetDimensions()
    refresh_overlay(self)
end

function KoReadalong:onSetRotationMode()
    refresh_overlay(self)
end

function KoReadalong:onRotationUpdate()
    refresh_overlay(self)
end

function KoReadalong:onZoomUpdate()
    refresh_overlay(self)
end

function KoReadalong:onFontSizeUpdate()
    refresh_overlay(self)
end

function KoReadalong:onDocumentPartiallyRerendered()
    if self.overlay then
        self.overlay:invalidate()
    end
end

function KoReadalong:onCloseDocument()
    if self.overlay then
        self.overlay:deactivate()
    end
end

return KoReadalong
