package.path = "./koreadalong.koplugin/?.lua;" .. package.path

local MediaOverlays = require("mediaoverlays")
local Timeline = require("timeline")

local OPF = [[
<package xmlns="http://www.idpf.org/2007/opf">
    <manifest>
        <item id="chapter" href="text/chapter.xhtml" media-type="application/xhtml+xml" media-overlay="chapter-mo"/>
        <item id="chapter-mo" href="media/chapter.smil" media-type="application/smil+xml"/>
        <item id="other" href="text/other.xhtml" media-type="application/xhtml+xml" media-overlay="other-mo"/>
        <item id="other-mo" href="media/other.smil" media-type="application/smil+xml"/>
        <item id="cover" href="text/cover.xhtml" media-type="application/xhtml+xml"/>
    </manifest>
    <spine>
        <itemref idref="other"/>
        <itemref idref="cover"/>
        <itemref idref="chapter"/>
    </spine>
</package>
]]

local CHAPTER_SMIL = [[
<smil xmlns="http://www.w3.org/ns/SMIL">
    <body>
        <seq>
            <par>
                <text src="../text/chapter.xhtml%23first"/>
                <audio src="../audio/part-one.mp3" clipBegin="00:00:01.500" clipEnd="2s"/>
            </par>
            <seq>
                <par>
                    <text src="../text/chapter.xhtml#second"/>
                    <audio src="../audio/part-one.mp3" clipBegin="2" clipEnd="2.5"/>
                </par>
                <par>
                    <text src="../text/chapter.xhtml#third"/>
                    <audio src="../audio/part-two.mp3" clipBegin="500ms" clipEnd="1min"/>
                </par>
            </seq>
        </seq>
    </body>
</smil>
]]

local OTHER_SMIL = [[
<smil><body><seq><par>
    <text src="../text/other.xhtml#only"/>
    <audio src="../audio/other.mp3" clipBegin="1:02.25" clipEnd="1:03"/>
</par></seq></body></smil>
]]

local function parse_fixture(smil)
    return MediaOverlays.parse(OPF, "book/package.opf", {
        ["book/media/chapter.smil"] = smil or CHAPTER_SMIL,
        ["book/media/other.smil"] = OTHER_SMIL,
    })
end

describe("SMIL clock values", function()
    it("parses colon, numeric, and unit forms", function()
        assert.are.equal(3723.25, MediaOverlays.parse_clock("01:02:03.25"))
        assert.are.equal(62.5, MediaOverlays.parse_clock("1:02.5"))
        assert.are.equal(12.75, MediaOverlays.parse_clock("12.75"))
        assert.are.equal(3600, MediaOverlays.parse_clock("1h"))
        assert.are.equal(120, MediaOverlays.parse_clock("2min"))
        assert.are.equal(3.5, MediaOverlays.parse_clock("3.5s"))
        assert.are.equal(0.25, MediaOverlays.parse_clock("250ms"))
    end)

    it("rejects malformed clocks with a useful error", function()
        local value, error_message = MediaOverlays.parse_clock("1:75")
        assert.is_nil(value)
        assert.matches("outside 0%.%.59", error_message)
        value, error_message = MediaOverlays.parse_clock("fast")
        assert.is_nil(value)
        assert.matches("invalid SMIL clock value", error_message)
    end)
end)

describe("EPUB media overlays", function()
    it("maps manifest overlays and traverses nested sequences in order", function()
        local clips, error_message = parse_fixture()
        assert.is_nil(error_message)
        assert.are.equal(4, #clips)

        assert.are.same({
            text_path = "book/text/other.xhtml",
            text_fragment = "only",
            audio_path = "book/audio/other.mp3",
            clip_begin = 62.25,
            clip_end = 63,
        }, clips[1])
        assert.are.same({
            text_path = "book/text/chapter.xhtml",
            text_fragment = "first",
            audio_path = "book/audio/part-one.mp3",
            clip_begin = 1.5,
            clip_end = 2,
        }, clips[2])
        assert.are.equal("second", clips[3].text_fragment)
        assert.are.equal("book/audio/part-two.mp3", clips[4].audio_path)
    end)

    it("normalizes relative paths without a ZIP-root assumption", function()
        local path, fragment = MediaOverlays.resolve_path(
            "novel/content/media/chapter.smil",
            "../../audio/../text/./chapter.xhtml%23sentence"
        )
        assert.are.equal("novel/text/chapter.xhtml", path)
        assert.are.equal("sentence", fragment)

        path, fragment = MediaOverlays.resolve_path(
            "novel/content/media/chapter.smil",
            "../../../audio/track.mp3"
        )
        assert.are.equal("audio/track.mp3", path)
        assert.is_nil(fragment)

        path, fragment = MediaOverlays.resolve_path(
            "novel/content/media/chapter.smil",
            "../../../../audio/track.mp3"
        )
        assert.is_nil(path)
        assert.matches("escapes EPUB ZIP root", fragment)
    end)

    it("rejects a par missing a required field", function()
        local malformed = CHAPTER_SMIL:gsub("clipEnd=\"2s\"", "")
        local clips, error_message = parse_fixture(malformed)
        assert.is_nil(clips)
        assert.matches("missing clipEnd", error_message)
    end)

    it("rejects invalid spine references for overlays", function()
        local invalid_opf = OPF:gsub('<itemref idref="chapter"/>', '<itemref idref="missing"/>')
        local clips, error_message = MediaOverlays.parse(
            invalid_opf,
            "book/package.opf",
            {
                ["book/media/chapter.smil"] = CHAPTER_SMIL,
                ["book/media/other.smil"] = OTHER_SMIL,
            }
        )
        assert.is_nil(clips)
        assert.matches("missing manifest item", error_message)
    end)
end)

describe("media overlay timeline", function()
    local clips = {
        { audio_path = "one.mp3", text_fragment = "one", clip_begin = 0, clip_end = 1 },
        { audio_path = "two.mp3", text_fragment = "other", clip_begin = 0, clip_end = 1 },
        { audio_path = "one.mp3", text_fragment = "two", clip_begin = 1, clip_end = 2 },
        { audio_path = "one.mp3", text_fragment = "three", clip_begin = 3, clip_end = 4 },
    }
    local timeline, timeline_error = Timeline.new(clips)

    it("indexes each audio resource with half-open binary-search lookup", function()
        assert.is_nil(timeline_error)
        assert.is_nil(timeline:lookup("one.mp3", -0.01))
        assert.are.equal("one", timeline:lookup("one.mp3", 0).text_fragment)
        assert.are.equal("two", timeline:lookup("one.mp3", 1).text_fragment)
        assert.is_nil(timeline:lookup("one.mp3", 2))
        assert.are.equal("three", timeline:lookup("one.mp3", 3).text_fragment)
        assert.is_nil(timeline:lookup("one.mp3", 4))
        assert.are.equal("other", timeline:lookup("two.mp3", 0).text_fragment)
        assert.is_nil(timeline:lookup("unknown.mp3", 0))
    end)

    it("rejects non-monotonic clips within one resource", function()
        local invalid_timeline, error_message = Timeline.new({
            { audio_path = "one.mp3", clip_begin = 2, clip_end = 3 },
            { audio_path = "one.mp3", clip_begin = 1, clip_end = 2 },
        })
        assert.is_nil(invalid_timeline)
        assert.matches("non%-monotonic", error_message)
    end)
end)
