defmodule Vutuv.DeployScriptTest do
  @moduledoc """
  `scripts/deploy.sh` runs on the self-hosted runner and is what puts a release
  into production, so its failure modes are production incidents rather than
  test failures.

  This covers one of them, seen on 2026-08-09. The script runs `set -euo
  pipefail`, and after the traffic switch it called two image-maintenance
  tasks directly. One of them could not open a database connection, `set -e`
  took the whole script down, and the lines below it never ran — including the
  one that stops the previous slot. Both releases then kept running for forty
  minutes: two connection pools against a Postgres already at its
  100-connection ceiling (which is what had failed the maintenance step to
  begin with), and every periodic sweeper firing twice, among them the one
  that emails members about unread messages.

  The property to hold on to: **once traffic has been switched, the deploy has
  succeeded**, so nothing after that point may abort the script before the old
  slot is stopped. Both the wrapper's behaviour and the ordering it protects
  are asserted here, because either one alone can regress silently.
  """
  use ExUnit.Case, async: true

  @script "scripts/deploy.sh"

  setup do
    {:ok, source: File.read!(@script)}
  end

  describe "the maintenance wrapper" do
    test "runs the failing command, says so, and lets the script continue", %{source: source} do
      # Exercise the definition the script actually ships, not a copy of it.
      [definition] = Regex.run(~r/^maintenance\(\) \{.*?^\}$/ms, source)

      harness = """
      set -euo pipefail
      log() { echo "LOG: $*"; }
      #{definition}
      maintenance "a step that fails" false
      maintenance "a step that works" true
      echo "REACHED-THE-STOP-STEP"
      """

      {output, status} = System.cmd("bash", ["-c", harness], stderr_to_stdout: true)

      assert status == 0
      assert output =~ "REACHED-THE-STOP-STEP"
      assert output =~ "WARNING: a step that fails failed"
      refute output =~ "WARNING: a step that works"
    end
  end

  describe "the post-switch section" do
    test "wraps every release task after the traffic switch", %{source: source} do
      after_switch = post_switch_section(source)

      for line <- String.split(after_switch, "\n"),
          String.contains?(line, ~s|eval "Vutuv.Release|),
          not String.starts_with?(String.trim(line), "#") do
        assert String.contains?(line, "maintenance "),
               """
               An unwrapped release task after the traffic switch can abort the \
               deploy before the old slot is stopped:

                   #{String.trim(line)}
               """
      end
    end

    test "stops the old slot after the maintenance tasks, not before", %{source: source} do
      after_switch = post_switch_section(source)

      assert [_ | _] = Regex.scan(~r/^maintenance /m, after_switch)

      last_maintenance =
        after_switch
        |> String.split("\n")
        |> Enum.find_index(&String.starts_with?(&1, "maintenance "))

      stop_line =
        after_switch
        |> String.split("\n")
        |> Enum.find_index(&String.contains?(&1, ~s|systemctl stop "$OLD_UNIT"|))

      assert stop_line, "the deploy must stop the old slot"
      assert stop_line > last_maintenance
    end
  end

  # Everything from the nginx reload onwards: at that point users are already
  # being served by the new release.
  defp post_switch_section(source) do
    [_, after_switch] = String.split(source, "Traffic switched to", parts: 2)
    after_switch
  end
end
