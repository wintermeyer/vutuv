defmodule VutuvWeb.FeedTranslateModeTest do
  @moduledoc """
  The feed's translate mode (issue #1461): with `feed_foreign_posts` set to
  "translate", foreign-language cards auto-request their translation on page
  load — cached ones show at once, the rest show the original with the
  pending line until the worker's broadcast swaps them in. Plus the settings
  form the pair of controls is set on.
  """
  use VutuvWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Vutuv.Posts
  alias Vutuv.Translations
  alias Vutuv.Translations.TranslationJob

  defp translate_mode!(user) do
    user
    |> Ecto.Changeset.change(%{feed_foreign_posts: "translate"})
    |> Repo.update!()
  end

  test "a cached translation shows at once, an uncached one queues", %{conn: conn} do
    {conn, user} = create_and_login_user(conn)
    translate_mode!(user)

    {:ok, cached} = Posts.create_post(user, %{body: "Schon übersetzt.", language: "de"})
    {:ok, fresh} = Posts.create_post(user, %{body: "Noch nicht übersetzt.", language: "de"})

    {:ok, _} =
      Translations.store_translation(cached, "en", %{
        source_language: "de",
        body: "Already translated.",
        model: "stub"
      })

    {:ok, live, _html} = live(conn, ~p"/feed")
    html = render(live)

    # The cached card swapped in with its label; the other shows the original
    # with the pending line, and exactly one job was queued for it.
    assert html =~ "Already translated."
    refute html =~ "Schon übersetzt."
    assert html =~ "Translated from German"
    assert html =~ "Noch nicht übersetzt."
    assert has_element?(live, "[data-translation-pending]")

    assert [job] = Repo.all(TranslationJob)
    assert job.post_id == fresh.id

    # The worker finishes; the second card swaps in live.
    :ok =
      Translations.deliver_due(
        translate: fn _subject, _target ->
          {:ok, %{source_language: "de", body: "Not yet translated.", summary: nil, model: "s"}}
        end
      )

    html = render(live)
    assert html =~ "Not yet translated."
    refute html =~ "Noch nicht übersetzt."
  end

  test "a translated card points at the settings that decided it", %{conn: conn} do
    {conn, user} = create_and_login_user(conn)
    translate_mode!(user)

    {:ok, post} = Posts.create_post(user, %{body: "Guten Morgen.", language: "de"})

    {:ok, _} =
      Translations.store_translation(post, "en", %{
        source_language: "de",
        body: "Good morning.",
        model: "stub"
      })

    {:ok, live, _html} = live(conn, ~p"/feed")

    # Issue #1672: the card is where a reader wonders how this was decided, and
    # it used to say nothing about where to change it.
    assert has_element?(live, ~s|[data-translation-settings][href="/settings/feed_languages"]|)
  end

  test "an untranslated card carries no settings link", %{conn: conn} do
    {conn, user} = create_and_login_user(conn)
    {:ok, _} = Posts.create_post(user, %{body: "Guten Morgen.", language: "de"})

    {:ok, live, _html} = live(conn, ~p"/feed")

    refute has_element?(live, "[data-translation-settings]")
  end

  test "a post in a chosen language is not auto-translated", %{conn: conn} do
    {conn, user} = create_and_login_user(conn)

    # Ranked English-first (issue #1672), so English is the translation target
    # and German is a chosen language that is *not* the target — the case the
    # manual button exists for.
    user
    |> Ecto.Changeset.change(%{feed_foreign_posts: "translate", feed_languages: ["en", "de"]})
    |> Repo.update!()

    {:ok, _} = Posts.create_post(user, %{body: "Gewählte Sprache.", language: "de"})

    {:ok, live, _html} = live(conn, ~p"/feed")

    assert render(live) =~ "Gewählte Sprache."
    assert Repo.aggregate(TranslationJob, :count) == 0
    # The manual button still offers the choice.
    assert has_element?(live, "[data-translate-button]")
  end

  test "a post already in the reader's target language offers no Translate button", %{conn: conn} do
    {conn, user} = create_and_login_user(conn)

    # The reader browses in English but ranked German first, so German is where
    # translations land — and a German card has nowhere left to go. Before
    # issue #1672 the target was the UI locale, so this card was offered a
    # translation into a language the reader had just ranked second.
    user
    |> Ecto.Changeset.change(%{locale: "en", feed_languages: ["de", "en"]})
    |> Repo.update!()

    {:ok, _} = Posts.create_post(user, %{body: "Schon in der Zielsprache.", language: "de"})

    {:ok, live, _html} = live(conn, ~p"/feed")

    assert render(live) =~ "Schon in der Zielsprache."
    refute has_element?(live, "[data-translate-button]")
  end

  describe "the settings page" do
    # The controls themselves live on /settings/feed_languages now (issue
    # #1672) and `feed_languages_live_test.exs` covers them. What is asserted
    # here is the bridge: "Language & display" is where members looked for
    # this for two releases, so it must still point at it.
    test "Language & display points at the page the controls moved to", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)

      html = conn |> get(~p"/settings/preferences") |> html_response(200)

      assert html =~ ~s|href="/settings/feed_languages"|
    end

    test "the hub lists the page under its own row", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)

      html = conn |> get(~p"/settings") |> html_response(200)

      assert html =~ ~s|href="/settings/feed_languages"|
    end
  end
end
