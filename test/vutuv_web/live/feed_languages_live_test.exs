defmodule VutuvWeb.FeedLanguagesLiveTest do
  @moduledoc """
  The feed-language settings page (/settings/feed_languages, issue #1672).

  The load-bearing assertions:

    * the list is **ranked** and the ranking survives a save — position 1 is
      the translation target, so an order that comes back sorted is a bug, not
      a cosmetic difference
    * the suggestion is offered as something to press and ticks nothing, so no
      filter can appear that the member did not choose (the reason #1537 gave
      for not pre-selecting)
    * a payload from the drag hook may reorder the list but never change what
      is in it
    * the outcome panel says what the two controls do together, including the
      case where "hide" hides nothing
  """
  use VutuvWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Vutuv.Accounts
  alias Vutuv.Profiles.Language

  defp open(conn), do: live(conn, ~p"/settings/feed_languages")

  defp languages(user), do: Accounts.get_user(user.id).feed_languages

  defp ranked(live) do
    live
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("[data-feed-language]")
    |> Enum.to_list()
    |> Enum.flat_map(&LazyHTML.attribute(&1, "data-feed-language"))
  end

  setup %{conn: conn} do
    {conn, user} = create_and_login_user(conn)
    {:ok, conn: conn, user: user}
  end

  describe "ranking" do
    test "adding appends, so the first language stays the one that was ranked first", %{
      conn: conn,
      user: user
    } do
      {:ok, live, _html} = open(conn)

      live |> element("form[phx-change=add]") |> render_change(%{"code" => "de"})
      live |> element("form[phx-change=add]") |> render_change(%{"code" => "en"})

      assert ranked(live) == ["de", "en"]
      assert languages(user) == ["de", "en"]
    end

    test "the placeholder adds nothing, and a chosen language leaves the picker", %{
      conn: conn,
      user: user
    } do
      {:ok, live, _html} = open(conn)

      live |> element("form[phx-change=add]") |> render_change(%{"code" => ""})
      assert languages(user) == nil

      live |> element("form[phx-change=add]") |> render_change(%{"code" => "de"})

      assert languages(user) == ["de"]
      refute has_element?(live, "[data-add-language] option[value=de]")
    end

    test "the arrows move one step and persist", %{conn: conn, user: user} do
      {:ok, _} = Accounts.update_user(user, %{"feed_languages" => ["de", "en", "fr"]})
      {:ok, live, _html} = open(conn)

      live |> element("[data-feed-language=fr] button[phx-value-dir=up]") |> render_click()

      assert ranked(live) == ["de", "fr", "en"]
      assert languages(user) == ["de", "fr", "en"]
    end

    test "the top language cannot move up and the last cannot move down", %{
      conn: conn,
      user: user
    } do
      {:ok, _} = Accounts.update_user(user, %{"feed_languages" => ["de", "en"]})
      {:ok, live, _html} = open(conn)

      assert has_element?(live, "[data-feed-language=de] button[phx-value-dir=up][disabled]")
      assert has_element?(live, "[data-feed-language=en] button[phx-value-dir=down][disabled]")
    end

    test "the first row is the one that says translations land in it", %{conn: conn, user: user} do
      {:ok, _} = Accounts.update_user(user, %{"feed_languages" => ["de", "en"]})
      {:ok, live, _html} = open(conn)

      assert has_element?(live, "[data-feed-language=de] [data-target-note]")
      refute has_element?(live, "[data-feed-language=en] [data-target-note]")
    end

    test "a drag payload reorders the list but cannot change what is in it", %{
      conn: conn,
      user: user
    } do
      {:ok, _} = Accounts.update_user(user, %{"feed_languages" => ["de", "en"]})
      {:ok, live, _html} = open(conn)

      # A forged code and a dropped one: neither may take effect. "ja" was
      # never chosen, and leaving "en" out must not remove it.
      render_hook(live, "reorder", %{"order" => ["ja", "en"]})

      assert languages(user) == ["en", "de"]
    end

    test "removing the last language means all languages again", %{conn: conn, user: user} do
      {:ok, _} = Accounts.update_user(user, %{"feed_languages" => ["de"]})
      {:ok, live, _html} = open(conn)

      live |> element("[data-feed-language=de] button[phx-click=remove]") |> render_click()

      assert languages(user) == nil
      assert render(live) =~ "No language chosen"
    end
  end

  describe "the suggestion" do
    test "is offered as a button and nothing is chosen until it is pressed", %{
      conn: conn,
      user: user
    } do
      {:ok, _} = Accounts.update_user(user, %{"locale" => "de"})
      Repo.insert!(%Language{user_id: user.id, language_code: "fr", proficiency: "c2"})

      {:ok, live, _html} = open(conn)

      assert has_element?(live, "[data-suggested-language=de]")
      assert has_element?(live, "[data-suggested-language=fr]")
      assert languages(user) == nil

      live |> element("[data-suggested-language=fr]") |> render_click()

      assert languages(user) == ["fr"]
      # Once chosen it is a ranked row, not a suggestion any more.
      refute has_element?(live, "[data-suggested-language=fr]")
    end
  end

  describe "what happens to the rest" do
    test "the mode select saves on change", %{conn: conn, user: user} do
      {:ok, live, _html} = open(conn)

      live |> element("form[phx-change=mode]") |> render_change(%{"mode" => "translate"})

      assert Accounts.get_user(user.id).feed_foreign_posts == "translate"
    end

    test "the translate option names the target language, not \"my language\"", %{
      conn: conn,
      user: user
    } do
      {:ok, _} = Accounts.update_user(user, %{"feed_languages" => ["de", "en"]})
      {:ok, live, _html} = open(conn)

      assert live |> element("option[value=translate]") |> render() =~ "Translate into German"

      # It follows the ranking, because the ranking is what picks the target.
      live |> element("[data-feed-language=en] button[phx-value-dir=up]") |> render_click()

      assert live |> element("option[value=translate]") |> render() =~ "Translate into English"
    end

    test "the other two options keep the registry's shared wording", %{conn: conn} do
      {:ok, live, _html} = open(conn)

      for value <- ~w(original hide) do
        pref = Vutuv.Prefs.pref!(:feed_foreign_posts)

        assert live |> element("option[value=#{value}]") |> render() =~
                 Vutuv.Prefs.value_label(pref, value)
      end
    end

    test "the outcome names the language translations land in", %{conn: conn, user: user} do
      {:ok, _} =
        Accounts.update_user(user, %{
          "feed_languages" => ["de", "en"],
          "feed_foreign_posts" => "translate"
        })

      {:ok, live, _html} = open(conn)

      assert live |> element("[data-outcome-rest]") |> render() =~ "German"
    end

    test "says out loud that hiding with no language hides nothing", %{conn: conn, user: user} do
      {:ok, _} = Accounts.update_user(user, %{"feed_foreign_posts" => "hide"})
      {:ok, live, _html} = open(conn)

      assert live |> element("[data-outcome-rest]") |> render() =~ "Nothing is hidden"
    end
  end

  describe "reset" do
    test "clears both halves back to inheriting", %{conn: conn, user: user} do
      {:ok, _} =
        Accounts.update_user(user, %{
          "feed_languages" => ["de"],
          "feed_foreign_posts" => "hide"
        })

      {:ok, live, _html} = open(conn)
      live |> element("#reset-feed-languages") |> render_click()

      reset = Accounts.get_user(user.id)
      assert reset.feed_languages == nil
      assert reset.feed_foreign_posts == nil
      refute has_element?(live, "#reset-feed-languages")
    end
  end

  describe "German" do
    test "renders in German for a German member", %{conn: conn, user: user} do
      {:ok, _} =
        Accounts.update_user(user, %{
          "locale" => "de",
          "feed_languages" => ["de"],
          "feed_foreign_posts" => "translate"
        })

      # `recycle/1` first: the login already sent a response on this conn, and
      # a header set on a sent conn raises rather than reaching the request.
      conn = conn |> recycle() |> put_req_header("accept-language", "de-DE,de")
      {:ok, live, _html} = live(conn, ~p"/settings/feed_languages")
      html = render(live)

      assert html =~ "Sprachen, die Sie lesen"
      assert html =~ "Sprache hinzufügen"
      assert html =~ "Zuerst: In diese Sprache wird übersetzt"
      assert html =~ "Was Ihr Feed macht"
      assert html =~ "Wird in Deutsch übersetzt."
      # The option Stefan named: the page knows which language it is, so it
      # says so instead of "In meine Sprache übersetzen".
      assert html =~ "In Deutsch übersetzen"
    end
  end
end
