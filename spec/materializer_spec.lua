package.path = "./koreadalong.koplugin/?.lua;"
    .. ".cache/koreader/lib/koreader/?.lua;"
    .. ".cache/koreader/lib/koreader/common/?.lua;"
    .. package.path

local ffi = require("ffi")
local lfs = require("lfs")
local Materializer = require("materializer")

describe("private audio materializer", function()
    it("writes exact binary bytes, retains a decoder suffix, and cleans owned paths", function()
        local materializer = Materializer.new{}
        local bytes = "RIFF\0\255\0WAVE"
        local path = assert(materializer:materialize(
            "book/audio.wav",
            function() return bytes end
        ))
        local file = assert(io.open(path, "rb"))
        assert.are.equal(bytes, file:read("*a"))
        file:close()
        assert.matches("%.wav$", path)
        assert.are.equal("rw-------", lfs.attributes(path, "permissions"))
        assert.are.equal("rwx------", lfs.attributes(materializer.session_dir, "permissions"))

        local owned = materializer:materialize(
            "book/second.unknown-extension-that-is-too-long",
            function() return "next" end
        )
        assert.is_not_nil(owned)
        assert.is_true(materializer:remove(path))
        assert.is_false(materializer:remove("/tmp/not-owned"))
        local directory = materializer.session_dir
        assert.is_true(materializer:cleanup())
        assert.is_nil(os.rename(owned, owned))
        assert.is_nil(os.rename(directory, directory))
    end)

    it("handles partial writes and EINTR without changing bytes", function()
        local written_bytes = ""
        local calls = 0
        local fake = {
            eintr = 4,
            make_directory = function()
                return "/fake/koreadalong-123"
            end,
            make_file = function(template, suffix_length)
                assert.are.equal(4, suffix_length)
                assert.matches("XXXXXX%.wav$", template)
                return 9, "/fake/koreadalong-123/audio-abc123.wav"
            end,
            write = function(_, buffer, length)
                calls = calls + 1
                if calls == 2 then
                    return nil, 4
                end
                local count = math.min(3, length)
                written_bytes = written_bytes .. ffi.string(buffer, count)
                return count
            end,
            close = function() return true end,
            remove = function() return true end,
            error_string = function() return "fake error" end,
        }
        local materializer = Materializer.new{ syscalls = fake }
        local bytes = "abc\0def"
        local path = assert(materializer:materialize("audio.wav", function()
            return bytes
        end))
        assert.are.equal("/fake/koreadalong-123/audio-abc123.wav", path)
        assert.are.equal(bytes, written_bytes)
        assert.are.equal(4, calls)
    end)

    it("does not leave ownership after read, write, or close failures", function()
        local materializer = Materializer.new{
            syscalls = {
                eintr = 4,
                make_directory = function()
                    return "/fake/koreadalong-456"
                end,
                make_file = function()
                    return 10, "/fake/koreadalong-456/audio-abc123.mp3"
                end,
                write = function()
                    return nil, 5
                end,
                close = function() return true end,
                remove = function() return true end,
                error_string = function() return "I/O error" end,
            },
        }
        local path, error_message = materializer:materialize("audio.mp3", function()
            return "bytes"
        end)
        assert.is_nil(path)
        assert.matches("I/O error", error_message)
        assert.is_nil(next(materializer.owned_files))

        local read_path, read_error = materializer:materialize(
            "audio.mp3",
            function() error("backend unavailable") end
        )
        assert.is_nil(read_path)
        assert.matches("backend unavailable", read_error)
    end)

    it("retains ownership after failed removal and retries file and directory cleanup", function()
        local remove_files = true
        local remove_directory = false
        local directory
        local fake = {
            eintr = 4,
            make_directory = function()
                directory = "/fake/koreadalong-retry"
                return directory
            end,
            make_file = function()
                return 11, directory .. "/audio-abc123.wav"
            end,
            write = function(_, _, length) return length end,
            close = function() return true end,
            remove = function(path)
                if path == directory then
                    if remove_directory then
                        return true
                    end
                    return nil, "directory busy"
                end
                if remove_files then
                    return true
                end
                return nil, "file busy"
            end,
            error_string = function() return "fake error" end,
        }
        local materializer = Materializer.new{ syscalls = fake }
        local path = assert(materializer:materialize(
            "audio.wav",
            function() return "bytes" end
        ))

        remove_files = false
        local removed, remove_error = materializer:remove(path)
        assert.is_nil(removed)
        assert.matches("file busy", remove_error)
        assert.is_true(materializer.owned_files[path])

        remove_files = true
        assert.is_true(materializer:remove(path))
        local cleanup_ok, cleanup_error = materializer:cleanup()
        assert.is_nil(cleanup_ok)
        assert.matches("directory busy", cleanup_error)
        assert.are.equal(directory, materializer.session_dir)

        remove_directory = true
        assert.is_true(materializer:cleanup())
        assert.is_nil(materializer.session_dir)
    end)
end)
