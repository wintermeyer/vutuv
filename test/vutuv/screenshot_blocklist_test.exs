defmodule Vutuv.ScreenshotBlocklistTest do
  @moduledoc """
  The screenshot blocklist: the entry grammar (domains with and without a
  wildcard, single URLs), the admin CRUD around it, and the shipped list every
  installation is seeded with.

  The cache (`Vutuv.ScreenshotBlocklist.Cache`) is off in the test env, so
  `blocked?/1` reads the table from the calling process and an entry inserted
  here takes effect at once.

  Not async: every test here clears and rewrites the seeded
  `screenshot_blocklist_entries` rows, which two concurrent modules would
  convoy (and could deadlock) on, since the sandbox holds each transaction's
  locks until the test ends.
  """
  use Vutuv.DataCase, async: false

  alias Vutuv.ScreenshotBlocklist

  # Replaces the seeded list for one test, so a case reads as its own list.
  defp blocklist(patterns) do
    Repo.delete_all(ScreenshotBlocklist.Entry)

    for pattern <- patterns do
      {:ok, _entry} = ScreenshotBlocklist.create_entry(%{"pattern" => pattern})
    end
  end

  describe "domain entries" do
    test "a bare domain blocks the apex, every subdomain and every path" do
      blocklist(["heise.de"])

      assert ScreenshotBlocklist.blocked?("https://heise.de")
      assert ScreenshotBlocklist.blocked?("https://heise.de/")
      assert ScreenshotBlocklist.blocked?("http://heise.de/newsticker/meldung-1.html")
      assert ScreenshotBlocklist.blocked?("https://www.heise.de/select/ct/2026/1")
      assert ScreenshotBlocklist.blocked?("https://m.heise.de/")
    end

    test "a domain entry stops at the label boundary" do
      blocklist(["heise.de"])

      refute ScreenshotBlocklist.blocked?("https://notheise.de/x")
      refute ScreenshotBlocklist.blocked?("https://heise.de.evil.example/x")
      refute ScreenshotBlocklist.blocked?("https://example.com/heise.de")
    end

    test "the *. wildcard form is the same rule spelled out, apex included" do
      blocklist(["*.heise.de"])

      assert ScreenshotBlocklist.blocked?("https://www.heise.de/x")
      assert ScreenshotBlocklist.blocked?("https://heise.de/x")
    end

    test "a www. entry names the site, not one host of it" do
      blocklist(["www.heise.de"])

      assert ScreenshotBlocklist.blocked?("https://heise.de/x")
      assert ScreenshotBlocklist.blocked?("https://www.heise.de/x")
    end

    test "case, port, query and fragment cannot defeat a match" do
      blocklist(["heise.de"])

      assert ScreenshotBlocklist.blocked?("https://WWW.Heise.DE/x?utm_source=vutuv#top")
      assert ScreenshotBlocklist.blocked?("https://heise.de:8443/x")
    end

    test "a lone * blocks every host" do
      blocklist(["*"])

      assert ScreenshotBlocklist.blocked?("https://example.com/page")
    end
  end

  describe "single-URL entries" do
    test "a single URL blocks that page and what sits below it" do
      blocklist(["https://example.com/news/story-1"])

      assert ScreenshotBlocklist.blocked?("https://example.com/news/story-1")
      assert ScreenshotBlocklist.blocked?("http://www.example.com/news/story-1?ref=x")
      assert ScreenshotBlocklist.blocked?("https://example.com/news/story-1/comments")

      refute ScreenshotBlocklist.blocked?("https://example.com/news/story-12")
      refute ScreenshotBlocklist.blocked?("https://example.com/news")
      refute ScreenshotBlocklist.blocked?("https://example.com/")
    end

    test "a path prefix stops at a segment boundary" do
      blocklist(["example.com/news"])

      assert ScreenshotBlocklist.blocked?("https://example.com/news")
      assert ScreenshotBlocklist.blocked?("https://example.com/news/2026/story")

      refute ScreenshotBlocklist.blocked?("https://example.com/newsroom")
    end

    test "* stands for exactly one path segment" do
      blocklist(["example.com/*/private"])

      assert ScreenshotBlocklist.blocked?("https://example.com/a/private")
      assert ScreenshotBlocklist.blocked?("https://example.com/b/private/deeper")

      refute ScreenshotBlocklist.blocked?("https://example.com/a/b/private")
      refute ScreenshotBlocklist.blocked?("https://example.com/a/public")
    end

    test "a trailing * stands for the rest of the path" do
      blocklist(["example.com/news/*"])

      assert ScreenshotBlocklist.blocked?("https://example.com/news/2026/story")
      assert ScreenshotBlocklist.blocked?("https://example.com/news")

      refute ScreenshotBlocklist.blocked?("https://example.com/other")
    end

    test "one list mixes domain and URL entries" do
      blocklist(["heise.de", "https://example.com/private"])

      assert ScreenshotBlocklist.blocked?("https://www.heise.de/x")
      assert ScreenshotBlocklist.blocked?("https://example.com/private/page")
      refute ScreenshotBlocklist.blocked?("https://example.com/public")
    end
  end

  describe "robustness" do
    test "a legacy link value without a scheme is matched too" do
      blocklist(["example.com/news"])

      assert ScreenshotBlocklist.blocked?("example.com/news/story")
      refute ScreenshotBlocklist.blocked?("example.com/jobs")
    end

    test "anything that is not an http(s) target is never blocked" do
      blocklist(["example.com"])

      refute ScreenshotBlocklist.blocked?("mailto:me@example.com")
      refute ScreenshotBlocklist.blocked?("garbage-not-a-url")
      refute ScreenshotBlocklist.blocked?(nil)
      refute ScreenshotBlocklist.blocked?(42)
    end
  end

  describe "entries (the admin editor's API)" do
    test "an entry is stored in one canonical spelling" do
      {:ok, entry} =
        ScreenshotBlocklist.create_entry(%{"pattern" => "  HTTPS://WWW.Heise.DE/News/  "})

      assert entry.pattern == "www.heise.de/news"
      assert ScreenshotBlocklist.blocked?("http://heise.de/news/story")
    end

    test "an entry that names no host is refused instead of matching nothing" do
      for pattern <- ["", "   ", "https://", "/", "://"] do
        assert {:error, changeset} = ScreenshotBlocklist.create_entry(%{"pattern" => pattern})
        assert changeset.errors[:pattern], "expected #{inspect(pattern)} to be refused"
      end
    end

    test "the same page cannot be listed twice" do
      blocklist(["heise.de"])

      assert {:error, changeset} =
               ScreenshotBlocklist.create_entry(%{"pattern" => "https://heise.de"})

      assert changeset.errors[:pattern]
    end

    test "a note explains the entry and rides along" do
      {:ok, entry} =
        ScreenshotBlocklist.create_entry(%{
          "pattern" => "consent-wall.example",
          "note" => "Consent banner"
        })

      assert entry.note == "Consent banner"
      assert entry in ScreenshotBlocklist.list_entries()
    end

    test "removing an entry lets the site be captured again" do
      blocklist(["heise.de"])
      [entry] = ScreenshotBlocklist.list_entries()

      assert ScreenshotBlocklist.blocked?("https://heise.de/x")
      {:ok, _deleted} = ScreenshotBlocklist.delete_entry(entry)
      refute ScreenshotBlocklist.blocked?("https://heise.de/x")
    end
  end

  describe "the seeded list" do
    test "covers heise.de and reddit.com out of the box" do
      # The migration seeds the table from :screenshot_blocklist — these two are
      # what every installation starts with.
      assert ScreenshotBlocklist.blocked?("https://www.heise.de/news/story-1234.html")
      assert ScreenshotBlocklist.blocked?("https://heise.de/")
      assert ScreenshotBlocklist.blocked?("https://old.reddit.com/r/elixir")

      refute ScreenshotBlocklist.blocked?("https://example.com/page")
    end
  end
end
