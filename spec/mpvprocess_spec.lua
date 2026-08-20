package.path = "./koreadalong.koplugin/?.lua;"
    .. ".cache/koreader/lib/koreader/?.lua;"
    .. package.path

local ffi = require("ffi")
local MpvProcess = require("mpvprocess")

local function path_exists(path)
    local ok = os.rename(path, path)
    return ok == true
end

describe("production mpv process lifecycle", function()
    it("reports exec failure, tracks/reaps the child, and cleans owned paths", function()
        local process = MpvProcess.new{
            executable = "/definitely/not/a/koreadalong-mpv",
        }
        local socket_path = assert(process:start())
        local session_dir = process.session_dir
        local saw_exec_error = false
        for _ = 1, 100 do
            for _, event in ipairs(process:poll(0)) do
                if event.kind == "exec_error" then
                    saw_exec_error = true
                    assert.matches("mpv exec failed", event.error)
                end
            end
            if process:is_done() then
                break
            end
            ffi.C.usleep(10000)
        end
        assert.is_true(saw_exec_error)
        assert.is_true(process:is_done())
        assert.is_true(process.reaped)
        assert.is_false(path_exists(socket_path))
        assert.is_false(path_exists(session_dir))
        assert.are.equal("--audio-fallback-to-null=no", process.argv[8])
        for _, argument in ipairs(process.argv) do
            assert.are_not.equal("--ao=null", argument)
        end
        process:cleanup()
    end)
end)
