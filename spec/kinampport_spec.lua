package.path = "./koreadalong.koplugin/?.lua;"
    .. ".cache/koreader/lib/koreader/?.lua;"
    .. ".cache/koreader/lib/koreader/common/?.lua;"
    .. package.path

local ffi = require("ffi")
local KinAMPPort = require("kinampport")

local IDLE_FIXTURE = table.concat({
    "pid=42",
    "state=stopped",
    "mode=audio",
    "index=-1",
    "count=1",
    "path=",
    "pos=0",
    "dur=0",
    "",
}, "\n")

local function attributes(token)
    return {
        mode = "file",
        dev = 1,
        ino = token,
        modification = token,
        change = token,
        size = 42,
    }
end

local function fake_fs(options)
    options = options or {}
    local fs = {
        writes = {},
        closes = 0,
        stats = 0,
        reads = 0,
        ignores = 0,
    }
    fs.is_fifo = options.is_fifo or function()
        return true
    end
    fs.open_fifo = options.open_fifo or function()
        if options.open_error then
            return nil, options.open_error
        end
        return 7
    end
    fs.verify_open_fifo = options.verify_open_fifo or function()
        return true
    end
    fs.close_fd = options.close_fd or function()
        fs.closes = fs.closes + 1
        return true
    end
    fs.write_fd = options.write_fd or function(_, payload)
        fs.writes[#fs.writes + 1] = payload
        if options.write_script then
            local result = table.remove(options.write_script, 1)
            if result then
                return table.unpack(result)
            end
        end
        return #payload
    end
    fs.ignore_sigpipe = options.ignore_sigpipe or function()
        fs.ignores = fs.ignores + 1
        return true
    end
    fs.read_file = options.read_file or function()
        fs.reads = fs.reads + 1
        return options.status or IDLE_FIXTURE
    end
    fs.stat_file = options.stat_file or function()
        fs.stats = fs.stats + 1
        if options.stat_script then
            local value = options.stat_script[fs.stats]
            if value == false then
                return nil, "metadata unavailable"
            end
            return value or options.stat_script[#options.stat_script]
        end
        return options.stat or attributes(1)
    end
    return fs
end

describe("KinAMP protocol port", function()
    it("encodes ordered command arrays and rejects raw multiline input", function()
        local payload = assert(KinAMPPort.encode{
            { "load", "/tmp/one.m3u" },
            { "speed", 1.3 },
            { "index", 0 },
            { "seek", 3 },
            { "pause" },
        })
        assert.are.equal(
            "load /tmp/one.m3u\nspeed 1.3\nindex 0\nseek 3\npause\n",
            payload
        )
        assert.is_nil(KinAMPPort.encode("status\n"))
        assert.is_nil(KinAMPPort.encode{{ "load", "/tmp/bad\npath" }})
        assert.is_nil(KinAMPPort.encode{{ "status\r" }})
        assert.is_nil(KinAMPPort.encode{{ "quit" }})
        assert.is_nil(KinAMPPort.encode{{ "unknown" }})
        assert.is_nil(KinAMPPort.encode({ { "status" } }, 3))
    end)

    it("installs SIG_IGN and rejects SIG_ERR from signal", function()
        local failing_fs = fake_fs{}
        failing_fs.ignore_sigpipe = nil
        local failed_port = KinAMPPort.new{
            fs = failing_fs,
            signal = function()
                return ffi.cast("koreadalong_sighandler_t", -1)
            end,
        }
        local sent, error_message = failed_port:send{{ "status" }}
        assert.is_nil(sent)
        assert.matches("SIG_ERR", error_message)

        local installed_signum
        local installed_handler
        local fs = fake_fs{}
        fs.ignore_sigpipe = nil
        local port = KinAMPPort.new{
            fs = fs,
            signal = function(signum, handler)
                installed_signum = signum
                installed_handler = handler
                return ffi.cast("koreadalong_sighandler_t", 0)
            end,
        }
        assert.is_true(port:send{{ "status" }})
        assert.are.equal(13, installed_signum)
        assert.is_true(
            installed_handler == ffi.cast("koreadalong_sighandler_t", 1)
        )
    end)

    it("parses a real-shaped idle snapshot including index -1", function()
        local status = assert(KinAMPPort.parseStatus(IDLE_FIXTURE))
        assert.are.equal(42, status.pid)
        assert.are.equal("stopped", status.state)
        assert.are.equal(-1, status.index)
        assert.are.equal(1, status.count)
        assert.are.equal("", status.path)
        assert.are.equal(0, status.pos)
        assert.are.equal(0, status.dur)
        assert.is_nil(KinAMPPort.parseStatus("state=stopped\nindex=-2\n"))
        assert.is_nil(KinAMPPort.parseStatus("state=stopped\npid=-1\n"))
        assert.is_nil(KinAMPPort.parseStatus("state=stopped\npos=-1\n"))
    end)

    it("parses the optional speed-v1 publication without weakening legacy fields", function()
        local status = assert(KinAMPPort.parseStatus(IDLE_FIXTURE
            .. "capabilities=speed-v1\nspeed=1.7\nspeed_min=0.5\nspeed_max=3\n"
            .. "speed_formats=aac-mp4,opus-mp4\nspeed_supported=1\npos_ms=12345\n"))
        assert.are.equal("speed-v1", status.capabilities)
        assert.are.equal(1.7, status.speed)
        assert.are.equal(0.5, status.speed_min)
        assert.are.equal(3, status.speed_max)
        assert.is_true(status.speed_supported)
        assert.are.equal(12345, status.pos_ms)
        for _, field in ipairs{
            "speed=nan", "speed=inf", "speed=-1", "speed_supported=2",
            "pos_ms=-1", "pos_ms=1.5",
        } do
            assert.is_nil(KinAMPPort.parseStatus(IDLE_FIXTURE .. field .. "\n"))
        end
    end)

    it("rejects malformed or oversized bounded status", function()
        local malformed = {
            "state=playing\nnot-a-field\n",
            "state=playing\npos=1.5\n",
            "state=unknown\n",
            "state=playing\nstate=paused\n",
            "state=playing\nvalue=bad\nvalue=again\n",
        }
        for _, content in ipairs(malformed) do
            assert.is_nil(KinAMPPort.parseStatus(content))
        end
        assert.is_nil(KinAMPPort.parseStatus("state=playing\n"
            .. string.rep("x", 20), 16))
        assert.is_nil(KinAMPPort.parseStatus("state=playing\npos="
            .. string.rep("9", 32) .. "\n"))
    end)

    it("uses FIFO liveness instead of trusting a stale status file", function()
        local fs = fake_fs{
            open_error = "ENXIO",
            status = "state=playing\npath=/old.wav\npos=9\ndur=10\n",
        }
        local port = KinAMPPort.new{
            runtime_dir = "/tmp/kinamp-test",
            fs = fs,
        }
        local result = assert(port:probe())
        assert.is_false(result.live)
        assert.are.equal("no-listener", result.reason)
        assert.are.equal(0, fs.reads)
        assert.are.equal(0, fs.closes)
    end)

    it("fails closed when FIFO type metadata is unavailable", function()
        local port = KinAMPPort.new{
            fs = fake_fs{
                is_fifo = function()
                    return nil, "metadata unavailable"
                end,
            },
        }
        local result, error_message = port:probe()
        assert.is_nil(result)
        assert.matches("metadata", error_message)
    end)

    it("fails closed when the opened target cannot be verified as a FIFO", function()
        local fs = fake_fs{
            verify_open_fifo = function()
                return nil, "opened target metadata unavailable"
            end,
        }
        local port = KinAMPPort.new{ fs = fs }
        local result, error_message = port:probe()
        assert.is_nil(result)
        assert.matches("opened target", error_message)
        assert.are.equal(1, fs.closes)
    end)

    it("fails closed when status publication metadata is unavailable", function()
        local port = KinAMPPort.new{
            fs = fake_fs{
                stat_file = function()
                    return nil, "metadata unavailable"
                end,
            },
        }
        local status, error_message, kind = port:readStatus()
        assert.is_nil(status)
        assert.matches("publication metadata", error_message)
        assert.are.equal("compatibility", kind)
    end)

    it("fails closed instead of reading a non-regular status path", function()
        local port = KinAMPPort.new{
            fs = fake_fs{
                stat_file = function()
                    return {
                        mode = "fifo",
                        dev = 1,
                        ino = 1,
                        modification = 1,
                    }
                end,
                read_file = function()
                    error("status FIFO must not be read")
                end,
            },
        }
        local status, error_message, kind = port:readStatus()
        assert.is_nil(status)
        assert.matches("regular file", error_message)
        assert.are.equal("compatibility", kind)
    end)

    it("reads a bounded snapshot with an inode publication token", function()
        local fs = fake_fs{
            status = "pid=42\nstate=paused\nindex=0\ncount=1\n"
                .. "path=/tmp/one.wav\npos=2\ndur=8\n",
            stat = attributes(9),
        }
        local port = KinAMPPort.new{
            runtime_dir = "/tmp/kinamp-test",
            fs = fs,
        }
        local result = assert(port:probe())
        assert.is_true(result.live)
        assert.are.equal("paused", result.status.state)
        assert.is_truthy(result.token)
        assert.are.equal(result.token, result.status.publication_token)
        assert.are.equal(2, fs.stats)
    end)

    it("retries a status read when atomic replacement races the read", function()
        local fs = fake_fs{
            status = IDLE_FIXTURE,
            stat_script = {
                attributes(1),
                attributes(2),
                attributes(3),
                attributes(3),
            },
        }
        local port = KinAMPPort.new{ fs = fs }
        local status, error_message, token = port:readStatus()
        assert.is_nil(error_message)
        assert.are.equal(-1, status.index)
        assert.is_truthy(token)
        assert.are.equal(4, fs.stats)
    end)

    it("forces a status publication through the command FIFO", function()
        local fs = fake_fs{
            status = IDLE_FIXTURE,
            stat = attributes(4),
        }
        local port = KinAMPPort.new{ fs = fs }
        local result = assert(port:requestStatus())
        assert.is_true(result.live)
        assert.are.equal("status\n", fs.writes[1])
        assert.are.equal(result.token, result.status.publication_token)
    end)

    it("retries EINTR and bounded EAGAIN without acknowledging a failed write", function()
        local eintr_fs = fake_fs{
            write_script = {
                { nil, "EINTR" },
                { #"status\n" },
            },
        }
        local eintr_port = KinAMPPort.new{ fs = eintr_fs }
        assert.is_true(eintr_port:send{{ "status" }})
        assert.are.equal(2, #eintr_fs.writes)

        local eagain_fs = fake_fs{
            write_script = {
                { nil, "EAGAIN" },
                { nil, "EAGAIN" },
                { #"status\n" },
            },
        }
        local eagain_port = KinAMPPort.new{ fs = eagain_fs }
        assert.is_true(eagain_port:send{{ "status" }})
        assert.are.equal(3, #eagain_fs.writes)
    end)

    it("surfaces EPIPE and impossible short writes as failures", function()
        local pipe_port = KinAMPPort.new{
            fs = fake_fs{
                write_script = { { nil, "EPIPE" } },
            },
        }
        local sent, error_message = pipe_port:send{{ "status" }}
        assert.is_nil(sent)
        assert.matches("not running", error_message)

        local short_port = KinAMPPort.new{
            fs = fake_fs{
                write_script = { { 1 } },
            },
        }
        sent, error_message = short_port:send{{ "status" }}
        assert.is_nil(sent)
        assert.matches("short write", error_message)
    end)

    it("bounds interrupted and would-block writes without acknowledging them", function()
        for _, errno in ipairs({ "EINTR", "EAGAIN" }) do
            local script = {}
            for _ = 1, KinAMPPort.MAX_WRITE_RETRIES + 1 do
                script[#script + 1] = { nil, errno }
            end
            local fs = fake_fs{
                write_script = script,
            }
            local port = KinAMPPort.new{ fs = fs }
            local sent, error_message = port:send{{ "status" }}
            assert.is_nil(sent)
            assert.matches("write", error_message)
            assert.are.equal(KinAMPPort.MAX_WRITE_RETRIES + 1, #fs.writes)
        end
    end)

    it("normalizes an empty runtime override and closes idempotently", function()
        local port = KinAMPPort.new{
            getenv = function(name)
                assert.are.equal("KINAMP_RUNTIME_DIR", name)
                return ""
            end,
            fs = fake_fs{ open_error = "ENXIO" },
        }
        assert.are.equal("/tmp", port:getRuntimeDir())
        assert.is_true(port:close())
        assert.is_true(port:close())
        local sent, error_message = port:send{{ "status" }}
        assert.is_nil(sent)
        assert.matches("closed", error_message)
    end)
end)
