package.path = "./koreadalong.koplugin/?.lua;" .. package.path

local NarrationState = require("narrationstate")

local function make_settings(initial)
    local settings = {
        data = initial or {},
        flushes = 0,
    }
    function settings:readSetting(key)
        return self.data[key]
    end
    function settings:saveSetting(key, value)
        self.data[key] = value
    end
    function settings:delSetting(key)
        self.data[key] = nil
    end
    function settings:flush()
        self.flushes = self.flushes + 1
    end
    return settings
end

local CLIPS = {
    {
        text_path = "book/chapter.xhtml",
        text_fragment = "one",
        spine_index = 0,
        audio_path = "book/first.wav",
        clip_begin = 0,
        clip_end = 1,
    },
    {
        text_path = "book/next.xhtml",
        text_fragment = "two",
        spine_index = 2,
        audio_path = "book/second.wav",
        clip_begin = 0.25,
        clip_end = 1.5,
    },
}

describe("durable narration state", function()
    it("round-trips clip identity and XPointers through book settings", function()
        local settings = make_settings()
        local state = NarrationState.new{
            settings = settings,
            clips = CLIPS,
        }

        assert.is_true(state:save{
            clip = CLIPS[2],
            pos0 = "/body/p[2]/text()[1]",
            pos1 = "/body/p[2]/text()[1]:end",
            position = 0.75,
        })
        assert.are.equal(1, settings.flushes)
        assert.is_nil(settings.data[NarrationState.KEY].screen_x)
        assert.is_nil(settings.data[NarrationState.KEY].screen_y)

        local reopened = NarrationState.new{
            settings = settings,
            clips = CLIPS,
        }
        local saved = assert(reopened:load())
        assert.are.equal(CLIPS[2].text_fragment, saved.clip.text_fragment)
        assert.are.equal("/body/p[2]/text()[1]", saved.pos0)
        assert.are.equal(0.75, saved.position)
    end)

    it("rejects state from a changed clip timeline and clears it durably", function()
        local settings = make_settings()
        local state = NarrationState.new{
            settings = settings,
            clips = CLIPS,
        }
        assert.is_true(state:save{
            clip = CLIPS[1],
            pos0 = "p0",
            pos1 = "p1",
            position = 0.5,
        })

        local changed_clips = {
            CLIPS[1],
            {
                text_path = "book/next.xhtml",
                text_fragment = "changed",
                spine_index = 2,
                audio_path = "book/second.wav",
                clip_begin = 0.25,
                clip_end = 1.5,
            },
        }
        local changed = NarrationState.new{
            settings = settings,
            clips = changed_clips,
        }
        local saved, error_message = changed:load()
        assert.is_nil(saved)
        assert.matches("does not match", error_message)
        assert.is_true(changed:clear())
        assert.is_nil(settings.data[NarrationState.KEY])
        assert.are.equal(2, settings.flushes)
    end)
end)
