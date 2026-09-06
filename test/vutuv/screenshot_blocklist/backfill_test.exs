defmodule Vutuv.ScreenshotBlocklist.BackfillTest do
  @moduledoc """
  The backfill over the captures this installation already stores.

  Two properties carry the whole thing. It works per **host**, so the site
  behind a thousand stored captures costs one inference and not a thousand.
  And a host leaves the due list on **every** outcome, including the ones
  where nothing could be judged — an oldest-first queue whose front holds work
  that can never finish spends every batch on it and never reaches the rest
  (the sweeper-clock trap that deadlocked the fediverse count refresher).

  The exception is a service failure: Ollama being down is not a property of
  any host, so the pass stops and stamps nothing.
  """
  use Vutuv.DataCase, async: false

  import Vutuv.PostsHelpers

  alias Vutuv.Posts.PostScreenshot
  alias Vutuv.Posts.Screenshots
  alias Vutuv.ScreenshotBlocklist
  alias Vutuv.ScreenshotBlocklist.Backfill

  setup do
    Repo.delete_all(ScreenshotBlocklist.Entry)
    Repo.delete_all(ScreenshotBlocklist.Check)
    clean_evidence()
    :ok
  end

  describe "due_hosts/1" do
    test "offers one capture per host, not one per capture" do
      user = insert(:activated_user)
      for n <- 1..3, do: stored_capture(user, "https://www.tagesschau.de/artikel-#{n}")
      stored_capture(user, "https://golem.de/news/1")

      hosts = Backfill.due_hosts() |> Enum.map(&elem(&1, 0)) |> Enum.sort()

      assert hosts == ["golem.de", "tagesschau.de"]
    end

    test "skips a host whose verdict still stands" do
      user = insert(:activated_user)
      stored_capture(user, "https://www.tagesschau.de/artikel-1")

      ScreenshotBlocklist.record_check(%{
        host: "tagesschau.de",
        verdict: "usable",
        obstruction: "none"
      })

      assert Backfill.due_hosts() == []
    end

    test "offers a host again once its verdict has aged out" do
      user = insert(:activated_user)
      stored_capture(user, "https://www.tagesschau.de/artikel-1")

      ScreenshotBlocklist.record_check(%{
        host: "tagesschau.de",
        verdict: "usable",
        obstruction: "none"
      })

      age_check("tagesschau.de", "usable", ScreenshotBlocklist.recheck_after_days() + 1)

      assert [{"tagesschau.de", _job}] = Backfill.due_hosts()
    end
  end

  describe "check_due/1" do
    test "a wall blocks the host and the entry names the model's reason" do
      user = insert(:activated_user)
      stored_capture(user, "https://www.golem.de/news/1", image: true)

      tally = Backfill.check_due(decide: fn _path -> {:block, consent()} end)

      assert tally == %{checked: 1, blocked: 1, unknown: 0}
      assert ScreenshotBlocklist.blocked?("https://golem.de/anything")

      entry = Repo.get_by!(ScreenshotBlocklist.Entry, pattern: "golem.de")
      assert entry.source == "ai"
      assert entry.note =~ "cookie dialog"
    end

    test "a usable capture records the verdict and leaves the site alone" do
      user = insert(:activated_user)
      stored_capture(user, "https://www.tagesschau.de/artikel-1", image: true)

      tally = Backfill.check_due(decide: fn _path -> {:usable, usable()} end)

      assert tally == %{checked: 1, blocked: 0, unknown: 0}
      refute ScreenshotBlocklist.blocked?("https://tagesschau.de/x")
      assert ScreenshotBlocklist.get_check("tagesschau.de").verdict == "usable"
    end

    test "a host whose picture cannot be read leaves the due list anyway" do
      user = insert(:activated_user)
      # No file on disk for this one: the check can never succeed.
      stored_capture(user, "https://gone.example/news/1")

      assert %{unknown: 1} = Backfill.check_due(decide: fn _path -> {:usable, usable()} end)

      # The point of the test: it is not offered again on the next pass, so it
      # cannot hold the front of the queue forever.
      assert Backfill.due_hosts() == []
      assert ScreenshotBlocklist.get_check("gone.example").verdict == "unknown"
    end

    test "an unconfirmed suspicion blocks nothing and is looked at again tomorrow" do
      user = insert(:activated_user)
      stored_capture(user, "https://golem.de/news/1", image: true)

      assert %{blocked: 0, unknown: 1} =
               Backfill.check_due(decide: fn _path -> {:discard, consent()} end)

      refute ScreenshotBlocklist.blocked?("https://golem.de/x")
      assert ScreenshotBlocklist.get_check("golem.de").verdict == "unknown"

      # Not due today...
      assert Backfill.due_hosts() == []
      # ...but due again after the short unknown retry age.
      age_check("golem.de", "unknown", 2)
      assert [{"golem.de", _job}] = Backfill.due_hosts()
    end

    test "an unreachable Ollama stops the pass and stamps nothing" do
      user = insert(:activated_user)
      stored_capture(user, "https://golem.de/news/1", image: true)
      stored_capture(user, "https://heise.de/news/1", image: true)

      tally = Backfill.check_due(decide: fn _path -> {:error, {:service, :econnrefused}} end)

      assert tally == %{checked: 0, blocked: 0, unknown: 0}
      assert Repo.all(ScreenshotBlocklist.Check) == []
      assert length(Backfill.due_hosts()) == 2
    end
  end

  ## Fixtures

  # A post with a capture that is stored and released, optionally with a real
  # file on disk where the uploader would have put it.
  defp stored_capture(user, url, opts \\ []) do
    post = create_post!(user, %{body: "Look at this: #{url}"})
    {:ok, job} = Screenshots.reconcile(post)

    {:ok, ready} =
      job
      |> Ecto.Changeset.change(
        status: "ready",
        # Row and disk must agree: the backfill resolves the file the way a URL
        # does (`Vutuv.Screenshot.stored_thumb_path/1`), so a fixture whose
        # name does not match the hash gets no picture at all. `.webp` also
        # exercises the pre-AVIF fallback that resolution keeps.
        screenshot: "0123456789ab.webp",
        moderation: "approved"
      )
      |> Repo.update()

    if Keyword.get(opts, :image, false), do: write_thumb(ready)

    ready
  end

  defp write_thumb(%PostScreenshot{} = job) do
    dir = Vutuv.Uploads.disk_dir("screenshots/#{job.id}")
    File.mkdir_p!(dir)
    path = Path.join(dir, "thumb-0123456789ab.webp")
    {:ok, img} = Image.new(400, 264, color: [10, 120, 200])
    {:ok, _written} = Image.write(img, path)
    on_exit(fn -> File.rm_rf(dir) end)
    path
  end

  defp age_check(host, verdict, days) do
    stale = DateTime.add(DateTime.utc_now(:second), -days, :day)

    ScreenshotBlocklist.get_check(host)
    |> Ecto.Changeset.change(verdict: verdict, checked_at: stale)
    |> Repo.update!()
  end

  defp consent do
    %{
      usable?: false,
      obstruction: "consent",
      coverage_percent: 70,
      reason: "A cookie dialog covers the page."
    }
  end

  defp usable do
    %{usable?: true, obstruction: "none", coverage_percent: 0, reason: "A news page."}
  end

  # The evidence tree is real disk, and the SQL sandbox does not roll a file
  # back: without this every run of this file leaves its pictures in the
  # checkout. Only what this test created is removed, never a neighbour's.
  defp clean_evidence do
    dir = Path.dirname(ScreenshotBlocklist.evidence_path("probe"))
    before = if File.dir?(dir), do: MapSet.new(File.ls!(dir)), else: MapSet.new()

    on_exit(fn -> remove_new_files(dir, before) end)
  end

  defp remove_new_files(dir, before) do
    for name <- (File.dir?(dir) && File.ls!(dir)) || [],
        not MapSet.member?(before, name),
        do: File.rm(Path.join(dir, name))
  end
end
