defmodule VutuvWeb.RecruiterSubscriptionControllerTest do
  use VutuvWeb.ConnCase

  alias Vutuv.Recruiting.RecruiterSubscription

  defp valid_params(package) do
    %{
      "recruiter_package_id" => package.id,
      "line1" => "Some Company",
      "street" => "123 Main St",
      "zip_code" => "12345",
      "city" => "Berlin",
      "country" => "Germany"
    }
  end

  describe "create authorization" do
    test "a logged-out visitor cannot create a subscription", %{conn: conn} do
      {logged_in, user} = create_and_login_user(conn)
      package = insert(:recruiter_package)

      # Build a fresh, anonymous conn (no session) but keep the resolvable slug.
      anon_conn = Phoenix.ConnTest.build_conn() |> Plug.Test.init_test_session(%{})

      result =
        post(anon_conn, ~p"/users/#{user}/recruiter_subscriptions",
          recruiter_subscription: valid_params(package)
        )

      assert result.status == 403
      assert Vutuv.Repo.all(RecruiterSubscription) == []

      # sanity: the owner is the only one who can reach the form
      assert html_response(get(logged_in, ~p"/users/#{user}/recruiter_subscriptions/new"), 200)
    end

    test "a logged-in user cannot create a subscription for someone else", %{conn: conn} do
      {conn, _attacker} = create_and_login_user(conn)

      {:ok, victim} =
        Vutuv.Accounts.register_user(conn, %{
          "emails" => %{"0" => %{"value" => "victim@example.com"}},
          "first_name" => "victim"
        })

      # The victim's detail pages are only reachable once validated; without this
      # EnsureValidated would 404 before AuthUser ever runs, masking the auth check.
      victim =
        victim
        |> Ecto.Changeset.change(%{validated?: true})
        |> Repo.update!()

      package = insert(:recruiter_package)

      result =
        post(conn, ~p"/users/#{victim}/recruiter_subscriptions",
          recruiter_subscription: valid_params(package)
        )

      assert result.status == 403
      assert Vutuv.Repo.all(RecruiterSubscription) == []
    end
  end

  describe "create mass-assignment protection" do
    test "smuggling paid=true does not yield a paid subscription", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      package = insert(:recruiter_package)

      params =
        package
        |> valid_params()
        |> Map.merge(%{
          "paid" => "true",
          "paid_on" => "2020-01-01",
          "invoice_number" => "FREE-RIDE",
          "invoiced_on" => "2020-01-01"
        })

      post(conn, ~p"/users/#{user}/recruiter_subscriptions", recruiter_subscription: params)

      [sub] = Vutuv.Repo.all(RecruiterSubscription)
      refute sub.paid
      assert sub.paid_on == nil
      assert sub.invoice_number == nil
      assert sub.invoiced_on == nil
    end
  end
end
