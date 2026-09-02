defmodule VutuvWeb.EmbeddedSubjectGateTest do
  @moduledoc """
  An embedded LiveView must re-authorize its **subject**, not only its viewer.

  A controller that embeds a LiveView with `live_render/3` hands it a curated
  session map: signed, **not** encrypted, bound to no user and good for days
  (`Phoenix.LiveView.Static`'s 14-day `@max_session_age`). The controller's own
  request was gated — `VutuvWeb.Plug.EnsureActivated` for a profile — but the
  socket that joins later carries only that map, and a rejoin is ordinary: a
  deploy reconnects every open tab, and the tokens sit in the page source of any
  render the holder could once load.

  The viewer half of this is well covered (`init_assigns_test.exs` re-resolves
  identity from the session token on every mount). The subject half has now been
  the bug three times — #1034, #1036, and the post permalink's conversation —
  each time in a different LiveView, each time fixed alone. So this is the
  chokepoint: one list of every embedded LiveView whose session names somebody
  *other than the viewer*, and one assertion that a withheld subject renders
  nothing. A new embedded LiveView carrying a subject id belongs in `@carriers`.
  """
  use VutuvWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Vutuv.Moderation
  alias Vutuv.Posts

  # Each entry: the LiveView, the session key naming its subject, and a label.
  # `VutuvWeb.PostLive.Thread` carries a post id rather than a member id and is
  # covered by `post_thread_live_test.exs`; everything here names a member.
  @carriers [
    {VutuvWeb.UserProfileLive, "profile_user_id", "the profile"},
    {VutuvWeb.CVLive, "profile_user_id", "the CV builder"}
  ]

  # The three ways this installation withholds a profile, and the status the
  # HTML page answers for each (`Moderation.withheld_status/1`).
  @withholdings [
    {[frozen_at: NaiveDateTime.utc_now(:second)], "frozen pending review"},
    {[deactivated_at: NaiveDateTime.utc_now(:second)], "permanently deactivated"},
    {[suspended_until: NaiveDateTime.add(NaiveDateTime.utc_now(:second), 7, :day)], "suspended"}
  ]

  for {live_view, key, label} <- @carriers,
      {attrs, how} <- @withholdings do
    test "#{label} renders nothing for a member #{how}" do
      member =
        insert_activated_user(
          [first_name: "Withheld", last_name: "Member"] ++ unquote(Macro.escape(attrs))
        )

      # The premise: this really is a member the site withholds, so a failure
      # below is the socket serving them and not a fixture that never hid.
      refute Moderation.profile_visible_to?(member, nil)

      session = %{unquote(key) => member.id, "locale" => "en"}

      assert render_withheld(unquote(live_view), session) == :withheld,
             "#{unquote(label)} served a withheld member over the socket"
    end
  end

  test "the profile still renders for a member the site does not withhold" do
    member = insert_activated_user(first_name: "Ordinary", last_name: "Member")
    {:ok, post} = Posts.create_post(member, %{body: "Ganz normal"})

    assert {:ok, _view, html} =
             live_isolated(build_conn(), VutuvWeb.UserProfileLive,
               session: %{"profile_user_id" => member.id, "locale" => "en"}
             )

    assert html =~ "Ordinary"
    assert post.id
  end

  # A gate may answer by refusing to mount or by rendering none of the member's
  # data; both are withholding, and which one a LiveView picks is its own
  # business. Anything else — a successful mount whose HTML names them — is not.
  defp render_withheld(live_view, session) do
    case live_isolated(build_conn(), live_view, session: session) do
      {:ok, _view, html} -> if html =~ "Withheld", do: {:served, html}, else: :withheld
      {:error, _reason} -> :withheld
    end
  rescue
    # A gate that refuses by raising (the profile answers the way its controller
    # would have, with the 404 the router turns an Ecto miss into) withholds
    # just as surely as one that renders an empty page.
    _error -> :withheld
  catch
    :exit, _reason -> :withheld
  end
end
