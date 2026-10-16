package.path = "./koreadalong.koplugin/?.lua;" .. package.path

local UnderlineOverlay = require("underlineoverlay")

local function bounding_box(boxes)
    if #boxes == 0 then
        return nil
    end
    local x0, y0 = boxes[1].x, boxes[1].y
    local x1 = boxes[1].x + boxes[1].w
    local y1 = boxes[1].y + boxes[1].h
    for index = 2, #boxes do
        local box = boxes[index]
        x0 = math.min(x0, box.x)
        y0 = math.min(y0, box.y)
        x1 = math.max(x1, box.x + box.w)
        y1 = math.max(y1, box.y + box.h)
    end
    return { x = x0, y = y0, w = x1 - x0, h = y1 - y0 }
end

local function clear_table(value)
    for key in pairs(value) do
        value[key] = nil
    end
end

local function make_fixture(config)
    config = config or {}
    local dirty = {}
    local queries = {}
    local paints = {}
    local visible = config.visible or {}
    local document = {
        annotation = {},
        annotation_calls = 0,
    }
    function document:addAnnotation()
        self.annotation_calls = self.annotation_calls + 1
        error("persistent annotations are not allowed")
    end
    function document:isXPointerInCurrentPage(pointer)
        return visible[pointer] == true
    end
    function document:getScreenBoxesFromPositions(pos0, pos1, get_segments)
        queries[#queries + 1] = {
            pos0 = pos0,
            pos1 = pos1,
            get_segments = get_segments,
        }
        if config.boxes then
            return config.boxes(pos0, pos1)
        end
        return {}
    end

    local ui_manager = {
        setDirty = function(_, dialog, mode, region)
            dirty[#dirty + 1] = {
                dialog = dialog,
                mode = mode,
                region = region,
            }
        end,
    }
    local view = {
        registerViewModule = function(self, name, widget)
            self.register_count = (self.register_count or 0) + 1
            self.registered_name = name
            self.registered_widget = widget
        end,
    }
    local blitbuffer = { COLOR_BLACK = "black" }
    local size = { line = { medium = 2 } }
    local overlay = UnderlineOverlay.new{
        dependencies = {
            Blitbuffer = blitbuffer,
            Geom = { boundingBox = bounding_box },
            Size = size,
            UIManager = ui_manager,
        },
        dialog = "reader-dialog",
        document = document,
        view = view,
    }
    local bb = {
        paintRect = function(_, x, y, w, h, color)
            paints[#paints + 1] = { x = x, y = y, w = w, h = h, color = color }
        end,
    }
    return overlay, document, view, dirty, queries, paints, bb
end

describe("ephemeral read-along underline overlay", function()
    it("registers its view module only once", function()
        local overlay, _, view = make_fixture()
        assert.is_true(overlay:register())
        assert.is_false(overlay:register())
        assert.are.equal(1, view.register_count)
        assert.are.equal("koreadalong_underline", view.registered_name)
        assert.are.equal(overlay, view.registered_widget)
    end)

    it("derives boxes when either range endpoint is visible", function()
        local overlay, _, _, _, queries = make_fixture{
            visible = { p0 = false, p1 = true },
            boxes = function()
                return { { x = 1, y = 2, w = 10, h = 12 } }
            end,
        }
        overlay:setRange("p0", "p1")
        assert.are.equal(1, #queries)
        assert.are.same({ pos0 = "p0", pos1 = "p1", get_segments = true }, queries[1])
        assert.are.same({ { x = 1, y = 2, w = 10, h = 12 } }, overlay.boxes)
    end)

    it("underlines middle pages of a passage even when neither endpoint is visible", function()
        local overlay, document = make_fixture{
            boxes = function()
                return { { x = 8, y = 20, w = 90, h = 16 } }
            end,
        }
        local page = 4
        function document:getCurrentPage()
            return page
        end
        function document:getPageFromXPointer(pointer)
            return pointer == "p0" and 3 or 6
        end
        for _, current_page in ipairs{ 4, 5, 2, 7 } do
            page = current_page
            overlay:setRange("p0", "p1")
            overlay:refresh()
            local on_passage = page == 4 or page == 5
            assert.are.equal(on_passage, UnderlineOverlay.isRangeVisible(document, "p0", "p1"))
            assert.are.same(on_passage and { { x = 8, y = 20, w = 90, h = 16 } } or {}, overlay.boxes)
        end
    end)

    it("clears boxes when a valid range is off-page", function()
        local overlay, _, _, dirty = make_fixture{
            visible = { p0 = true, p1 = true },
            boxes = function()
                return { { x = 2, y = 3, w = 10, h = 12 } }
            end,
        }
        overlay:setRange("p0", "p1")
        clear_table(dirty)
        overlay.document.isXPointerInCurrentPage = function()
            return false
        end
        overlay:refresh()
        assert.are.same({}, overlay.boxes)
        assert.are.equal(1, #dirty)
        assert.are.same({ x = 2, y = 14, w = 10, h = 2 }, dirty[1].region)
    end)

    it("clears old display for nil and invalid ranges", function()
        local overlay, _, _, dirty = make_fixture{
            visible = { p0 = true, p1 = true },
            boxes = function()
                return { { x = 2, y = 3, w = 10, h = 12 } }
            end,
        }
        overlay:setRange("p0", "p1")
        clear_table(dirty)
        overlay:setRange(nil, "p1")
        assert.is_nil(overlay.pos0)
        assert.is_nil(overlay.pos1)
        assert.are.same({}, overlay.boxes)
        assert.are.equal(1, #dirty)

        clear_table(dirty)
        overlay:setRange("", "p1")
        assert.are.same({}, overlay.boxes)
        assert.are.equal(0, #dirty)
    end)

    it("dirties the union of old and new painted line regions", function()
        local current_boxes = { { x = 1, y = 2, w = 3, h = 4 } }
        local overlay, _, _, dirty, _, paints, bb = make_fixture{
            visible = { old0 = true, old1 = true, new0 = true, new1 = true },
            boxes = function(pos0)
                if pos0 == "old0" then
                    return current_boxes
                end
                return { { x = 10, y = 20, w = 5, h = 6 } }
            end,
        }
        overlay:setRange("old0", "old1")
        clear_table(dirty)
        overlay:paintTo(bb, 100, 200)
        local old_line = paints[1]
        clear_table(paints)
        overlay:setRange("new0", "new1")
        overlay:paintTo(bb, 100, 200)
        local new_line = paints[1]
        assert.are.equal(1, #dirty)
        assert.are.same({ x = 1, y = 5, w = 14, h = 22 }, dirty[1].region)
        assert.is_true(
            dirty[1].region.x <= old_line.x
                and dirty[1].region.y <= old_line.y
                and dirty[1].region.x + dirty[1].region.w
                    >= old_line.x + old_line.w
                and dirty[1].region.y + dirty[1].region.h
                    >= old_line.y + old_line.h
        )
        assert.is_true(
            dirty[1].region.x <= new_line.x
                and dirty[1].region.y <= new_line.y
                and dirty[1].region.x + dirty[1].region.w
                    >= new_line.x + new_line.w
                and dirty[1].region.y + dirty[1].region.h
                    >= new_line.y + new_line.h
        )
    end)

    it("does not dirty an empty unchanged cache", function()
        local overlay, _, _, dirty = make_fixture{
            visible = { p0 = false, p1 = false },
        }
        overlay:setRange("p0", "p1")
        overlay:refresh()
        assert.are.equal(0, #dirty)
    end)

    it("paints exact black screen-coordinate rectangles without offsets", function()
        local overlay, _, _, _, _, paints, bb = make_fixture{
            visible = { p0 = true, p1 = true },
            boxes = function()
                return { { x = 3, y = 4, w = 20, h = 10 } }
            end,
        }
        overlay:setRange("p0", "p1")
        overlay:paintTo(bb, 100, 200)
        assert.are.same({ x = 3, y = 13, w = 20, h = 2, color = "black" }, paints[1])
    end)

    it("fails closed for invalid box results", function()
        local overlay, _, _, dirty, _, paints, bb = make_fixture{
            visible = { p0 = true, p1 = false },
            boxes = function()
                return { { x = 1, y = 2, w = nil, h = 4 } }
            end,
        }
        overlay:setRange("p0", "p1")
        overlay:paintTo(bb, 0, 0)
        assert.are.same({}, overlay.boxes)
        assert.are.equal(0, #dirty)
        assert.are.equal(0, #paints)
    end)

    it("suppresses stale boxes during partial rerender until refresh", function()
        local overlay, _, _, dirty, queries, _, bb = make_fixture{
            visible = { p0 = true, p1 = true },
            boxes = function()
                return { { x = 1, y = 2, w = 10, h = 12 } }
            end,
        }
        overlay:setRange("p0", "p1")
        clear_table(dirty)
        clear_table(queries)
        overlay:invalidate()
        overlay:paintTo(bb, 0, 0)
        assert.are.same({}, overlay.boxes)
        assert.are.equal(0, #queries)
        assert.are.equal(1, #dirty)
        overlay:refresh()
        assert.are.equal(1, #queries)
        assert.are.equal(1, #overlay.boxes)
    end)

    it("recomputes a repeated range after cache invalidation", function()
        local overlay, _, _, _, queries = make_fixture{
            visible = { p0 = true, p1 = true },
            boxes = function()
                return { { x = 1, y = 2, w = 10, h = 12 } }
            end,
        }
        overlay:setRange("p0", "p1")
        overlay:invalidate()
        clear_table(queries)
        overlay:setRange("p0", "p1")
        assert.are.equal(1, #queries)
    end)

    it("cannot paint or refresh after close", function()
        local overlay, _, _, dirty, queries, _, bb = make_fixture{
            visible = { p0 = true, p1 = true },
            boxes = function()
                return { { x = 1, y = 2, w = 10, h = 12 } }
            end,
        }
        overlay:setRange("p0", "p1")
        overlay:register()
        overlay:deactivate()
        local query_count = #queries
        local dirty_count = #dirty
        overlay:setRange("p0", "p1")
        overlay:refresh()
        overlay:paintTo(bb, 0, 0)
        assert.is_false(overlay.active)
        assert.are.equal(query_count, #queries)
        assert.are.equal(dirty_count, #dirty)
    end)

    it("does not touch persistent annotation APIs", function()
        local overlay, document = make_fixture{
            visible = { p0 = true, p1 = true },
            boxes = function()
                return { { x = 1, y = 2, w = 10, h = 12 } }
            end,
        }
        overlay:setRange("p0", "p1")
        assert.is_table(document.annotation)
        assert.is_function(document.addAnnotation)
        assert.are.equal(0, document.annotation_calls)
    end)
end)
