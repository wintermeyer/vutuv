defmodule VutuvWeb.FeedTranslationTargetTest do
  @moduledoc """
  The reader's translation target (issue #1672): the **first** language on
  their ranked feed-language list, not the interface locale.

  That distinction is the whole point of ranking the list. "I read German and
  English, translate everything else into German" is unsayable while the target
  is the UI locale — a member browsing vutuv in English got English
  translations whatever their list said, and the two settings quietly
  contradicted each other.

  An empty list keeps the old behaviour (the UI locale), because a member who
  named no language has expressed no target either.
  """
  use VutuvWeb.ConnCase, async: true

  alias Vutuv.Accounts.User
  alias VutuvWeb.Live.PostTranslations

  defp reader!(attrs) do
    :activated_user |> insert() |> Ecto.Changeset.change(attrs) |> Repo.update!()
  end

  describe "target_language/1" do
    test "is the first language on the ranked list" do
      reader = reader!(%{locale: "en", feed_languages: ["de", "en"]})

      assert PostTranslations.target_language(reader) == "de"
    end

    test "follows the ranking, not the alphabet or the locale" do
      reader = reader!(%{locale: "de", feed_languages: ["en", "de"]})

      assert PostTranslations.target_language(reader) == "en"
    end

    test "falls back to the interface locale when no language is chosen" do
      reader = reader!(%{locale: "de", feed_languages: nil})

      Gettext.put_locale(VutuvWeb.Gettext, "de")
      assert PostTranslations.target_language(reader) == "de"
    end

    test "answers the interface locale for a logged-out viewer" do
      Gettext.put_locale(VutuvWeb.Gettext, "en")

      assert PostTranslations.target_language(nil) == "en"
    end
  end

  describe "offer_translation?/2" do
    test "a card in the reader's target language gets no Translate button" do
      reader = reader!(%{locale: "en", feed_languages: ["de", "en"]})

      refute PostTranslations.offer_translation?("de", reader)
    end

    test "a card in another of the reader's languages still offers the button" do
      # Deliberately wider than the automatic mode: a reader who ranked English
      # second sees it in the original, and may still want this one card in
      # German.
      reader = reader!(%{locale: "en", feed_languages: ["de", "en"]})

      assert PostTranslations.offer_translation?("en", reader)
    end

    test "an undeclared card is never offered" do
      reader = reader!(%{locale: "en", feed_languages: ["de"]})

      refute PostTranslations.offer_translation?(nil, reader)
    end
  end

  describe "the automatic mode" do
    test "queues into the first ranked language, not the interface locale" do
      Gettext.put_locale(VutuvWeb.Gettext, "en")

      reader =
        reader!(%{locale: "en", feed_foreign_posts: "translate", feed_languages: ["de", "en"]})

      author = insert(:activated_user)
      insert(:follow, follower: reader, followee: author)

      {:ok, french} =
        Vutuv.Posts.create_post(author, %{body: "Bonjour tout le monde.", language: "fr"})

      map = PostTranslations.auto_translate(%{}, [french], reader)

      assert map[{:post, french.id}] == :pending
      assert [job] = Repo.all(Vutuv.Translations.TranslationJob)
      assert job.target_language == "de"
    end

    test "leaves every ranked language alone" do
      reader =
        reader!(%{locale: "en", feed_foreign_posts: "translate", feed_languages: ["de", "en"]})

      author = insert(:activated_user)
      {:ok, english} = Vutuv.Posts.create_post(author, %{body: "Good morning.", language: "en"})

      assert PostTranslations.auto_translate(%{}, [english], reader) == %{}
      assert Repo.aggregate(Vutuv.Translations.TranslationJob, :count) == 0
    end
  end

  describe "chosen_feed_languages/1" do
    test "keeps the member's ranking" do
      assert Vutuv.Posts.chosen_feed_languages(%User{feed_languages: ["en", "de"]}) == [
               "en",
               "de"
             ]
    end
  end
end
