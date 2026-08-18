defmodule Vutuv.Translations.PrecomputeTest do
  @moduledoc """
  Background pre-translation of local posts, and the reader's right of way
  over it.

  The load-bearing assertions are the two that read as "nothing happened":
  a post the sweep considered and found nothing to do for must still leave
  the work list (an unstamped no-op holds the front of every batch forever —
  the `refresh_counts` starvation lesson), and the backlog cap must actually
  stop a round rather than merely slow it down.
  """
  use Vutuv.DataCase, async: true

  alias Vutuv.Translations
  alias Vutuv.Translations.TranslationJob

  @background TranslationJob.background_priority()

  defp german_post(attrs \\ []) do
    insert(:post, Keyword.merge([body: "Guten Morgen.", language: "de"], attrs))
  end

  defp jobs_for(post) do
    Repo.all(from(j in TranslationJob, where: j.post_id == ^post.id))
  end

  defp considered_at(post), do: Repo.reload!(post).translations_enqueued_at

  describe "picking candidates" do
    test "opens a background job for the locale the post is not written in" do
      post = german_post()

      assert Translations.enqueue_background() == 1

      assert [%TranslationJob{target_language: "en", priority: @background, status: "pending"}] =
               jobs_for(post)
    end

    test "never translates a post into its own language" do
      german_post(language: "de")
      Translations.enqueue_background()

      assert Repo.all(from(j in TranslationJob, select: j.target_language)) == ["en"]
    end

    test "covers BOTH directions — every locale this installation serves" do
      german = german_post(language: "de")
      english = german_post(body: "Good morning.", language: "en")

      assert Translations.enqueue_background() == 2

      assert [%TranslationJob{target_language: "en"}] = jobs_for(german)

      # The direction the German-site reflex forgets, and the one that caught a
      # real bug: `:locales` lives under the ENDPOINT config, so reading it as a
      # top-level `:vutuv` key answers nil and falls back to a default whose
      # only entry is "en" — which translates German posts correctly by
      # accident and English posts not at all, with the whole suite green.
      assert [%TranslationJob{target_language: "de"}] = jobs_for(english)
    end

    test "skips a post whose language nobody could place" do
      post = german_post(language: nil)

      assert Translations.enqueue_background() == 0
      assert jobs_for(post) == []
      # And it is not even stamped: it was never a candidate, so the sweep has
      # nothing to say about it. Detection owns that row (issue #1535).
      assert considered_at(post) == nil
    end

    test "skips a frozen post and a post with nothing to translate" do
      frozen = german_post(frozen_at: NaiveDateTime.utc_now(:second))
      empty = german_post(body: "")

      assert Translations.enqueue_background() == 0
      assert jobs_for(frozen) == []
      assert jobs_for(empty) == []
    end

    test "a post that already has a fresh translation opens no job" do
      post = german_post()
      {:ok, _} = Translations.store_translation(post, "en", %{body: "Good morning.", model: "m"})

      assert Translations.enqueue_background() == 0
      assert jobs_for(post) == []
    end

    test "an edited post is re-translated: its cached row went stale" do
      post = german_post()
      {:ok, _} = Translations.store_translation(post, "en", %{body: "Good morning.", model: "m"})
      assert Translations.enqueue_background() == 0

      # The sweep looked at this post before the edit — which is what makes the
      # edit re-open it. Backdated by a second because the whole exchange fits
      # inside one here, and both columns hold whole seconds.
      Repo.update_all(from(p in Vutuv.Posts.Post, where: p.id == ^post.id),
        set: [translations_enqueued_at: DateTime.add(DateTime.utc_now(:second), -1, :second)]
      )

      {:ok, post} = Vutuv.Posts.update_post(post, %{body: "Guten Abend."})

      assert Translations.enqueue_background() == 1
      assert [%TranslationJob{target_language: "en"}] = jobs_for(post)
    end
  end

  describe "the sweep's clock" do
    test "a considered post leaves the work list — including the do-nothing outcome" do
      post = german_post()
      {:ok, _} = Translations.store_translation(post, "en", %{body: "Good morning.", model: "m"})

      # Nothing to open here. The stamp is the scheduler's clock, not a claim
      # that work happened — without it this post is due again on the very
      # next round and holds the front of the work list forever. Calibrated
      # against the un-fixed shape, where `enqueue_background/1` keeps
      # returning this same row every round.
      assert Translations.enqueue_background() == 0
      assert %DateTime{} = considered_at(post)

      other = german_post(body: "Guten Abend.")
      assert Translations.enqueue_background(limit: 1) == 1
      assert [%TranslationJob{}] = jobs_for(other)
    end

    test "a stamped post is not reconsidered until the interval is up" do
      post = german_post()
      assert Translations.enqueue_background() == 1

      # Its job is open, so a second round finds nothing new even once the
      # post is back in the work list.
      Repo.update_all(from(p in Vutuv.Posts.Post, where: p.id == ^post.id),
        set: [translations_enqueued_at: nil]
      )

      assert Translations.enqueue_background() == 0
      assert length(jobs_for(post)) == 1
    end

    test "a failed translation is retried once the reconsider interval has passed" do
      post = german_post()
      assert Translations.enqueue_background() == 1

      # What an Ollama outage leaves behind: the job gave up, no translation
      # was stored, and no edit will ever re-open this post.
      Repo.update_all(from(j in TranslationJob, where: j.post_id == ^post.id),
        set: [status: "failed"]
      )

      long_ago = DateTime.add(DateTime.utc_now(:second), -7 * 3600, :second)

      Repo.update_all(from(p in Vutuv.Posts.Post, where: p.id == ^post.id),
        set: [translations_enqueued_at: long_ago]
      )

      assert Translations.enqueue_background() == 1
      assert length(jobs_for(post)) == 2
    end
  end

  describe "the backlog cap" do
    test "a full backlog stops the round dead" do
      for n <- 1..3, do: german_post(body: "Guten Morgen #{n}.")

      assert Translations.enqueue_background(backlog_cap: 2) == 3
      assert Translations.background_backlog() == 3

      # Over the cap now: the next round opens nothing, whatever is waiting.
      fresh = german_post(body: "Und noch einer.")
      assert Translations.enqueue_background(backlog_cap: 2) == 0
      assert jobs_for(fresh) == []
      # Not stamped either — it was never looked at, so nothing was decided.
      assert considered_at(fresh) == nil
    end

    test "a reader's own jobs do not count toward the cap" do
      post = german_post()
      {:queued, _} = Translations.request(post, "en")

      assert Translations.background_backlog() == 0
    end
  end

  describe "the flags" do
    test "off means nothing is opened and nothing is stamped" do
      post = german_post()

      Application.put_env(:vutuv, :precompute_translations, false)
      on_exit(fn -> Application.put_env(:vutuv, :precompute_translations, true) end)

      assert Translations.enqueue_background() == 0
      assert jobs_for(post) == []
      assert considered_at(post) == nil
    end
  end
end
