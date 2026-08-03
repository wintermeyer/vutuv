defmodule Vutuv.References.SkillTest do
  @moduledoc """
  The prompt source. Most of the attention goes to `valid_body?/1` and to what
  happens when it says no, because that is the one place where failing open
  would be silent and expensive: a short or empty prompt does not make the
  model refuse, it makes it answer from training alone — still formatted,
  still confident, and without a single legal anchor.

  This module flips `:fetch_reference_skill` and the Req stub, both global
  application env, so it is `async: false`. No other module reads those keys.
  """
  use Vutuv.DataCase, async: false

  alias Vutuv.References.Skill
  alias Vutuv.References.SkillVersion
  alias Vutuv.Repo

  # A body that passes every gate: the frontmatter name, a Version line, and
  # enough bulk. Built rather than read from priv/ so the test states its own
  # preconditions.
  defp valid_body(version \\ "3.0.24") do
    """
    ---
    name: arbeitszeugnis-pruefer
    description: "Test"
    ---

    Version: #{version}

    """ <> String.duplicate("Zeugnisrecht nach § 109 GewO. ", 2_000)
  end

  defp put_config(key, value) do
    original = Application.fetch_env(:vutuv, key)
    Application.put_env(:vutuv, key, value)

    on_exit(fn ->
      case original do
        {:ok, was} -> Application.put_env(:vutuv, key, was)
        :error -> Application.delete_env(:vutuv, key)
      end
    end)
  end

  defp stub(fun), do: put_config(:reference_skill_req_options, plug: fun)

  describe "valid_body?/1" do
    test "accepts the real shape" do
      assert Skill.valid_body?(valid_body())
    end

    test "rejects a body that is too short" do
      short = """
      ---
      name: arbeitszeugnis-pruefer
      ---

      Version: 3.0.24
      """

      refute Skill.valid_body?(short)
    end

    test "rejects a long document that is not the skill" do
      refute Skill.valid_body?(String.duplicate("Lorem ipsum dolor sit amet. ", 3_000))
    end

    # The most likely real failure: GitHub answers 200 with an HTML error or a
    # login page rather than the file.
    test "rejects an HTML error page" do
      page = "<!doctype html><title>404</title>" <> String.duplicate("<p>Not found</p>", 5_000)
      refute Skill.valid_body?(page)
    end

    test "rejects a body with no Version line" do
      body = String.replace(valid_body(), "Version: 3.0.24", "")
      refute Skill.valid_body?(body)
    end

    test "rejects a non-binary" do
      refute Skill.valid_body?(nil)
      refute Skill.valid_body?(%{})
    end
  end

  describe "version_of/1 and digest/1" do
    test "reads the declared version" do
      assert Skill.version_of(valid_body("4.1.0")) == "4.1.0"
    end

    test "is nil when there is none" do
      assert Skill.version_of("no version here") == nil
    end

    test "the digest is stable and differs per body" do
      assert Skill.digest("a") == Skill.digest("a")
      refute Skill.digest("a") == Skill.digest("b")
      assert String.length(Skill.digest("a")) == 64
    end
  end

  describe "store/2" do
    test "stores a valid body" do
      assert {:ok, version} = Skill.store(valid_body(), "remote")
      assert version.version == "3.0.24"
      assert version.source == "remote"
      assert version.sha256 == Skill.digest(valid_body())
    end

    test "refuses an invalid body" do
      assert {:error, :not_the_skill} = Skill.store("too short", "remote")
      assert Repo.aggregate(SkillVersion, :count) == 0
    end

    # The daily fetch nearly always returns what is already stored. That must
    # refresh the row, not pile up a copy a day.
    test "the same body twice is one row" do
      {:ok, _first} = Skill.store(valid_body(), "remote")
      {:ok, _again} = Skill.store(valid_body(), "remote")

      assert Repo.aggregate(SkillVersion, :count) == 1
    end

    test "a changed body is a new row, so the history survives" do
      {:ok, _old} = Skill.store(valid_body("3.0.24"), "remote")
      {:ok, _new} = Skill.store(valid_body("3.1.0"), "remote")

      assert Repo.aggregate(SkillVersion, :count) == 2
    end
  end

  describe "current/0" do
    test "falls back to the vendored copy when nothing is stored" do
      version = Skill.current()

      assert version.source == "vendored"
      # The vendored file is the real skill, so it must pass its own gate.
      assert Skill.valid_body?(version.body)
      assert version.version
    end

    test "prefers the newest stored body" do
      {:ok, _vendored} = Skill.store(Skill.vendored_body(), "vendored")
      {:ok, fetched} = Skill.store(valid_body("9.9.9"), "remote")

      assert Skill.current().id == fetched.id
    end
  end

  describe "refresh/0" do
    test "adopts a valid fetched body" do
      put_config(:fetch_reference_skill, true)
      stub(fn conn -> Plug.Conn.resp(conn, 200, valid_body("5.0.0")) end)

      assert {:ok, version} = Skill.refresh()
      assert version.version == "5.0.0"
      assert version.source == "remote"
      assert Skill.current().version == "5.0.0"
    end

    # Fail closed: whatever arrives that is not the skill leaves the previous
    # prompt in force. An empty prompt would not stop the model, it would only
    # remove every legal anchor from its answer.
    test "keeps the previous body when the fetch returns something else" do
      put_config(:fetch_reference_skill, true)
      {:ok, good} = Skill.store(valid_body("5.0.0"), "remote")

      stub(fn conn -> Plug.Conn.resp(conn, 200, "<html>404</html>") end)

      assert {:ok, version} = Skill.refresh()
      assert version.id == good.id
      assert Skill.current().version == "5.0.0"
    end

    test "keeps the previous body when the fetch fails outright" do
      put_config(:fetch_reference_skill, true)
      {:ok, good} = Skill.store(valid_body("5.0.0"), "remote")

      stub(fn conn -> Plug.Conn.resp(conn, 500, "boom") end)

      assert {:ok, version} = Skill.refresh()
      assert version.id == good.id
    end

    test "falls back to the vendored copy when the very first fetch fails" do
      put_config(:fetch_reference_skill, true)
      stub(fn conn -> Plug.Conn.resp(conn, 503, "") end)

      assert {:ok, version} = Skill.refresh()
      assert version.source == "vendored"
    end

    # An installation with no outbound network access runs on the vendored
    # copy and must never reach for the network.
    test "does not fetch at all when the switch is off" do
      put_config(:fetch_reference_skill, false)

      stub(fn _conn ->
        flunk("refresh/0 reached the network with :fetch_reference_skill disabled")
      end)

      assert {:ok, version} = Skill.refresh()
      assert version.source == "vendored"
    end
  end

  describe "the vendored copy" do
    test "is present and is really the skill" do
      body = Skill.vendored_body()

      assert is_binary(body)
      assert Skill.valid_body?(body)
      assert body =~ "§ 109 GewO"
    end
  end
end
