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

    it("escalates one process group from TERM to KILL after bounded deadlines", function()
        local signals = {}
        local process = MpvProcess.new{
            term_timeout = 0.4,
            kill_timeout = 0.4,
            waitpid = function()
                return 0
            end,
            kill = function(pid, signal)
                signals[#signals + 1] = { pid = pid, signal = signal }
                return 0
            end,
        }
        process.started = true
        process.pid = 31415

        process:begin_close(10)
        process:poll(10.39)
        assert.are.same({}, signals)
        process:poll(10.4)
        assert.are.same({ { pid = -31415, signal = 15 } }, signals)
        process:poll(10.79)
        assert.are.equal(1, #signals)
        process:poll(10.8)
        assert.are.same({
            { pid = -31415, signal = 15 },
            { pid = -31415, signal = 9 },
        }, signals)
    end)
end)
