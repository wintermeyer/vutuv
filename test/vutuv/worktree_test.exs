defmodule Vutuv.WorktreeTest do
  @moduledoc """
  The three helpers in `mix.exs` that keep parallel git worktrees off each
  other's databases and ports. The reasoning lives in their `@doc`s.
  """
  use ExUnit.Case, async: true

  alias Vutuv.MixProject

  describe "worktree_name/1" do
    @describetag :tmp_dir

    test "the main checkout has none: its .git is a directory", %{tmp_dir: tmp} do
      dir = Path.join(tmp, "vutuv")
      File.mkdir_p!(Path.join(dir, ".git"))

      assert MixProject.worktree_name(dir) == nil
    end

    test "a linked worktree is named the way git names it", %{tmp_dir: tmp} do
      assert tmp |> checkout("profile") |> MixProject.worktree_name() == "profile"
    end

    test "the name is lowercased and reduced to database-safe characters", %{tmp_dir: tmp} do
      assert tmp |> checkout("Fix-Feed.Rail") |> MixProject.worktree_name() == "fix_feed_rail"
    end

    test "a long name is cut so the database name stays inside Postgres' 63 bytes",
         %{tmp_dir: tmp} do
      name = tmp |> checkout(String.duplicate("a", 60)) |> MixProject.worktree_name()

      assert byte_size("vutuv1_test_#{name}#{String.duplicate("p", 8)}") < 63
    end

    # A submodule's .git is a file too, and a third party vendoring vutuv would
    # otherwise get a worktree's treatment: its own database, its own port.
    test "a git submodule is not a worktree", %{tmp_dir: tmp} do
      dir = Path.join(tmp, "vendored")
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, ".git"), "gitdir: ../.git/modules/vutuv\n")

      assert MixProject.worktree_name(dir) == nil
    end

    test "a checkout without any .git counts as the main one", %{tmp_dir: tmp} do
      dir = Path.join(tmp, "export")
      File.mkdir_p!(dir)

      assert MixProject.worktree_name(dir) == nil
    end
  end

  describe "worktree_suffix/1" do
    @describetag :tmp_dir

    test "the main checkout appends nothing", %{tmp_dir: tmp} do
      dir = Path.join(tmp, "vutuv")
      File.mkdir_p!(Path.join(dir, ".git"))

      assert MixProject.worktree_suffix(dir) == ""
    end

    test "a worktree appends its own name", %{tmp_dir: tmp} do
      assert tmp |> checkout("profile") |> MixProject.worktree_suffix() == "_profile"
    end
  end

  describe "worktree_port/1" do
    test "the main checkout keeps 4000" do
      assert MixProject.worktree_port(nil) == 4000
    end

    test "every port lands in the range reserved for worktrees" do
      for name <- ~w(a profile feed_rail x9 verylongworktreename) do
        assert MixProject.worktree_port(name) in 4100..4899
      end
    end

    # The `cw` shell function that creates these worktrees computes the port too,
    # to print the URL — it lives in the author's shell, not in this repository,
    # so nothing here can prove the two agree. These fixtures pin the formula, so
    # at least a change on this side is visible rather than silent.
    test "the fixtures pin the formula" do
      assert MixProject.worktree_port("profile") == 4653
      assert MixProject.worktree_port("vutuv") == 4346
    end
  end

  describe "the config wiring" do
    # This one only bites where it matters: in a worktree it fails the moment
    # config/test.exs stops deriving the name (verified by reverting that line —
    # "vutuv1_test" against "vutuv1_test_vutuv_wt_cal"). In the main checkout,
    # CI included, both sides are "vutuv1_test" and it asserts nothing.
    test "the suite runs on this checkout's own database" do
      expected =
        "vutuv1_test#{MixProject.worktree_suffix()}#{System.get_env("MIX_TEST_PARTITION")}"

      assert Application.get_env(:vutuv, Vutuv.Repo)[:database] == expected
    end
  end

  defp checkout(tmp, name) do
    dir = Path.join(tmp, "checkout")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, ".git"), "gitdir: /elsewhere/.git/worktrees/#{name}\n")
    dir
  end
end
