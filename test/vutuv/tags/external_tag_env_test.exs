defmodule Vutuv.Tags.ExternalTagEnvTest do
  @moduledoc """
  The three colon-separated knobs of the followed-tag pull (issue #2126), read
  from an operator's environment at boot.

  It evaluates the parser out of `config/runtime.exs` itself rather than keeping
  a copy here, because a copy would go on passing after the real one had drifted
  — and what is being pinned is that a typo costs the operator the setting and
  not the installation. `runtime.exs` is evaluated **before anything is
  listening**, so a `MatchError` there is not an error message, it is a site
  that does not come up.

  Two older blocks in that file (`FEDIVERSE_INBOUND_CAPS`,
  `FEDIVERSE_COUNTS_LADDER`) still destructure a hard list and are outside this
  test's scope — do not read it as covering the file.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  setup_all do
    source = File.read!(Path.join([__DIR__, "..", "..", "..", "config", "runtime.exs"]))

    [body] =
      Regex.run(~r/^  external_tag_numbers = fn.*?^  end$/ms, source)
      |> List.wrap()

    {parser, _binding} = Code.eval_string(body)
    %{parser: parser}
  end

  test "reads the shipped shapes", %{parser: parser} do
    assert parser.("5:10:180", 3, "EXTERNAL_TAG_CADENCE") == [5, 10, 180]
    assert parser.("20:10000", 2, "EXTERNAL_TAG_POST_CAPS") == [20, 10_000]
    assert parser.(" 20 : 5 ", 2, "EXTERNAL_TAG_FETCH_BUDGET") == [20, 5]
  end

  test "an unset variable is simply not set, and says nothing", %{parser: parser} do
    assert capture_io(:stderr, fn -> send(self(), parser.(nil, 3, "X")) end) == ""
    assert_received nil
  end

  test "a typo keeps the default and says so, rather than killing the boot", %{parser: parser} do
    for bad <- ["5:oops:180", "5:10", "5:10:180:9", "", "-1:10:180", "5:10:180x"] do
      assert capture_io(:stderr, fn -> send(self(), parser.(bad, 3, "EXTERNAL_TAG_CADENCE")) end) =~
               "keeping the default"

      assert_received nil
    end
  end
end
