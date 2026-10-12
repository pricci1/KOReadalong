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
        <item id="missing-href" media-type="application/octet-stream"/>
        <item id="unsupported" href="misc/unsupported.bin" media-type="application/octet-stream"/>
        <item id="appendix" href="text/appendix.xhtml" media-type="application/xhtml+xml" media-overlay="appendix-mo"/>
        <item id="appendix-mo" href="media/appendix.smil" media-type="application/smil+xml"/>
    </manifest>
    <spine>
        <itemref idref="other"/>
        <itemref idref="cover" linear="no"/>
        <itemref idref="missing-href"/>
        <itemref idref="unsupported"/>
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
    it("follows spine order and ignores overlay documents outside the spine", function()
        local clips, error_message, skipped_clips = parse_fixture()
        assert.is_nil(error_message)
        assert.are.equal(0, skipped_clips)
        assert.are.equal(4, #clips)

        assert.are.same({
            text_path = "book/text/other.xhtml",
            text_fragment = "only",
            audio_path = "book/audio/other.mp3",
            clip_begin = 62.25,
            clip_end = 63,
            spine_index = 0,
        }, clips[1])
        assert.are.same({
            text_path = "book/text/chapter.xhtml",
            text_fragment = "first",
            audio_path = "book/audio/part-one.mp3",
            clip_begin = 1.5,
            clip_end = 2,
            spine_index = 3,
        }, clips[2])
        assert.are.equal("second", clips[3].text_fragment)
        assert.are.equal(3, clips[3].spine_index)
        assert.are.equal("book/audio/part-two.mp3", clips[4].audio_path)
        assert.are.equal(3, clips[4].spine_index)
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

    it("rejects duplicate manifest IDs and XHTML content hrefs", function()
        local duplicate_id = OPF:gsub(
            '<item id="appendix"',
            '<item id="chapter"'
        )
        local clips, error_message = MediaOverlays.parse(
            duplicate_id,
            "book/package.opf",
            {
                ["book/media/chapter.smil"] = CHAPTER_SMIL,
                ["book/media/other.smil"] = OTHER_SMIL,
            }
        )
        assert.is_nil(clips)
        assert.matches("duplicate item id", error_message)

        local duplicate_href = OPF:gsub(
            'href="text/appendix.xhtml"',
            'href="text/chapter.xhtml"'
        )
        clips, error_message = MediaOverlays.parse(
            duplicate_href,
            "book/package.opf",
            {
                ["book/media/chapter.smil"] = CHAPTER_SMIL,
                ["book/media/other.smil"] = OTHER_SMIL,
                ["book/media/appendix.smil"] = CHAPTER_SMIL,
            }
        )
        assert.is_nil(clips)
        assert.matches("duplicate XHTML content href", error_message)
    end)

    it("rejects repeated valid spine itemrefs with duplicate content hrefs", function()
        local repeated = OPF:gsub(
            '<itemref idref="chapter"/>',
            '<itemref idref="other"/><itemref idref="chapter"/>'
        )
        local clips, error_message = MediaOverlays.parse(
            repeated,
            "book/package.opf",
            {
                ["book/media/chapter.smil"] = CHAPTER_SMIL,
                ["book/media/other.smil"] = OTHER_SMIL,
            }
        )
        assert.is_nil(clips)
        assert.matches("duplicate spine content href.*unsupported", error_message)
    end)
end)

describe("EPUB media overlay loading", function()
    local CONTAINER = [[
<container xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
    <rootfiles>
        <rootfile full-path="books/OPS/package.opf" media-type="application/oebps-package+xml"/>
    </rootfiles>
</container>
]]
    local MULTIPLE_ROOTFILES_CONTAINER = [[
<container xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
    <rootfiles>
        <rootfile full-path="books/OPS/not-the-package.xml" media-type="application/xml"/>
        <rootfile full-path="books/OPS/package.opf" media-type="application/oebps-package+xml"/>
    </rootfiles>
</container>
]]
    local LOADER_OPF = [[
<package xmlns="http://www.idpf.org/2007/opf">
    <manifest>
        <item id="chapter" href="text/chapter.xhtml" media-type="application/xhtml+xml" media-overlay="chapter-mo"/>
        <item id="chapter-mo" href="media/chapter.smil" media-type="application/smil+xml"/>
    </manifest>
    <spine><itemref idref="chapter"/></spine>
</package>
]]
    local SMIL = [[
<smil xmlns="http://www.w3.org/ns/SMIL"><body><seq><par>
    <text src="../text/chapter.xhtml#sentence"/>
    <audio src="../audio/chapter.mp3" clipBegin="0" clipEnd="1s"/>
</par></seq></body></smil>
]]

    local function callback_for(entries, requested)
        return function(path)
            requested[#requested + 1] = path
            if entries[path] then
                return entries[path]
            end
            return nil, "missing entry: " .. path
        end
    end

    it("loads a nested package and requests only the required entries", function()
        local requested = {}
        local clips, error_message = MediaOverlays.load(callback_for({
            ["META-INF/container.xml"] = CONTAINER,
            ["books/OPS/package.opf"] = LOADER_OPF,
            ["books/OPS/media/chapter.smil"] = SMIL,
        }, requested))
        assert.is_nil(error_message)
        assert.are.same({
            "META-INF/container.xml",
            "books/OPS/package.opf",
            "books/OPS/media/chapter.smil",
        }, requested)
        assert.are.equal(1, #clips)
        assert.are.equal("books/OPS/text/chapter.xhtml", clips[1].text_path)
        assert.are.equal("books/OPS/audio/chapter.mp3", clips[1].audio_path)
        local timeline, timeline_error = Timeline.new(clips)
        assert.is_nil(timeline_error)
        assert.are.equal(clips[1], timeline:lookup(clips[1].audio_path, 0))
    end)

    it("skips nonpositive intervals without losing a zero-clock resource handoff", function()
        local mixed_smil = [[
<smil><body><seq>
    <par><text src="../text/chapter.xhtml#before"/>
        <audio src="../audio/chapter.mp3" clipBegin="1.25s" clipEnd="2.5s"/></par>
    <par><text src="../text/chapter.xhtml#reversed"/>
        <audio src="../audio/chapter.mp3" clipBegin="1553.880s" clipEnd="1549.003s"/></par>
    <par><text src="../text/chapter.xhtml#after"/>
        <audio src="../audio/next.mp3" clipBegin="0s" clipEnd="3s"/></par>
    <par><text src="../text/chapter.xhtml#empty"/>
        <audio src="../audio/next.mp3" clipBegin="3s" clipEnd="3s"/></par>
</seq></body></smil>
]]
        local clips, error_message, skipped_clips = MediaOverlays.load(callback_for({
            ["META-INF/container.xml"] = CONTAINER,
            ["books/OPS/package.opf"] = LOADER_OPF,
            ["books/OPS/media/chapter.smil"] = mixed_smil,
        }, {}))
        assert.is_nil(error_message)
        assert.are.equal(2, skipped_clips)
        assert.are.same({
            { text_path = "books/OPS/text/chapter.xhtml", text_fragment = "before",
                audio_path = "books/OPS/audio/chapter.mp3", spine_index = 0,
                clip_begin = 1.25, clip_end = 2.5 },
            { text_path = "books/OPS/text/chapter.xhtml", text_fragment = "after",
                audio_path = "books/OPS/audio/next.mp3", spine_index = 0,
                clip_begin = 0, clip_end = 3 },
        }, clips)
        local timeline = assert(Timeline.new(clips))
        assert.are.equal(clips[2], timeline:lookup(clips[2].audio_path, 0))
        local elapsed, duration, chapter, chapter_count = timeline:getBookProgress(
            clips[2].audio_path, 1
        )
        assert.are.same({ 2.25, 4.25, 1, 1 }, { elapsed, duration, chapter, chapter_count })
    end)

    it("returns no playable clips and an aggregate count when all intervals are invalid", function()
        local clips, error_message, skipped_clips = MediaOverlays.parse(
            OPF, "book/package.opf", {
                ["book/media/other.smil"] = OTHER_SMIL:gsub('clipEnd="1:03"', 'clipEnd="1:02.25"'),
                ["book/media/chapter.smil"] = SMIL:gsub('clipEnd="1s"', 'clipEnd="0s"'),
            }
        )
        assert.is_nil(error_message)
        assert.are.same({}, clips)
        assert.are.equal(2, skipped_clips)
    end)

    it("does not turn malformed clocks, missing fields or escaping paths into skipped clips", function()
        for _, case in ipairs{
            { SMIL:gsub('clipEnd="1s"', 'clipEnd="fast"'), "invalid SMIL clock" },
            { SMIL:gsub('clipBegin="0"', ''), "missing clipBegin" },
            { SMIL:gsub('clipEnd="1s"', 'clipEnd="0s"')
                :gsub('../audio/chapter.mp3', '../../../../audio/chapter.mp3'), "escapes EPUB ZIP root" },
            { SMIL:gsub('clipEnd="1s"', 'clipEnd="0s"')
                :gsub('../text/chapter.xhtml', '../../../../text/chapter.xhtml'), "escapes EPUB ZIP root" },
        } do
            local smil = case[1]:gsub("<seq>", [[<seq>
<par><text src="../text/chapter.xhtml#skipped"/>
<audio src="../audio/chapter.mp3" clipBegin="2s" clipEnd="1s"/></par>]])
            local clips, error_message, skipped_clips = MediaOverlays.load(callback_for({
                ["META-INF/container.xml"] = CONTAINER,
                ["books/OPS/package.opf"] = LOADER_OPF,
                ["books/OPS/media/chapter.smil"] = smil,
            }, {}))
            assert.is_nil(clips)
            assert.matches(case[2], error_message)
            assert.is_nil(skipped_clips)
        end
    end)

    it("prefers an EPUB package rootfile media type", function()
        local requested = {}
        local clips, error_message = MediaOverlays.load(callback_for({
            ["META-INF/container.xml"] = MULTIPLE_ROOTFILES_CONTAINER,
            ["books/OPS/package.opf"] = LOADER_OPF,
            ["books/OPS/media/chapter.smil"] = SMIL,
        }, requested))
        assert.is_nil(error_message)
        assert.are.equal(1, #clips)
        assert.are.equal("books/OPS/package.opf", requested[2])
        assert.is_not.equal("books/OPS/not-the-package.xml", requested[2])
    end)

    it("reports a missing container with callback context", function()
        local clips, error_message = MediaOverlays.load(function(path)
            return nil, "entry unavailable: " .. path
        end)
        assert.is_nil(clips)
        assert.matches("unable to read container.*entry unavailable", error_message)
    end)

    it("reports a container with no rootfile", function()
        local clips, error_message = MediaOverlays.load(function(path)
            if path == "META-INF/container.xml" then
                return "<container><rootfiles/></container>"
            end
            return nil, "unexpected read"
        end)
        assert.is_nil(clips)
        assert.matches("container%.xml has no rootfile", error_message)
    end)

    it("reports a rootfile with no full-path", function()
        local clips, error_message = MediaOverlays.load(function(path)
            if path == "META-INF/container.xml" then
                return "<container><rootfiles><rootfile media-type=\"application/oebps-package+xml\"/></rootfiles></container>"
            end
            return nil, "unexpected read"
        end)
        assert.is_nil(clips)
        assert.matches("rootfile is missing full%-path", error_message)
    end)

    it("reports an unreadable OPF and preserves callback detail", function()
        local clips, error_message = MediaOverlays.load(function(path)
            if path == "META-INF/container.xml" then
                return CONTAINER
            end
            return nil, "permission denied"
        end)
        assert.is_nil(clips)
        assert.matches("unable to read OPF.*permission denied", error_message)
    end)

    it("reports an unreadable referenced SMIL", function()
        local clips, error_message = MediaOverlays.load(function(path)
            if path == "META-INF/container.xml" then
                return CONTAINER
            elseif path == "books/OPS/package.opf" then
                return LOADER_OPF
            end
            return nil, "SMIL entry missing"
        end)
        assert.is_nil(clips)
        assert.matches("unable to read SMIL.*SMIL entry missing", error_message)
    end)

    it("rejects a rootfile path that escapes the ZIP root", function()
        local clips, error_message = MediaOverlays.load(function(path)
            if path == "META-INF/container.xml" then
                return "<container><rootfiles><rootfile full-path=\"../package.opf\"/></rootfiles></container>"
            end
            return nil, "unexpected read"
        end)
        assert.is_nil(clips)
        assert.matches("escapes EPUB ZIP root", error_message)
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
