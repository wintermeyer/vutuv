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
    test "renders the select preset to the UI locale, site locales first", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)

      {:ok, live, _html} = live(conn, ~p"/feed")

      html = render(live)
      assert has_element?(live, ~s(select[name="post[language]"]))
      # The test conn's locale is "en"; the site locales render as short codes.
      assert html =~ ~r/<option[^>]*value="en"[^>]*selected/
      assert html =~ ~s(<option value="de")
    end

    test "renders German labels for a German member — by name, against fuzzy fills", %{
      conn: conn
    } do
      {conn, user} = create_and_login_user(conn)
      user |> Ecto.Changeset.change(%{locale: "de"}) |> Repo.update!()

      {:ok, live, _html} = live(conn, ~p"/feed")
      html = render(live)

      assert html =~ "Sprache des Beitrags"
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
  end
end
