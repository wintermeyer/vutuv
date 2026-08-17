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

  test "a post in a chosen language is not auto-translated", %{conn: conn} do
    {conn, user} = create_and_login_user(conn)

    user
    |> Ecto.Changeset.change(%{feed_foreign_posts: "translate", feed_languages: ["de", "en"]})
    |> Repo.update!()

    {:ok, _} = Posts.create_post(user, %{body: "Gewählte Sprache.", language: "de"})

    {:ok, live, _html} = live(conn, ~p"/feed")

    assert render(live) =~ "Gewählte Sprache."
    assert Repo.aggregate(TranslationJob, :count) == 0
    # The manual button still offers the choice.
    assert has_element?(live, "[data-translate-button]")
  end

  describe "the settings form" do
    test "stores the mode and the chosen languages, and resets to inherit", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      conn =
        put(conn, ~p"/settings/feed_languages", %{
          "user" => %{"feed_foreign_posts" => "hide", "feed_languages" => ["de", "en"]}
        })

      assert redirected_to(conn) == ~p"/settings/preferences"
      reloaded = Repo.reload!(user)
      assert reloaded.feed_foreign_posts == "hide"
      assert Enum.sort(reloaded.feed_languages) == ["de", "en"]

      conn = post(conn, ~p"/settings/feed_languages/reset", %{})
      assert redirected_to(conn) == ~p"/settings/preferences"
      reset = Repo.reload!(user)
      assert reset.feed_foreign_posts == nil
      assert reset.feed_languages == nil
    end

    test "renders the card with German strings for a German member", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      user |> Ecto.Changeset.change(%{locale: "de"}) |> Repo.update!()

      html = conn |> get(~p"/settings/preferences") |> html_response(200)

      assert html =~ "Beiträge in anderen Sprachen"
      assert html =~ "In meine Sprache übersetzen"
      assert html =~ "Ausblenden"
      # The chips' own heading (issue #1537 replaced the checkbox grid);
      # feed_language_chips_test.exs covers the card's behaviour.
      assert html =~ "Diese Sprachen lese ich"
    end
  end
end
