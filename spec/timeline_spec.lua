package.path = "./koreadalong.koplugin/?.lua;" .. package.path
local Timeline = require("timeline")

describe("overlay book progress", function()
    local timeline
    before_each(function()
        timeline = assert(Timeline.new{
            { audio_path = "a", clip_begin = 11, clip_end = 14, spine_index = 3,
                text_fragment = "repeated" },
            { audio_path = "a", clip_begin = 14, clip_end = 18, spine_index = 3,
                text_fragment = "repeated" },
            { audio_path = "a", clip_begin = 23, clip_end = 31, spine_index = 5 },
            { audio_path = "b", clip_begin = 7, clip_end = 9, spine_index = 7 },
            { audio_path = "b", clip_begin = 9, clip_end = 12, spine_index = 8 },
        })
    end)

    it("counts each asymmetric resource extent once, not clips or chapters", function()
        -- A spans 11..31 = 20, B spans 7..12 = 5. Clips sum to 20,
        -- while counting a full resource for every chapter would give 50.
        local position, duration, chapter, count = timeline:getBookProgress("b", 10)
        assert.are.equal(23, position)
        assert.are.equal(25, duration)
        assert.are.equal(4, chapter)
        assert.are.equal(4, count)
    end)

    it("keeps gaps on the audio clock without inventing a chapter", function()
        local position, duration, chapter = timeline:getBookProgress("a", 20)
        assert.are.equal(9, position)
        assert.are.equal(25, duration)
        assert.is_nil(chapter)
        assert.are.equal(0, timeline:getBookProgress("a", 0))
        assert.are.equal(20, timeline:getBookProgress("a", 50))
        assert.are.equal(20, timeline:getBookProgress("b", 7))
    end)

    it("orders resources by first appearance, not path name", function()
        local ordered = assert(Timeline.new{
            { audio_path = "z", clip_begin = 4, clip_end = 9 },
            { audio_path = "a", clip_begin = 2, clip_end = 13 },
        })
        local position, duration = ordered:getBookProgress("a", 5)
        assert.are.equal(8, position) -- preceding 5 + current (5 - 2)
        assert.are.equal(16, duration)
    end)

    it("does not fabricate elapsed time for an unknown resource or clock", function()
        assert.is_nil(timeline:getBookProgress(nil, nil))
        assert.is_nil(timeline:getBookProgress("missing", 10))
        assert.is_nil(timeline:getBookProgress("a", 0/0))
        assert.is_nil(timeline:getBookProgress("a", math.huge))
        assert.is_nil(timeline:getBookProgress("a", -math.huge))
    end)
end)
