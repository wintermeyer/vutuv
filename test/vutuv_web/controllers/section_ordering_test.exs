defmodule VutuvWeb.SectionOrderingTest do
  @moduledoc """
  The controller-owned half of profile-section ordering: new entries append to
  the owner's chosen order, and the owner — not a visitor — gets the embedded
  reorder tool (VutuvWeb.SectionReorderLive) on every orderable section page.
  The reordering interactions themselves live in section_reorder_live_test.exs;
  the position bookkeeping in ordering_test.exs.
  """
  use VutuvWeb.ConnCase, async: true

  import Vutuv.Factory

  alias Vutuv.Profiles.Address
  alias Vutuv.Profiles.PhoneNumber
  alias Vutuv.Profiles.SocialMediaAccount

  describe "the embedded reorder tool" do
    test "the owner gets it on every orderable section page", %{conn: conn} do
      {conn, owner} = create_and_login_user(conn)
      insert(:phone_number, user: owner)
      insert(:address, user: owner)
      insert(:social_media_account, user: owner)
      insert(:email, user: owner)
      insert(:url, user: owner)

      for section <- ~w(phone_numbers addresses social_media_accounts emails links) do
        html = conn |> get("/#{owner.active_slug}/#{section}") |> html_response(200)

        assert html =~ ~s(phx-hook="Reorder"),
               "expected the embedded reorder tool on the owner's #{section} page"
      end
    end

    test "a visitor never gets it", %{conn: conn} do
      {conn, _visitor} = create_and_login_user(conn)
      owner = insert_activated_user()
      insert(:phone_number, user: owner)
      insert(:url, user: owner)

      for section <- ~w(phone_numbers links) do
        html = conn |> get("/#{owner.active_slug}/#{section}") |> html_response(200)
        refute html =~ ~s(phx-hook="Reorder")
      end
    end
  end

  describe "new entries append to the chosen order" do
    test "phone numbers", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      post(conn, ~p"/#{user}/phone_numbers",
        phone_number: %{"value" => "0261-123456", "number_type" => "Work"}
      )

      post(conn, ~p"/#{user}/phone_numbers",
        phone_number: %{"value" => "0261-654321", "number_type" => "Work"}
      )

      assert Repo.all(PhoneNumber.ordered(Ecto.assoc(user, :phone_numbers)))
             |> Enum.map(& &1.position) == [1, 2]
    end

    test "addresses", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      post(conn, ~p"/#{user}/addresses",
        address: %{"description" => "Home", "country" => "Germany"}
      )

      post(conn, ~p"/#{user}/addresses",
        address: %{"description" => "Work", "country" => "Germany"}
      )

      assert Repo.all(Address.ordered(Ecto.assoc(user, :addresses)))
             |> Enum.map(& &1.position) == [1, 2]
    end

    test "social media accounts", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      post(conn, ~p"/#{user}/social_media_accounts",
        social_media_account: %{"provider" => "GitHub", "value" => "octocat"}
      )

      post(conn, ~p"/#{user}/social_media_accounts",
        social_media_account: %{"provider" => "Twitter", "value" => "jack"}
      )

      assert Repo.all(SocialMediaAccount.ordered(Ecto.assoc(user, :social_media_accounts)))
             |> Enum.map(& &1.position) == [1, 2]
    end
  end
end
