defmodule Vutuv.ScreenshotBlocklist.VisionTest do
  @moduledoc """
  The page check: what it does with each answer the model can give.

  The three that matter and are easy to get backwards: a consent or login wall
  silences the **site** (and only after every opinion agrees), an error or
  blank page discards the **capture** and leaves the site alone, and anything
  the model cannot answer keeps the capture — this check fails open, unlike
  the NSFW gate it borrows its machinery from.

  All against a `plug:` stub through `:screenshot_check_req_options`; no live
  Ollama, and the picture is a plain generated JPEG (what it depicts does not
  matter, the answer is scripted).
  """
  use Vutuv.DataCase, async: false

  alias Vutuv.ScreenshotBlocklist
  alias Vutuv.ScreenshotBlocklist.Vision

  setup do
    Repo.delete_all(ScreenshotBlocklist.Entry)
    Repo.delete_all(ScreenshotBlocklist.Check)
    put_config(:screenshot_page_check, true)
    on_exit(fn -> Application.delete_env(:vutuv, :screenshot_check_req_options) end)
    {:ok, image: jpeg_fixture()}
  end

  describe "a wall the model is sure about" do
    test "puts the host on the blocklist, with the reason and the picture", %{image: image} do
      agent = stub_verdicts([consent(), consent(), consent()])

      assert {:error, :obstructed} =
               Vision.review("https://www.golem.de/news/artikel-1.html", image)

      assert ScreenshotBlocklist.blocked?("https://golem.de/anything/else")

      entry = Repo.get_by!(ScreenshotBlocklist.Entry, pattern: "golem.de")
      assert entry.source == "ai"
      assert entry.note =~ "consent"
      assert entry.note =~ "cookie dialog"
      assert entry.evidence_file
      assert File.exists?(ScreenshotBlocklist.evidence_path(entry.evidence_file))

      check = ScreenshotBlocklist.get_check("golem.de")
      assert check.verdict == "blocked"
      assert check.obstruction == "consent"
      assert check.coverage_percent == 70
      assert check.checked_url == "https://www.golem.de/news/artikel-1.html"

      # One deterministic opinion, then two independent confirmations.
      assert asked(agent) == 3
      assert temperatures(agent) == [0.0, 0.8, 0.8]
    end

    test "a single dissent leaves the site alone and only drops the capture", %{image: image} do
      stub_verdicts([consent(), consent(), usable()])

      assert {:error, :unusable} = Vision.review("https://www.golem.de/news/1", image)

      refute ScreenshotBlocklist.blocked?("https://golem.de/x")
      assert ScreenshotBlocklist.get_check("golem.de").verdict == "unknown"
    end
  end

  describe "an answer that is about this capture, not the site" do
    for obstruction <- ~w(error blank) do
      test "#{obstruction} discards the capture and never blocks the host", %{image: image} do
        stub_verdicts([%{unquote(obstruction) => true} |> obstruction_verdict()])

        assert {:error, :unusable} = Vision.review("https://tagesschau.de/eilmeldung", image)

        refute ScreenshotBlocklist.blocked?("https://tagesschau.de/x")

        # The host is stamped `unknown` rather than left blank: this capture
        # was worthless, but a site whose captures keep failing must not pay
        # the full ballot again on the very next one.
        check = ScreenshotBlocklist.get_check("tagesschau.de")
        assert check.verdict == "unknown"
      end
    end
  end

  describe "a usable page" do
    test "is remembered, and the host is not asked about again", %{image: image} do
      agent = stub_verdicts([usable()])

      assert :ok = Vision.review("https://www.tagesschau.de/inland/artikel-1.html", image)

      check = ScreenshotBlocklist.get_check("tagesschau.de")
      assert check.verdict == "usable"
      assert check.obstruction == "none"
      assert ScreenshotBlocklist.judged_recently?("tagesschau.de")

      # The second capture of the same site costs no inference at all — the
      # scripted list would raise if it asked again.
      assert :ok = Vision.review("https://www.tagesschau.de/ausland/artikel-2.html", image)
      assert asked(agent) == 1
    end

    test "a verdict older than the re-check age is asked again", %{image: image} do
      stub_verdicts([usable(), usable()])

      assert :ok = Vision.review("https://tagesschau.de/1", image)

      # Age the verdict past the window.
      stale =
        DateTime.add(
          DateTime.utc_now(:second),
          -(ScreenshotBlocklist.recheck_after_days() + 1),
          :day
        )

      ScreenshotBlocklist.get_check("tagesschau.de")
      |> Ecto.Changeset.change(checked_at: stale)
      |> Repo.update!()

      refute ScreenshotBlocklist.judged_recently?("tagesschau.de")
      assert :ok = Vision.review("https://tagesschau.de/2", image)
    end
  end

  describe "when no verdict can be had" do
    test "an unreachable Ollama keeps the capture and blocks nothing", %{image: image} do
      stub_verdicts([{:http, 503}])

      assert :ok = Vision.review("https://golem.de/news/1", image)
      refute ScreenshotBlocklist.blocked?("https://golem.de/news/1")
    end

    test "an answer that is not a verdict keeps the capture", %{image: image} do
      stub(fn conn ->
        body = %{"message" => %{"role" => "assistant", "content" => ""}}
        answer_json(conn, body)
      end)

      assert :ok = Vision.review("https://golem.de/news/1", image)
      refute ScreenshotBlocklist.blocked?("https://golem.de/news/1")
    end

    test "an unreadable picture keeps the capture" do
      stub_verdicts([])

      assert :ok = Vision.review("https://golem.de/news/1", "/nonexistent/path.png")
      refute ScreenshotBlocklist.blocked?("https://golem.de/news/1")
    end

    test "the flag off asks nothing at all", %{image: image} do
      put_config(:screenshot_page_check, false)
      stub_verdicts([])

      assert :ok = Vision.review("https://golem.de/news/1", image)
      refute ScreenshotBlocklist.blocked?("https://golem.de/news/1")
    end
  end

  describe "an admin overruling the model" do
    test "deleting the automatic entry records a usable verdict, so it stays gone", %{
      image: image
    } do
      stub_verdicts([consent(), consent(), consent()])
      assert {:error, :obstructed} = Vision.review("https://golem.de/news/1", image)

      entry = Repo.get_by!(ScreenshotBlocklist.Entry, pattern: "golem.de")
      {:ok, _deleted} = ScreenshotBlocklist.delete_entry(entry)

      refute ScreenshotBlocklist.blocked?("https://golem.de/news/1")
      assert ScreenshotBlocklist.judged_recently?("golem.de")

      # And the next capture of that site does not ask the model again, so it
      # cannot walk straight back onto the list.
      assert :ok = Vision.review("https://golem.de/news/2", image)
    end

    test "their decision does not expire the way a measurement does", %{image: image} do
      stub_verdicts([consent(), consent(), consent()])
      assert {:error, :obstructed} = Vision.review("https://golem.de/news/1", image)

      entry = Repo.get_by!(ScreenshotBlocklist.Entry, pattern: "golem.de")
      {:ok, _deleted} = ScreenshotBlocklist.delete_entry(entry)

      check = ScreenshotBlocklist.get_check("golem.de")
      assert check.source == "admin"

      # Age it far past the re-check window a model's verdict would expire in.
      check
      |> Ecto.Changeset.change(
        checked_at:
          DateTime.add(
            DateTime.utc_now(:second),
            -(ScreenshotBlocklist.recheck_after_days() * 10),
            :day
          )
      )
      |> Repo.update!()

      # Still standing: a person decided this about their own installation, and
      # the docs promise the entry stays gone.
      assert ScreenshotBlocklist.judged_recently?("golem.de")
      assert :ok = Vision.review("https://golem.de/news/3", image)
    end
  end

  ## Stub plumbing (mirrors test/vutuv/moderation/ollama_test.exs)

  defp stub_verdicts(script) do
    {:ok, agent} = Agent.start_link(fn -> %{script: script, asked: 0, temperatures: []} end)

    stub(fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn, length: 50_000_000)
      temperature = Jason.decode!(raw)["options"]["temperature"]

      case next_verdict(agent, temperature) do
        {:http, status} -> Plug.Conn.send_resp(conn, status, "boom")
        verdict -> answer(conn, verdict)
      end
    end)

    agent
  end

  defp next_verdict(agent, temperature) do
    Agent.get_and_update(agent, fn
      %{script: []} ->
        raise "the page check asked for more opinions than the test scripted"

      %{script: [next | rest]} = state ->
        {next,
         %{
           state
           | script: rest,
             asked: state.asked + 1,
             temperatures: state.temperatures ++ [temperature]
         }}
    end)
  end

  defp asked(agent), do: Agent.get(agent, & &1.asked)
  defp temperatures(agent), do: Agent.get(agent, & &1.temperatures)

  defp stub(fun), do: Application.put_env(:vutuv, :screenshot_check_req_options, plug: fun)

  defp answer(conn, verdict) do
    answer_json(conn, %{
      "message" => %{"role" => "assistant", "content" => Jason.encode!(verdict)}
    })
  end

  defp answer_json(conn, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(200, Jason.encode!(body))
  end

  defp consent do
    %{
      "reason" => "A cookie dialog covers the page.",
      "usable" => false,
      "obstruction" => "consent",
      "coverage_percent" => 70
    }
  end

  defp usable do
    %{
      "reason" => "A news page with headlines and a photo.",
      "usable" => true,
      "obstruction" => "none",
      "coverage_percent" => 0
    }
  end

  defp obstruction_verdict(%{"error" => true}) do
    %{
      "reason" => "Error page showing 'This site can't be reached'.",
      "usable" => false,
      "obstruction" => "error",
      "coverage_percent" => 95
    }
  end

  defp obstruction_verdict(%{"blank" => true}) do
    %{
      "reason" => "An essentially empty white page.",
      "usable" => false,
      "obstruction" => "blank",
      "coverage_percent" => 100
    }
  end

  defp put_config(key, value) do
    previous = Application.fetch_env(:vutuv, key)
    Application.put_env(:vutuv, key, value)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:vutuv, key, value)
        :error -> Application.delete_env(:vutuv, key)
      end
    end)
  end

  defp jpeg_fixture do
    src = Path.join(System.tmp_dir!(), "page_check_#{System.unique_integer([:positive])}.jpg")
    {:ok, img} = Image.new(1280, 800, color: [10, 120, 200])
    {:ok, _written} = Image.write(img, src)
    on_exit(fn -> File.rm(src) end)
    src
  end
end
