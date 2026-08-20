package.path = "./koreadalong.koplugin/?.lua;" .. package.path

local FragmentResolver = require("fragmentresolver")

local function clip(spine_index, text_fragment)
    return {
        spine_index = spine_index,
        text_fragment = text_fragment,
    }
end

local function fake_document(content, targets, behavior)
    behavior = behavior or {}
    local document = {}
    local target_by_anchor = {}
    for anchor, target in pairs(targets) do
        target_by_anchor[anchor] = target
    end

    local function pointer_order(pointer)
        local position = pointer:match("^p([0-9]+)$")
        if position then
            return tonumber(position)
        end
        local spine_index, text_fragment = pointer:match(
            "^#_doc_fragment_([0-9]+)_(.+)$"
        )
        local target = targets[pointer]
        if spine_index and text_fragment and target then
            return target.start - 0.5
        end
        return nil
    end

    function document:isXPointerInDocument(pointer)
        if behavior.is_in_document then
            return behavior.is_in_document(pointer)
        end
        return target_by_anchor[pointer] ~= nil
    end

    function document:getTextFromXPointer(pointer)
        if behavior.target_text then
            return behavior.target_text(pointer)
        end
        local target = target_by_anchor[pointer]
        return target and target.text
    end

    function document:getNextVisibleChar(pointer)
        if behavior.next_visible_char then
            return behavior.next_visible_char(pointer)
        end
        local target = target_by_anchor[pointer]
        if target then
            return "p" .. target.start
        end
        local position = tonumber(pointer:match("^p([0-9]+)$"))
        if not position then
            return nil
        end
        return "p" .. (position + 1)
    end

    function document:getTextFromXPointers(pos0, pos1)
        if behavior.range_text then
            return behavior.range_text(pos0, pos1)
        end
        local start = tonumber(pos0:match("^p([0-9]+)$"))
        local finish = tonumber(pos1:match("^p([0-9]+)$"))
        if not start or not finish or finish < start then
            return nil
        end
        return content:sub(start, finish - 1)
    end

    function document:compareXPointers(left, right)
        if behavior.compare then
            return behavior.compare(left, right)
        end
        local left_order = pointer_order(left)
        local right_order = pointer_order(right)
        if not left_order or not right_order then
            return nil
        end
        if left_order < right_order then
            return 1
        elseif left_order > right_order then
            return -1
        end
        return 0
    end

    return document
end

