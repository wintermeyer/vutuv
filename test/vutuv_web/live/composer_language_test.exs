defmodule VutuvWeb.ComposerLanguageTest do
  @moduledoc """
  The composer's language declaration (issue #1489): the author says what
  language the post is written in — preset to the UI locale, stored on the
  post, kept on edit, and immune to a tampered select value.
  """
  use VutuvWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Vutuv.Posts
  alias Vutuv.Posts.Post
  alias Vutuv.Repo

  describe "Post.cast_language/1" do
    test "keeps a known code, normalized to its primary subtag" do
      assert Post.cast_language("de") == "de"
      assert Post.cast_language("de-AT") == "de"
      assert Post.cast_language("EN") == "en"
    end

    test "anything unknown becomes nil — undeclared, never a failed post" do
      assert Post.cast_language("xx") == nil
      assert Post.cast_language("hax0r") == nil
      assert Post.cast_language("") == nil
      assert Post.cast_language(nil) == nil
    end
  end

  describe "storing the declaration" do
    test "create_post stores the declared language" do
      user = insert(:user, email_confirmed?: true)

      {:ok, post} = Posts.create_post(user, %{body: "Guten Morgen.", language: "de"})
      assert post.language == "de"
    end

    test "a tampered select value stores as undeclared" do
      user = insert(:user, email_confirmed?: true)

      {:ok, post} = Posts.create_post(user, %{body: "Hello.", language: "<script>"})
      assert post.language == nil
    end

    test "attrs without a language leave a legacy post's NULL alone on edit" do
      user = insert(:user, email_confirmed?: true)
      {:ok, post} = Posts.create_post(user, %{body: "Alt."})
      assert post.language == nil

      {:ok, updated} = Posts.update_post(post, %{body: "Alt, editiert."})
      assert updated.language == nil
    end
  end

  describe "the feed composer" do
    test "renders the select in the bottom row, preset to the UI locale", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)

      {:ok, live, html} = live(conn, ~p"/feed")

      # In the row beside "Add photos", not behind a disclosure — the placement
      # IS the change, so assert it inside the row rather than anywhere in the
      # document. The ⋯ it used to sit in never held a second entry the member
      # could reach.
      assert has_element?(
               live,
               ~s([data-composer-actions] select[name="post[language]"])
             )

      # The test conn's locale is "en"; the site locales render as short codes.
      assert html =~ ~r/<option[^>]*value="en"[^>]*selected/
      assert html =~ ~s(<option value="de")
    end

    test "renders German labels for a German member — by name, against fuzzy fills", %{
      conn: conn
    } do
      {conn, user} = create_and_login_user(conn)
      user |> Ecto.Changeset.change(%{locale: "de"}) |> Repo.update!()

      {:ok, live, html} = live(conn, ~p"/feed")

      # The word is inside the control now, on the group holding the codes —
      # the box is two letters wide and has no room beside it. It keeps its own
      # msgctxt so it can be the bare word here while the profile's
      # `gettext("Language")` goes on labelling a language somebody speaks.
      # Assert the German by name: a one-word msgid is the likeliest thing a
      # `gettext.extract --merge` fuzzy-fills wrongly and the least likely to
      # be noticed.
      assert has_element?(live, ~s(select#composer-language optgroup[label="Sprache"]))
      assert html =~ "Die Sprache, in der dieser Beitrag geschrieben ist"
      assert html =~ "Weitere Sprachen"
      assert html =~ ~r/<option[^>]*value="de"[^>]*selected/
    end

    test "saving a post stores the selected language", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      {:ok, live, _html} = live(conn, ~p"/feed")

      live
      |> form("#composer-form", %{"post" => %{"body" => "Guten Morgen!", "language" => "de"}})
      |> render_submit()

      post = Repo.one!(from(p in Post, where: p.user_id == ^user.id))
      assert post.language == "de"
    end

    test "a submit carrying no language at all falls back to the assign", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      user |> Ecto.Changeset.change(%{locale: "de"}) |> Repo.update!()

      {:ok, live, _html} = live(conn, ~p"/feed")

      # Pushed at the component, NOT through `form/3`: with the select on
      # screen, `form/3` collects it as a rendered default and submits
      # `post[language]` whatever payload you hand it, so the fallback in
      # `save` would go unmeasured. It still has to hold — a form recovered
      # after a reconnect need not carry every field, and losing the
      # declaration is the silent kind of loss.
      live
      |> with_target("#composer")
      |> render_submit("save", %{"post" => %{"body" => "Guten Morgen!"}})

      post = Repo.one!(from(p in Post, where: p.user_id == ^user.id))
      assert post.language == "de"
    end
  end

  describe "the edit page" do
    test "prefills the post's own language and saves a change", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      {:ok, post} = Posts.create_post(user, %{body: "Guten Morgen.", language: "de"})

      {:ok, live, html} = live(conn, ~p"/posts/#{post.id}/edit")

      assert html =~ ~r/<option[^>]*value="de"[^>]*selected/

      live
      |> form("#composer-form", %{"post" => %{"body" => "Good morning.", "language" => "en"}})
      |> render_submit()

      assert Repo.reload!(post).language == "en"
    end

    test "a language outside the site's own gets a code of its own", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      {:ok, post} = Posts.create_post(user, %{body: "Bom dia.", language: "pt"})

      {:ok, live, _html} = live(conn, ~p"/posts/#{post.id}/edit")

      # The closed box is 4.5rem, so whatever it has to show has to be a code:
      # "pt" joins the site's own rather than standing in the long list as
      # "Portuguese" and being cut off in the box. Assert it SELECTED — an
      # option that merely exists is what the browser falls back off, and the
      # box would show "EN".
      assert has_element?(
               live,
               ~s(optgroup[label="Language"] option[value="pt"][selected]),
               "PT"
             )

      # And it leaves the long list, or two options would carry one value and
      # the second — the long one — would win the closed box back.
      refute has_element?(live, ~s(optgroup[label="More languages"] option[value="pt"]))
      assert has_element?(live, ~s(optgroup[label="More languages"] option[value="fr"]))
    end
  end
end
