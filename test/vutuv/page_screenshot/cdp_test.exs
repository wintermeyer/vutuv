defmodule Vutuv.PageScreenshot.CdpTest do
  @moduledoc """
  The two parts of the DevTools driver that can be tested without a browser:
  how the protocol stream is framed, and how the browser is launched. Both are
  places where a mistake is invisible rather than loud — a mis-split frame just
  goes missing, and a missing redirect corrupts the stream with log lines.
  """
  use ExUnit.Case, async: true

  alias Vutuv.PageScreenshot.Cdp

  describe "split_frames/1" do
    test "keeps an incomplete trailing frame for the next read" do
      complete = ~s({"id":1})
      partial = ~s({"id":2)

      # A read lands wherever it lands. Parsing the tail would throw away the
      # first half of a message and desynchronise everything after it.
      assert {[^complete], ^partial} = Cdp.split_frames(complete <> <<0>> <> partial)
    end

    test "takes several messages out of one read" do
      assert {["a", "b", "c"], ""} = Cdp.split_frames("a\0b\0c\0")
    end

    test "a buffer with no terminator yields nothing yet" do
      assert {[], "half a mes"} = Cdp.split_frames("half a mes")
    end

    test "an empty buffer is not a frame" do
      assert {[], ""} = Cdp.split_frames("")
    end
  end

  describe "command/2" do
    test "hands the protocol pipe to the descriptors Chromium expects" do
      {_cmd, args} = Cdp.command("/usr/bin/chromium", ["--headless=new"])
      shell = Enum.at(args, Enum.find_index(args, &(&1 == "-c")) + 1)

      # A port only ever gets fd 0 and 1; --remote-debugging-pipe reads fd 3
      # and writes fd 4, so they are duplicated across.
      assert shell =~ "3<&0"
      assert shell =~ "4>&1"
    end

    test "takes Chromium's own stdio away so its logs cannot corrupt the stream" do
      {_cmd, args} = Cdp.command("/usr/bin/chromium", [])
      shell = Enum.at(args, Enum.find_index(args, &(&1 == "-c")) + 1)

      # fd 4 is a dup of stdout, so anything Chromium prints on stdout would
      # arrive interleaved with protocol frames and break JSON decoding. The
      # order matters: the dups above happen first, then these replace 0 and 1.
      assert shell =~ "1>/dev/null"
      assert shell =~ "2>/dev/null"
      assert Enum.find_index(args, &String.contains?(&1, "4>&1")) != nil
    end

    test "adds the protocol flag itself, so it cannot drift from the fd plumbing" do
      {_cmd, args} = Cdp.command("/usr/bin/chromium", ["--headless=new"])

      # Left to the caller's flag list, dropping it would launch a perfectly
      # healthy browser that simply never answers — a 20s timeout with nothing
      # pointing at the cause.
      assert "--remote-debugging-pipe" in args
    end

    test "passes the binary and its flags through to the shell" do
      {_cmd, args} = Cdp.command("/usr/bin/chromium", ["--headless=new", "--window-size=1,2"])

      assert "/usr/bin/chromium" in args
      assert "--headless=new" in args
      assert "--window-size=1,2" in args
    end

    test "wraps the run in a hard OS ceiling when timeout is available" do
      {cmd, args} = Cdp.command("/usr/bin/chromium", [])

      # Without an OS-level kill, a wedged Chromium outlives the capture as an
      # orphan — the failure this wrapper has always existed to prevent.
      if System.find_executable("timeout") || System.find_executable("gtimeout") do
        assert Path.basename(cmd) in ["timeout", "gtimeout"]
        assert "#{Cdp.capture_seconds()}" in args
        assert Enum.any?(args, &String.starts_with?(&1, "--kill-after="))
      else
        assert cmd == "/bin/sh"
      end
    end
  end
end
