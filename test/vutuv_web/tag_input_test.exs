defmodule VutuvWeb.TagInputTest do
  @moduledoc """
  Every field that takes a batch of tags renders the one shared pill box
  (`VutuvWeb.UI.tag_input/1`), on classic controller pages and inside
  LiveViews alike.

  This is a drift guard, not a UI test: the pills themselves are built by
  `assets/js/tag_input.js`, so what the server owes each surface is the widget
  root (`[data-tag-input]`, which the app.js sweep and the `TagInput` hook both
  look for) wrapped around the plain `<input>` that stays the form field and is
  the whole feature with JS off. A surface that quietly goes back to a bare text
  input would lose the pills with nothing failing — which is how members came to
  read a space as a tag separator in the first place.

  `/settings/tags/new` has its own coverage in `tag_new_live_test.exs`.
  """
  use VutuvWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Vutuv.Posts

  # The widget root plus the field it wraps, for one form field name.
  defp assert_tag_input(html, name) do
    doc = LazyHTML.from_document(html)

    assert [_] =
             Enum.to_list(
               LazyHTML.query(
                 doc,
                 ~s([data-tag-input] input[data-tag-input-field][name="#{name}"])
               )
             )
  end

  # The pill cap is opt-in per instance, so a surface without one must not
  # inherit the composer's.
  defp refute_pill_cap(html) do
    doc = LazyHTML.from_document(html)

    assert [] = Enum.to_list(LazyHTML.query(doc, "[data-tag-input][data-max]"))
  end

  test "the sign-up landing page", %{conn: conn} do
    html = conn |> get(~p"/") |> html_response(200)

    assert_tag_input(html, "user[tag_list]")
    refute_pill_cap(html)
  end

  test "the invitation form", %{conn: conn} do
    {conn, _user} = create_and_login_user(conn)

    html = conn |> get(~p"/system/invitations/new") |> html_response(200)

    assert_tag_input(html, "invitation_request[tag_list]")
    refute_pill_cap(html)
  end

  test "both tag fields on the job posting form", %{conn: conn} do
    {conn, _user} = create_and_login_user(conn)
    {:ok, live, _html} = live(conn, ~p"/jobs/new")

    for name <- ~w(required_tags nice_to_have_tags) do
      assert has_element?(
               live,
               ~s([data-tag-input] input[data-tag-input-field][name="job_posting[#{name}]"])
             )
    end
  end

  test "the post composer", %{conn: conn} do
    {conn, _user} = create_and_login_user(conn)
    {:ok, live, _html} = live(conn, ~p"/feed")

    render_click(live, "open-composer")

    assert has_element?(live, ~s([data-tag-input] input[data-tag-input-field][name="post[tags]"]))
  end

  test "the post composer is the one surface with a pill cap", %{conn: conn} do
    {conn, _user} = create_and_login_user(conn)
    {:ok, live, _html} = live(conn, ~p"/feed")

    render_click(live, "open-composer")

    # A post takes five tags (issue #1237), so its box refuses the sixth pill
    # and says why — `data-max` and the translated sentence beside it are what
    # `assets/js/tag_input.js` reads. The cap is per instance: the fields above
    # take as many tags as a member types, so a hardcoded 5 in the component or
    # the JS would silently cap them too.
    assert has_element?(
             live,
             ~s([data-tag-input][data-max="#{Posts.max_tags_per_post()}"][data-limit-message])
           )

    assert render(live) =~ "At most #{Posts.max_tags_per_post()} tags"
  end

  test "the pill cap explains itself in German", %{conn: conn} do
    # The member has no locale of their own, so the browser's Accept-Language
    # decides — the way a real German visitor arrives.
    {conn, user} = create_and_login_user(conn)
    user |> Ecto.Changeset.change(%{locale: nil}) |> Vutuv.Repo.update!()

    {:ok, live, _html} =
      conn
      |> recycle()
      |> put_req_header("accept-language", "de-DE,de;q=0.9")
      |> live(~p"/feed")

    render_click(live, "open-composer")

    assert render(live) =~ "Höchstens #{Posts.max_tags_per_post()} Tags"
  end
end
