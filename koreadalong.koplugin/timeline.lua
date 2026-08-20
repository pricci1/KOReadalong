local Timeline = {}
Timeline.__index = Timeline

function Timeline.new(clips)
    assert(type(clips) == "table", "Timeline clips must be a table")
    return setmetatable({ clips = clips }, Timeline)
end

-- Clip intervals are half-open: [clip_begin, clip_end).
-- At an exact shared boundary, the following clip is selected; gaps return nil.
function Timeline:lookup(playback_time)
    if type(playback_time) ~= "number" or playback_time ~= playback_time then
        return nil
    end
    local low = 1
    local high = #self.clips
    local candidate
    while low <= high do
        local middle = math.floor((low + high) / 2)
        if self.clips[middle].clip_begin <= playback_time then
            candidate = middle
            low = middle + 1
        else
            high = middle - 1
        end
    end
    if candidate then
        local clip = self.clips[candidate]
        if playback_time < clip.clip_end then
            return clip
        end
    end
    return nil
end

return Timeline
