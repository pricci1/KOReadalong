-- Shared text resolution for local playback and remote, text-only following.
-- This module never owns audio, navigation, saved progress, or screen geometry.
local NarrationRanges = {}
NarrationRanges.__index = NarrationRanges

function NarrationRanges.new(options)
    return setmetatable({
        clips = options.clips,
        document = options.document,
        resolver = options.resolver,
        cache = options.cache or {},
    }, NarrationRanges)
end

function NarrationRanges:nextClip(index)
    local clip = self.clips[index]
    for next_index = index + 1, #self.clips do
        local candidate = self.clips[next_index]
        if not clip or clip.spine_index ~= candidate.spine_index
            or clip.text_path ~= candidate.text_path then
            return nil
        end
        if candidate.text_fragment ~= clip.text_fragment then
            return candidate
        end
    end
end

function NarrationRanges:get(index)
    local cached = self.cache[index]
    if cached == false then
        return nil
    elseif cached then
        return cached
    end
    local method = self.resolver and self.resolver.resolve
    if type(method) ~= "function" then
        return nil, "fragment resolver is missing resolve"
    end
    local ok, range, err = pcall(method, self.document, self.clips[index], self:nextClip(index))
    if not ok then
        err, range = tostring(range), nil
    end
    if type(range) ~= "table" or type(range.pos0) ~= "string"
        or type(range.pos1) ~= "string" then
        -- Unsupported targets must not interrupt audio or flood the reader.
        self.cache[index] = false
        return nil, err
    end
    self.cache[index] = { pos0 = range.pos0, pos1 = range.pos1 }
    return self.cache[index]
end

return NarrationRanges
