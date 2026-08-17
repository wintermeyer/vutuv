defmodule VutuvWeb.PostTranslationDisplayTest do
  @moduledoc """
  The translate action on post cards (issue #1462): the quiet button on a
  foreign-language card, the pending line, the live swap-in over PubSub, the
  "never a silent translation" label with the original one tap away, and the
  `lang` attribute. Logged-out and same-language cards get none of it.
  """
  use VutuvWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Vutuv.Posts
  alias Vutuv.Translations

  defp german_post!(user) do
    {:ok, post} = Posts.create_post(user, %{body: "Guten Morgen allerseits.", language: "de"})
    post
  end

  defp translator(body) do
    fn _subject, _target ->
      {:ok, %{source_language: "de", body: body, summary: nil, model: "stub"}}
    end
  end

  describe "the feed" do
    test "translate → pending → live swap-in → back to the original", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      post = german_post!(user)

      {:ok, live, _html} = live(conn, ~p"/feed")

      # The viewer's locale is "en", the post declares "de": the quiet action.
      assert has_element?(live, "[data-translate-button]")

      live
      |> element(~s(button[phx-click="translate"][phx-value-id="#{post.id}"]))
      |> render_click()

      # Queued, not cached: the pending line shows while the worker runs.
      assert has_element?(live, "[data-translation-pending]")

      :ok = Translations.deliver_due(translate: translator("Good morning everyone."))

      html = render(live)
      assert html =~ "Good morning everyone."
      refute html =~ "Guten Morgen allerseits."
      assert html =~ "Translated from German"
      assert html =~ ~s(lang="en")

      # The original is one tap away; the cached row stays for the next tap.
      live
      |> element(~s(button[phx-click="show-original"][phx-value-id="#{post.id}"]))
      |> render_click()

      html = render(live)
      assert html =~ "Guten Morgen allerseits."
      refute html =~ "Good morning everyone."
    end

    test "a cached translation swaps in without a job", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      post = german_post!(user)

      {:ok, _} =
        Translations.store_translation(post, "en", %{
          source_language: "de",
          body: "Cached morning.",
          model: "stub"
        })

      {:ok, live, _html} = live(conn, ~p"/feed")

      live
      |> element(~s(button[phx-click="translate"][phx-value-id="#{post.id}"]))
      |> render_click()

      assert render(live) =~ "Cached morning."
      assert Repo.aggregate(Vutuv.Translations.TranslationJob, :count) == 0
    end

    test "a card in the reader's own language offers no translate action", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      {:ok, _post} = Posts.create_post(user, %{body: "Same language.", language: "en"})

      {:ok, live, _html} = live(conn, ~p"/feed")

      refute has_element?(live, "[data-translate-button]")
    end

    # Issue #1535: an undeclared post used to be offered, and since nearly
    # everything written before the language column existed is undeclared, the
    # offer sat under posts the reader wrote in their own language.
    test "a card that declares no language offers no translate action", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      {:ok, post} = Posts.create_post(user, %{body: "Undeclared language.", language: nil})

      {:ok, live, _html} = live(conn, ~p"/feed")

      assert render(live) =~ "Undeclared language."
      refute has_element?(live, "[data-translate-button]")

      # Once the detector places it, the action is back.
      {:ok, 1} =
        Translations.detect_due(
          force: true,
          limit: 1,
          detect: fn _subject -> {:ok, "de"} end
        )

      {:ok, live, _html} = live(conn, ~p"/feed")

      assert has_element?(
               live,
               ~s(button[phx-click="translate"][phx-value-id="#{post.id}"])
             )
    end

    test "a failed translation clears the pending line, the original stands", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      post = german_post!(user)

      {:ok, live, _html} = live(conn, ~p"/feed")

      live
      |> element(~s(button[phx-click="translate"][phx-value-id="#{post.id}"]))
      |> render_click()

      assert has_element?(live, "[data-translation-pending]")

      # Drive the job to its strike cap: the worker broadcasts the failure.
      failing = fn _subject, _target -> {:error, {:content, :length_ratio}} end

      for _round <- 1..4 do
        Repo.update_all(Vutuv.Translations.TranslationJob, set: [next_attempt_at: nil])
        :ok = Translations.deliver_due(translate: failing)
      end

      html = render(live)
      refute html =~ "data-translation-pending"
      assert html =~ "Guten Morgen allerseits."
    end
  end

  describe "the profile" do
    test "translating and toggling back works on the profile's posts card", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      post = german_post!(user)

      {:ok, _} =
        Translations.store_translation(post, "en", %{
          source_language: "de",
          body: "Profile morning.",
          model: "stub"
        })

      {:ok, live, _html} = live(conn, ~p"/#{user.username}")

      live
      |> element(~s(button[phx-click="translate"][phx-value-id="#{post.id}"]))
      |> render_click()

      assert render(live) =~ "Profile morning."

      live
      |> element(~s(button[phx-click="show-original"][phx-value-id="#{post.id}"]))
      |> render_click()

      assert render(live) =~ "Guten Morgen allerseits."
    end

    test "a logged-out visitor sees the original and no translation controls", %{conn: conn} do
      user = insert(:user, email_confirmed?: true)
      _post = german_post!(user)

      conn = get(conn, ~p"/#{user.username}")
      html = html_response(conn, 200)

      assert html =~ "Guten Morgen allerseits."
      refute html =~ "data-translate-button"
      # The lang attribute is worth having independent of any translation.
      assert html =~ ~s(lang="de")
    end
  end

  describe "German UI strings (by name, against fuzzy fills)" do
    test "the whole flow reads German for a German member", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      user |> Ecto.Changeset.change(%{locale: "de"}) |> Repo.update!()

      {:ok, post} = Posts.create_post(user, %{body: "English words here.", language: "en"})

      {:ok, _} =
        Translations.store_translation(post, "de", %{
          source_language: "en",
          body: "Deutsche Wörter hier.",
          model: "stub"
        })

      {:ok, live, html} = live(conn, ~p"/feed")
      assert html =~ "Übersetzen"

      live
      |> element(~s(button[phx-click="translate"][phx-value-id="#{post.id}"]))
      |> render_click()

      html = render(live)
      assert html =~ "Deutsche Wörter hier."
      assert html =~ "Übersetzt aus Englisch"
      assert html =~ "Original anzeigen"
    end
  end
end
