defmodule Vutuv.Translations.TranslationsDisabledTest do
  @moduledoc """
  The `:translate_posts` flag off — the shipped default, and every
  installation without an Ollama. `async: false` in its own file: the test
  flips a global application env key that `Vutuv.Translations.enabled?/0`
  reads (via `request/2` and `deliver_due/1`), which the whole translation
  feature branches on.
  """
  use Vutuv.DataCase, async: false

  alias Vutuv.Translations
  alias Vutuv.Translations.TranslationJob

  setup do
    original = Application.fetch_env(:vutuv, :translate_posts)
    Application.put_env(:vutuv, :translate_posts, false)

    on_exit(fn ->
      case original do
        {:ok, was} -> Application.put_env(:vutuv, :translate_posts, was)
        :error -> Application.delete_env(:vutuv, :translate_posts)
      end
    end)

    :ok
  end

  test "request/2 answers :disabled and queues nothing" do
    post = insert(:post, body: "Guten Morgen.")

    assert Translations.request(post, "en") == :disabled
    assert Repo.aggregate(TranslationJob, :count) == 0
  end

  test "deliver_due/1 is a no-op — pending jobs stay untouched, originals stand" do
    post = insert(:post, body: "Guten Morgen.")

    Repo.insert!(%TranslationJob{post_id: post.id, target_language: "en"})

    exploding = fn _subject, _target -> raise "must not translate while disabled" end
    :ok = Translations.deliver_due(translate: exploding)

    assert Repo.one!(TranslationJob).status == "pending"
  end

  test "detect_due/1 is a no-op — an installation with no Ollama detects nothing" do
    post = insert(:post, body: "Ein ganz gewöhnlicher deutscher Satz.")

    {1, _} =
      Repo.update_all(from(p in Vutuv.Posts.Post, where: p.id == ^post.id),
        set: [language: nil]
      )

    exploding = fn _subject -> raise "must not detect while disabled" end
    assert Translations.detect_due(detect: exploding) == {:ok, 0}
    assert Translations.detect_all(detect: exploding) == {:ok, 0}

    assert Repo.reload!(post).language_checked_at == nil
  end
end
