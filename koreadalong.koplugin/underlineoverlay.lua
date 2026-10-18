local UnderlineOverlay = {}
UnderlineOverlay.__index = UnderlineOverlay

local function valid_pointer(pointer)
    return type(pointer) == "string" and pointer ~= ""
end

local function finite_number(value)
    return type(value) == "number"
        and value == value
        and value ~= math.huge
        and value ~= -math.huge
end

local function invoke(object, method_name, ...)
    local method = object and object[method_name]
    if type(method) ~= "function" then
        return false
    end
    local ok, result = pcall(method, object, ...)
    if not ok then
        return false
    end
    return true, result
end

function UnderlineOverlay.isRangeVisible(document, pos0, pos1)
    local start_ok, start_visible = invoke(document, "isXPointerInCurrentPage", pos0)
    local end_ok, end_visible = invoke(document, "isXPointerInCurrentPage", pos1)
    if (start_ok and start_visible == true) or (end_ok and end_visible == true) then
        return true
    end
    -- A long passage can fill the screen without either endpoint being visible.
    -- Resolve pages afresh so font, rotation and layout changes cannot stale them.
    local _, start_page = invoke(document, "getPageFromXPointer", pos0)
    local _, end_page = invoke(document, "getPageFromXPointer", pos1)
    local _, page = invoke(document, "getCurrentPage")
    return type(start_page) == "number" and type(end_page) == "number"
        and type(page) == "number" and page > start_page and page < end_page
end

local function normalize_boxes(boxes)
    if type(boxes) ~= "table" then
        return {}
    end

    local normalized = {}
    for index = 1, #boxes do
        local box = boxes[index]
        if type(box) ~= "table"
            or not finite_number(box.x)
            or not finite_number(box.y)
            or not finite_number(box.w)
            or not finite_number(box.h)
            or box.w <= 0
            or box.h <= 0 then
            return {}
        end
        normalized[index] = {
            x = box.x,
            y = box.y,
            w = box.w,
            h = box.h,
        }
    end
    return normalized
end

local function boxes_equal(left, right)
    if #left ~= #right then
        return false
    end
    for index = 1, #left do
        local left_box = left[index]
        local right_box = right[index]
        if left_box.x ~= right_box.x
            or left_box.y ~= right_box.y
            or left_box.w ~= right_box.w
            or left_box.h ~= right_box.h then
            return false
        end
    end
    return true
end

local function line_thickness(size)
    return math.max(1, math.floor(size.line.medium))
end

local function underline_rect(box, thickness)
    -- CRe returns window-space boxes. Match KOReader's underscore baseline;
    -- a medium line may occupy pixels just below the text box, so dirtying
    -- must use these exact painted rectangles rather than the source boxes.
    return {
        x = math.floor(box.x),
        y = math.floor(box.y + box.h - 1),
        w = math.floor(box.w),
        h = thickness,
    }
end

