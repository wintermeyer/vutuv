defmodule VutuvWeb.SignupTrapRegistrationTest do
  @moduledoc """
  A sign-up `Vutuv.SignupTrap` recognises must look like any other from the
  outside (the same PIN screen, the same pin cookie) while nothing happens
  behind it: no account, no mail, only an entry for the weekly report.
  """
  use VutuvWeb.ConnCase, async: true

  alias Vutuv.Accounts.Email
  alias Vutuv.SignupTrap.Entry

  defp trapped_params(overrides \\ %{}) do
    n = System.unique_integer([:positive])

    Map.merge(
      %{
        "emails" => %{"0" => %{"value" => "bot#{n}@trap.example"}},
        "first_name" => "ihclfjep",
        "last_name" => "ihclfjep",
        "gender" => "male",
        "tag_list" => @registration_tags
      },
      overrides
    )
  end

  defp address(params), do: params["emails"]["0"]["value"]

  defp accounts_with(address), do: Repo.aggregate(where(Email, value: ^address), :count)

  test "a trapped sign-up gets the PIN screen and nothing else", %{conn: conn} do
    params = trapped_params()

    conn =
      conn
      |> put_req_header("user-agent", "BotBrowser/1.0")
      |> post(~p"/new_registration", user: params)

    body = html_response(conn, 200)
    assert body =~ "Enter the PIN from the email"
    assert body =~ address(params)
    assert conn.resp_cookies["_vutuv_login_pin"]

    assert accounts_with(address(params)) == 0
    refute_received {:email, _}

    assert [entry] = Repo.all(where(Entry, email: ^address(params)))
    assert entry.rule == "same_lowercase_name"
    assert entry.first_name == "ihclfjep"
    assert entry.ip_address == "127.0.0.1"
    assert entry.user_agent == "BotBrowser/1.0"
    assert entry.params["gender"] == "male"
  end

  test "a real sign-up still gets its account and its PIN", %{conn: conn} do
    params = registration_attrs("real")

    conn |> post(~p"/new_registration", user: params) |> html_response(200)

    assert accounts_with(address(params)) == 1
    assert_received {:email, _pin_mail}
    refute Repo.exists?(where(Entry, email: ^address(params)))
  end

  test "an invalid form is refused the ordinary way before the trap looks at it", %{conn: conn} do
    params = trapped_params(%{"tag_list" => ""})

    conn |> post(~p"/new_registration", user: params) |> html_response(422)

    refute Repo.exists?(where(Entry, email: ^address(params)))
  end

  test "a member whose address the bot typed hears nothing either", %{conn: conn} do
    member = insert(:activated_user)
    email = insert(:email, user: member).value

    conn
    |> post(~p"/new_registration",
      user: trapped_params(%{"emails" => %{"0" => %{"value" => email}}})
    )
    |> html_response(200)

    refute_received {:email, _}
    assert Repo.exists?(where(Entry, email: ^email))
  end
end
