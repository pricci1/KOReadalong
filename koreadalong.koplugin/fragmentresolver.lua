local FragmentResolver = {}

local DEFAULT_MAX_STEPS = 4096

local function error_message(category)
    return "fragment resolver: " .. category
end

local function invoke(document, method_name, ...)
    local method = document[method_name]
    if type(method) ~= "function" then
        return false, error_message("document is missing " .. method_name)
    end
    local ok, first, second = pcall(method, document, ...)
    if not ok then
        return false, error_message("document method " .. method_name .. " failed")
    end
    return true, first, second
end

local function valid_pointer(pointer)
    return type(pointer) == "string" and pointer ~= ""
end

local function validate_clip(clip)
    if type(clip) ~= "table" then
        return nil, error_message("malformed clip")
    end
    if type(clip.spine_index) ~= "number"
        or clip.spine_index ~= math.floor(clip.spine_index)
        or clip.spine_index < 0
        or clip.spine_index >= math.huge then
        return nil, error_message("malformed clip spine_index")
    end
    if type(clip.text_fragment) ~= "string" or clip.text_fragment == "" then
        return nil, error_message("malformed clip text_fragment")
    end
    local lower_fragment = clip.text_fragment:lower()
    if clip.text_fragment:find("#", 1, true)
        or lower_fragment:find(":~:text=", 1, true)
        or lower_fragment:find("%3a~%3atext%3d", 1, true)
        or clip.text_fragment:find("%s") then
        return nil, error_message("unsupported target fragment")
    end
    return true
end

local function validate_document(document)
    local document_type = type(document)
    if document_type ~= "table" and document_type ~= "userdata" then
        return nil, error_message("invalid document")
    end
    for _, method_name in ipairs({
        "isXPointerInDocument",
        "getTextFromXPointer",
        "getNextVisibleChar",
        "getTextFromXPointers",
        "compareXPointers",
    }) do
        if type(document[method_name]) ~= "function" then
            return nil, error_message("document is missing " .. method_name)
        end
    end
    return true
end

local function require_anchor(document, anchor, description)
    local ok, in_document = invoke(
        document,
        "isXPointerInDocument",
        anchor
    )
    if not ok then
        return nil, in_document
    end
    if type(in_document) ~= "boolean" then
        return nil, error_message("invalid document result from isXPointerInDocument")
    end
    if not in_document then
        return nil, error_message(description .. " anchor is not in document")
    end
    return true
end

local function compare(document, left, right)
    -- CRe returns 1 when the right pointer follows the left pointer.
    local ok, result = invoke(
        document,
        "compareXPointers",
        left,
        right
    )
    if not ok then
        return nil, result
    end
    if type(result) ~= "number"
        or (result ~= -1 and result ~= 0 and result ~= 1) then
        return nil, error_message("invalid compare result")
    end
    return result
end

local function option_max_steps(options)
    if options == nil then
        return DEFAULT_MAX_STEPS
    end
    if type(options) ~= "table" then
        return nil, error_message("invalid options")
    end
    if options.max_steps == nil then
        return DEFAULT_MAX_STEPS
    end
    if type(options.max_steps) ~= "number"
        or options.max_steps ~= math.floor(options.max_steps)
        or options.max_steps < 1
        or options.max_steps > DEFAULT_MAX_STEPS then
        return nil, error_message("invalid max_steps option")
    end
    return options.max_steps
end

function FragmentResolver.resolve(document, clip, next_clip, options)
    local valid_clip, clip_error = validate_clip(clip)
    if not valid_clip then
        return nil, clip_error
    end
    local valid_document, document_error = validate_document(document)
    if not valid_document then
        return nil, document_error
    end
    local max_steps, options_error = option_max_steps(options)
    if not max_steps then
        return nil, options_error
    end

    local anchor = "#_doc_fragment_" .. clip.spine_index
        .. "_" .. clip.text_fragment
    local anchor_ok, anchor_error = require_anchor(document, anchor, "target")
    if not anchor_ok then
        return nil, anchor_error
    end

    local text_ok, target_text = invoke(
        document,
        "getTextFromXPointer",
        anchor
    )
    if not text_ok then
        return nil, target_text
    end
    if type(target_text) ~= "string" then
        return nil, error_message("invalid target text")
    end
    if not target_text:match("%S") then
        return nil, error_message("target text is empty or whitespace")
    end

    local next_anchor
    if next_clip ~= nil then
        local valid_next_clip, next_clip_error = validate_clip(next_clip)
        if not valid_next_clip then
            return nil, error_message("malformed next clip") .. ": " .. next_clip_error
        end
        next_anchor = "#_doc_fragment_" .. next_clip.spine_index
            .. "_" .. next_clip.text_fragment
        local next_ok, next_error = require_anchor(
            document,
            next_anchor,
            "next target"
        )
        if not next_ok then
            return nil, next_error
        end
        local next_order, next_order_error = compare(document, anchor, next_anchor)
        if not next_order then
            return nil, next_order_error
        end
        if next_order ~= 1 then
            return nil, error_message("invalid next-target ordering")
        end
    end

    local pos0_ok, pos0 = invoke(
        document,
        "getNextVisibleChar",
        anchor
    )
    if not pos0_ok then
        return nil, pos0
    end
    if not valid_pointer(pos0) then
        return nil, error_message("invalid pointer from getNextVisibleChar")
    end
    if next_anchor then
        local pos0_order, pos0_order_error = compare(document, pos0, next_anchor)
        if not pos0_order then
            return nil, pos0_order_error
        end
        if pos0_order ~= 1 then
            return nil, error_message("next target boundary precedes current target")
        end
    end

    local previous = pos0
    local recovered_text = ""
    local steps = 0
    while true do
        if steps >= max_steps then
            return nil, error_message("resolution step cap exceeded")
        end
        local pos1_ok, pos1 = invoke(
            document,
            "getNextVisibleChar",
            previous
        )
        if not pos1_ok then
            return nil, pos1
        end
        if not valid_pointer(pos1) then
            return nil, error_message("invalid pointer from getNextVisibleChar")
        end
        local pointer_order, pointer_order_error = compare(document, previous, pos1)
        if not pointer_order then
            return nil, pointer_order_error
        end
        if pointer_order ~= 1 then
            return nil, error_message("next visible pointer did not advance")
        end
        if next_anchor then
            local boundary_order, boundary_error = compare(
                document,
                pos1,
                next_anchor
            )
            if not boundary_order then
                return nil, boundary_error
            end
            if boundary_order ~= 1 then
                return nil, error_message("next target boundary reached or crossed")
            end
        end

        local range_ok, range_text = invoke(
            document,
            "getTextFromXPointers",
            pos0,
            pos1
        )
        if not range_ok then
            return nil, range_text
        end
        if type(range_text) ~= "string" then
            return nil, error_message("invalid recovered range text")
        end
        if target_text:sub(1, #range_text) ~= range_text then
            return nil, error_message("recovered range text is not a byte-prefix")
        end
        if #range_text <= #recovered_text then
            return nil, error_message("recovered range text did not advance")
        end
        recovered_text = range_text
        steps = steps + 1
        if recovered_text == target_text then
            return {
                pos0 = pos0,
                pos1 = pos1,
                anchor = anchor,
            }
        end
        previous = pos1
    end
end

return FragmentResolver