local function dirty_region(geom, old_rects, new_rects)
    local boxes = {}
    for _, rect in ipairs(old_rects) do
        boxes[#boxes + 1] = rect
    end
    for _, rect in ipairs(new_rects) do
        boxes[#boxes + 1] = rect
    end
    if #boxes == 0 then
        return nil
    end
    return geom.boundingBox(boxes)
end

function UnderlineOverlay.new(first, second)
    local options = second or first or {}
    local dependencies = options.dependencies or {}
    local ui = options.ui
    local view = options.view

    local blitbuffer = dependencies.Blitbuffer or require("ffi/blitbuffer")
    local geom = dependencies.Geom or require("ui/geometry")
    local size = dependencies.Size or require("ui/size")
    local ui_manager = dependencies.UIManager or require("ui/uimanager")

    return setmetatable({
        active = true,
        cache_valid = true,
        boxes = {},
        rects = {},
        mode = (options.mode == "underline" or options.mode == "off") and options.mode or "margin",
        dialog = options.dialog or (ui and ui.dialog) or (view and view.dialog),
        document = options.document or (ui and ui.document) or (view and view.document),
        geom = geom,
        blitbuffer = blitbuffer,
        size = size,
        ui = ui,
        ui_manager = ui_manager,
        view = view,
        name = options.name or "koreadalong_underline",
        pos0 = nil,
        pos1 = nil,
        registered = false,
    }, UnderlineOverlay)
end

function UnderlineOverlay:register(view)
    if not self.active or self.registered then
        return false
    end
    view = view or self.view
    if not view or type(view.registerViewModule) ~= "function" then
        return false
    end
    self.view = view
    view:registerViewModule(self.name, self)
    self.registered = true
    return true
end

function UnderlineOverlay:_painted_rects(boxes)
    local rects = {}
    local thickness = line_thickness(self.size)
    if self.mode == "underline" then
        for index, box in ipairs(boxes) do
            rects[index] = underline_rect(box, thickness)
        end
    elseif self.mode == "margin" and #boxes > 0 then
        local margins = self.document:getPageMargins()
        local offsets = { 0 }
        if self.document:getVisiblePageCount() > 1 then
            local page = self.document:getCurrentPage(true)
            offsets[2] = self.document:getPageOffsetX(page + 1)
        end
        for index, offset in ipairs(offsets) do
            local top, bottom
            for _, box in ipairs(boxes) do
                if box.x >= offset and (not offsets[index + 1] or box.x < offsets[index + 1]) then
                    top = math.min(top or box.y, box.y)
                    bottom = math.max(bottom or box.y + box.h, box.y + box.h)
                end
            end
            -- Keep the bar at the text column's margin, even for indented
            -- paragraphs or ranges starting mid-line. Never paint over text
            -- when the reader has removed the page margin entirely.
            local gap = math.min(self.size.padding.default, margins.left - thickness)
            if top and gap >= 0 then
                rects[#rects + 1] = {
                    x = math.floor(offset + margins.left - gap - thickness),
                    y = math.floor(top),
                    w = thickness,
                    h = math.ceil(bottom) - math.floor(top),
                }
            end
        end
    end
    return rects
end

function UnderlineOverlay:_replace_boxes(new_boxes)
    local old_rects = self.rects
    local new_rects = self:_painted_rects(new_boxes)
    self.boxes = new_boxes
    self.rects = new_rects
    self.cache_valid = true
    if not boxes_equal(old_rects, new_rects) then
        local region = dirty_region(self.geom, old_rects, new_rects)
        if region and self.ui_manager and type(self.ui_manager.setDirty) == "function" then
            self.ui_manager:setDirty(self.dialog, "ui", region)
        end
    end
end

function UnderlineOverlay:setMode(mode)
    if not self.active or (mode ~= "margin" and mode ~= "underline" and mode ~= "off") then
        return false
    end
    self.mode = mode
    if self.cache_valid then
        self:_replace_boxes(self.boxes)
    end
    return true
end

function UnderlineOverlay:clear()
    self.pos0 = nil
    self.pos1 = nil
    self:_replace_boxes({})
end

function UnderlineOverlay:invalidate()
    if self.active then
        self:_replace_boxes({})
        self.cache_valid = false
    end
end

function UnderlineOverlay:setRange(pos0, pos1)
    if not self.active then
        return false
    end
    if not valid_pointer(pos0) or not valid_pointer(pos1) then
        self:clear()
        return false
    end
    if self.pos0 == pos0 and self.pos1 == pos1 and self.cache_valid then
        return true
    end

    self.pos0 = pos0
    self.pos1 = pos1
    self:refresh()
    return true
end

function UnderlineOverlay:refresh()
    if not self.active then
        return false
    end

    local new_boxes = {}
    if valid_pointer(self.pos0) and valid_pointer(self.pos1)
        and UnderlineOverlay.isRangeVisible(self.document, self.pos0, self.pos1) then
        local boxes_ok, boxes = invoke(
            self.document,
            "getScreenBoxesFromPositions",
            self.pos0,
            self.pos1,
            true
        )
        if boxes_ok then
            new_boxes = normalize_boxes(boxes)
        end
    end

    self:_replace_boxes(new_boxes)
    return true
end

function UnderlineOverlay:paintTo(bb, _x, _y)
    if not self.active then
        return
    end

    for _, rect in ipairs(self.rects) do
        bb:paintRect(
            rect.x,
            rect.y,
            rect.w,
            rect.h,
            self.blitbuffer.COLOR_BLACK
        )
    end
end

function UnderlineOverlay:deactivate()
    if self.active then
        self:clear()
    end
    self.active = false
end

return UnderlineOverlay
