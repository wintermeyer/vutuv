defmodule Vutuv.BuildInfoTest do
  use ExUnit.Case, async: true

  alias Vutuv.BuildInfo
  alias Vutuv.BuildInfo.Git
  alias Vutuv.SourceRepo

  describe "Git.parse/1" do
    test "reads the short sha and the committer instant off `git log --format=%h %cI`" do
      assert Git.parse("3faa4b9d 2026-08-29T17:21:10+02:00\n") ==
               {"3faa4b9d", ~U[2026-08-29 15:21:10Z]}
    end

    test "is nil for anything git did not say" do
      assert Git.parse("") == nil
      assert Git.parse("fatal: not a git repository\n") == nil
      assert Git.parse("3faa4b9d not-a-date\n") == nil
    end
  end

  describe "Git.head_log/0" do
    test "names this checkout's reflog, the file that moves with HEAD" do
      assert Git.head_log() =~ ~r{/logs/HEAD$}
    end
  end

  describe "commit_sha/0 and committed_at/0" do
    test "name the commit this checkout was compiled from" do
      # The suite runs inside the git checkout, so git answered at compile time.
      assert BuildInfo.commit_sha() =~ ~r/^[0-9a-f]{7,40}$/
      assert %DateTime{time_zone: "Etc/UTC"} = BuildInfo.committed_at()
    end
  end

  describe "stamp/0" do
    test "is the commit instant when git answered" do
      assert BuildInfo.stamp() == BuildInfo.committed_at()
    end
  end

  describe "commit_url/0 and version/0" do
    test "hand the commit to the source repository's URL shape" do
      assert BuildInfo.commit_url() == SourceRepo.commit_url(BuildInfo.commit_sha())
    end

    test "the version is the calendar date mix.exs derived" do
      assert BuildInfo.version() == Mix.Project.config()[:version]
    end
  end

  describe "berlin_date/1 and berlin_time/1" do
    test "format a UTC instant as Berlin wall clock, DD.MM.YYYY and HH:MM" do
      # Summer (CEST, UTC+2): 12:30 UTC -> 14:30 Berlin on 24.06.2026.
      assert BuildInfo.berlin_date(~U[2026-06-24 12:30:00Z]) == "24.06.2026"
      assert BuildInfo.berlin_time(~U[2026-06-24 12:30:00Z]) == "14:30"
      # Winter (CET, UTC+1): 12:00 UTC -> 13:00 Berlin on 15.01.2026.
      assert BuildInfo.berlin_date(~U[2026-01-15 12:00:00Z]) == "15.01.2026"
      assert BuildInfo.berlin_time(~U[2026-01-15 12:00:00Z]) == "13:00"
    end
  end
end