describe("Storyteller fragment resolver", function()
    it("resolves one-character, word, and sentence ranges with half-open ends", function()
        local document = fake_document("A word sentence.", {
            ["#_doc_fragment_0_letter"] = { start = 1, text = "A" },
            ["#_doc_fragment_0_word"] = { start = 3, text = "word" },
            ["#_doc_fragment_0_sentence"] = { start = 8, text = "sentence." },
        })

        local result, error_message = FragmentResolver.resolve(
            document,
            clip(0, "letter")
        )
        assert.is_nil(error_message)
        assert.are.same({
            pos0 = "p1",
            pos1 = "p2",
            anchor = "#_doc_fragment_0_letter",
        }, result)

        result, error_message = FragmentResolver.resolve(document, clip(0, "word"))
        assert.is_nil(error_message)
        assert.are.equal("p3", result.pos0)
        assert.are.equal("p7", result.pos1)

        result, error_message = FragmentResolver.resolve(
            document,
            clip(0, "sentence")
        )
        assert.is_nil(error_message)
        assert.are.equal("p8", result.pos0)
        assert.are.equal("p17", result.pos1)
    end)

    it("keeps repeated text distinct through their ID anchors", function()
        local document = fake_document("echo between echo", {
            ["#_doc_fragment_2_first"] = { start = 1, text = "echo" },
            ["#_doc_fragment_2_second"] = { start = 14, text = "echo" },
        })

        local first = FragmentResolver.resolve(document, clip(2, "first"))
        local second = FragmentResolver.resolve(document, clip(2, "second"))
        assert.are.equal("p1", first.pos0)
        assert.are.equal("p5", first.pos1)
        assert.are.equal("p14", second.pos0)
        assert.are.equal("p18", second.pos1)
    end)

    it("uses the next target first visible character as the boundary", function()
        local document = fake_document("hello world", {
            ["#_doc_fragment_0_first"] = { start = 1, text = "hello " },
            ["#_doc_fragment_0_second"] = { start = 7, text = "world" },
        })
        local result, error_message = FragmentResolver.resolve(
            document,
            clip(0, "first"),
            clip(0, "second")
        )
        assert.is_nil(error_message)
        assert.are.equal("p7", result.pos1)

        result, error_message = FragmentResolver.resolve(
            document,
            clip(0, "first"),
            clip(0, "second"),
            { max_steps = 6 }
        )
        assert.is_nil(error_message)
        assert.are.equal("p7", result.pos1)

        document = fake_document("hello world", {
            ["#_doc_fragment_0_first"] = { start = 1, text = "hello world" },
            ["#_doc_fragment_0_second"] = { start = 7, text = "world" },
        })
        result, error_message = FragmentResolver.resolve(
            document,
            clip(0, "first"),
            clip(0, "second")
        )
        assert.is_nil(result)
        assert.matches("next target boundary crossed", error_message)
    end)

    it("fails closed for missing or empty anchors", function()
        local document = fake_document("visible", {
            ["#_doc_fragment_0_visible"] = { start = 1, text = "visible" },
            ["#_doc_fragment_0_empty"] = { start = 1, text = "" },
            ["#_doc_fragment_0_whitespace"] = { start = 1, text = " \n\t" },
        })
        local result, error_message = FragmentResolver.resolve(
            document,
            clip(0, "missing")
        )
        assert.is_nil(result)
        assert.matches("anchor is not in document", error_message)

        result, error_message = FragmentResolver.resolve(document, clip(0, "empty"))
        assert.is_nil(result)
        assert.matches("empty or whitespace", error_message)

        result, error_message = FragmentResolver.resolve(
            document,
            clip(0, "whitespace")
        )
        assert.is_nil(result)
        assert.matches("empty or whitespace", error_message)
    end)

    it("rejects prefix mismatches before searching elsewhere", function()
        local document = fake_document("hullo", {
            ["#_doc_fragment_0_target"] = { start = 1, text = "hello" },
        })
        local result, error_message = FragmentResolver.resolve(
            document,
            clip(0, "target")
        )
        assert.is_nil(result)
        assert.matches("not a byte%-prefix", error_message)
    end)

    it("rejects non-advancing pointers and invalid compare results", function()
        local document = fake_document("word", {
            ["#_doc_fragment_0_target"] = { start = 1, text = "word" },
        }, {
            next_visible_char = function(pointer)
                if pointer == "#_doc_fragment_0_target" then
                    return "p1"
                end
                return pointer
            end,
        })
        local result, error_message = FragmentResolver.resolve(
            document,
            clip(0, "target")
        )
        assert.is_nil(result)
        assert.matches("did not advance", error_message)

        document = fake_document("word", {
            ["#_doc_fragment_0_target"] = { start = 1, text = "word" },
        }, {
            compare = function()
                return nil
            end,
        })
        result, error_message = FragmentResolver.resolve(document, clip(0, "target"))
        assert.is_nil(result)
        assert.matches("invalid compare result", error_message)
    end)

    it("enforces a bounded sentence step cap", function()
        local document = fake_document("long sentence", {
            ["#_doc_fragment_0_target"] = { start = 1, text = "long sentence" },
        })
        local result, error_message = FragmentResolver.resolve(
            document,
            clip(0, "target"),
            nil,
            { max_steps = 3 }
        )
        assert.is_nil(result)
        assert.matches("step cap exceeded", error_message)
    end)

    it("rejects malformed clips and unsupported target structures", function()
        local document = fake_document("visible", {
            ["#_doc_fragment_0_visible"] = { start = 1, text = "visible" },
        })
        local result, error_message = FragmentResolver.resolve(document, nil)
        assert.is_nil(result)
        assert.matches("malformed clip", error_message)

        result, error_message = FragmentResolver.resolve(
            document,
            clip(0, ":~:text=visible")
        )
        assert.is_nil(result)
        assert.matches("unsupported target fragment", error_message)

        result, error_message = FragmentResolver.resolve(
            document,
            clip(0, "%3a~%3atext%3dvisible")
        )
        assert.is_nil(result)
        assert.matches("unsupported target fragment", error_message)

        result, error_message = FragmentResolver.resolve(document, {
            spine_index = 0,
            text_fragment = "visible id",
        })
        assert.is_nil(result)
        assert.matches("unsupported target fragment", error_message)

        result, error_message = FragmentResolver.resolve(
            document,
            clip(0, "visible"),
            { spine_index = 0 }
        )
        assert.is_nil(result)
        assert.matches("malformed next clip", error_message)
    end)

    it("rejects invalid next-target ordering", function()
        local document = fake_document("hello world", {
            ["#_doc_fragment_2_first"] = { start = 7, text = "hello" },
            ["#_doc_fragment_1_second"] = { start = 1, text = "world" },
        })
        local result, error_message = FragmentResolver.resolve(
            document,
            clip(2, "first"),
            clip(1, "second")
        )
        assert.is_nil(result)
        assert.matches("invalid next%-target ordering", error_message)
    end)
end)
