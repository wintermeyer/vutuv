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

  # The sign-up form is deliberately NOT on this list any more. Its topics step
  # (`VutuvWeb.RegistrationLive`) says how many members carry each topic and how
  # many the selection reaches, so the chosen topics have to live in socket
  # state — and this component is `phx-update="ignore"` with its pills owned by
  # the browser, which is the opposite arrangement. It keeps the same comma
  # splitting (`Vutuv.Tags.parse_tag_names/1`), so what a member types behaves
  # the same either way.

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
