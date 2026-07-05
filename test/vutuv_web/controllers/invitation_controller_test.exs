defmodule VutuvWeb.InvitationControllerTest do
  use VutuvWeb.ConnCase, async: false

  import Swoosh.TestAssertions

  alias Vutuv.Accounts.Email
  alias Vutuv.Invitations
  alias Vutuv.Invitations.Invitation
  alias Vutuv.Social

  defp form_params(overrides \\ %{}) do
    Map.merge(
      %{
        "first_name" => "Jane",
        "last_name" => "Doe",
        "email" => "jane@example.com",
        "locale" => "en"
      },
      overrides
    )
  end

  describe "new" do
    test "requires a login", %{conn: conn} do
      conn = get(conn, ~p"/system/invitations/new")
      assert redirected_to(conn) == ~p"/"
    end

    test "renders the form posting to the create URL", %{conn: conn} do
      {conn, _me} = create_and_login_user(conn)
      conn = get(conn, ~p"/system/invitations/new")

      response = html_response(conn, 200)
      # Assert the *rendered* action so a retired URL can't hide behind a
      # ConnTest that only POSTs a hand-built path (see the CLAUDE.md note).
      assert response =~ ~s(action="/system/invitations")
      assert response =~ "Invite a friend"
      # The word-of-mouth thank-you note.
      assert response =~ "Thank you for spreading the word"
    end
  end

  describe "create" do
    setup %{conn: conn} do
      {conn, me} = create_and_login_user(conn)
      %{conn: conn, me: me}
    end

    test "a first invitation records the row, mails it, and shows the sent email", %{
      conn: conn,
      me: me
    } do
      conn = post(conn, ~p"/system/invitations", invitation_request: form_params())

      response = html_response(conn, 200)
      assert response =~ "on its way"
      # The result page embeds the rendered email (what the recipient receives)
      # in an iframe, with the recipient + subject shown.
      assert response =~ "<iframe"
      assert response =~ "jane@example.com"

      assert [invitation] = Repo.all(Invitation)
      assert invitation.user_id == me.id
      assert_email_sent(fn email -> assert {_name, "jane@example.com"} = hd(email.to) end)
    end

    test "a repeat address shows the same sent page but sends nothing new", %{conn: conn} do
      first = post(conn, ~p"/system/invitations", invitation_request: form_params())
      assert html_response(first, 200) =~ "<iframe"
      assert_email_sent()

      second = post(conn, ~p"/system/invitations", invitation_request: form_params())
      # Same page (200, the preview), so a repeat is indistinguishable from a
      # first send; but no second email and no second row.
      assert html_response(second, 200) =~ "<iframe"
      refute_email_sent()
      assert Repo.aggregate(Invitation, :count) == 1
    end

    test "an invalid form re-renders with a 422", %{conn: conn} do
      conn =
        post(conn, ~p"/system/invitations",
          invitation_request: form_params(%{"first_name" => "", "last_name" => ""})
        )

      assert html_response(conn, 422) =~ "Invite a friend"
      refute_email_sent()
    end
  end

  describe "the invite link on the landing page" do
    test "prefills the sign-up form and stamps the first visit", %{conn: conn} do
      inviter = insert(:user)

      Repo.insert!(%Invitation{
        user_id: inviter.id,
        email_hash: Invitations.hash_email("jane@example.com"),
        locale: "en"
      })

      conn =
        get(
          conn,
          ~p"/?#{[first_name: "Jane", last_name: "Doe", email: "jane@example.com", gender: "female"]}"
        )

      response = html_response(conn, 200)
      assert response =~ ~s(value="Jane")
      assert response =~ ~s(value="jane@example.com")

      assert Repo.one(Invitation).visited_at
    end
  end

  describe "auto-follow on registration" do
    test "the inviter follows the newcomer once they register with the invited address", %{
      conn: conn
    } do
      inviter = insert(:user)

      Repo.insert!(%Invitation{
        user_id: inviter.id,
        email_hash: Invitations.hash_email("invitee@example.com"),
        locale: "en",
        auto_follow: true
      })

      params = %{
        "emails" => %{"0" => %{"value" => "invitee@example.com"}},
        "first_name" => "Invited",
        "tag_list" => "alpha-tag beta-tag gamma-tag"
      }

      conn = post(conn, ~p"/new_registration", user: params)
      assert html_response(conn, 200)

      newcomer = Repo.get_by(Email, value: "invitee@example.com")
      assert is_binary(Social.follow_id(inviter.id, newcomer.user_id))
    end
  end
end
