defmodule Vutuv.Imports.ConnectionMatchTest do
  @moduledoc """
  Which vutuv members a LinkedIn contact list resolves to (issue #1476). Only
  exact identifiers count, and the email half deliberately reaches **public**
  addresses only — the same line `Vutuv.Search.search_by_email/1` holds, because
  a private address must not even confirm that an account exists.
  """
  use Vutuv.DataCase

  alias Vutuv.Imports.ConnectionMatch
  alias Vutuv.Social

  defp member(attrs \\ []) do
    insert_activated_user(attrs)
  end

  defp with_email(user, value, opts \\ []) do
    insert(:email,
      user: user,
      value: value,
      public?: Keyword.get(opts, :public?, true),
      md5sum: :crypto.hash(:md5, value) |> Base.encode16(case: :lower)
    )

    user
  end

  defp with_linkedin(user, handle) do
    insert(:social_media_account, user: user, provider: "LinkedIn", value: handle)
    user
  end

  defp email_contact(value), do: %{email: value, linkedin: nil}
  defp linkedin_contact(value), do: %{email: nil, linkedin: value}

  describe "find/2 — email" do
    test "finds the member behind a public address", %{} do
      viewer = member()
      target = member() |> with_email("conni@example.com")

      assert [%{user: found, via: :email}] =
               ConnectionMatch.find(viewer, [email_contact("conni@example.com")])

      assert found.id == target.id
    end

    test "does not find a member whose address is private" do
      viewer = member()
      _target = member() |> with_email("secret@example.com", public?: false)

      assert [] = ConnectionMatch.find(viewer, [email_contact("secret@example.com")])
    end

    test "an unconfirmed account is not a member yet" do
      viewer = member()
      pending = insert(:user)
      with_email(pending, "pending@example.com")

      assert [] = ConnectionMatch.find(viewer, [email_contact("pending@example.com")])
    end

    test "a deactivated account stays out of the results" do
      viewer = member()

      member(deactivated_at: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second))
      |> with_email("gone@example.com")

      assert [] = ConnectionMatch.find(viewer, [email_contact("gone@example.com")])
    end
  end

  describe "find/2 — LinkedIn profile" do
    test "finds the member who links that LinkedIn profile" do
      viewer = member()
      target = member() |> with_linkedin("conni-contact")

      assert [%{user: found, via: :linkedin}] =
               ConnectionMatch.find(viewer, [linkedin_contact("conni-contact")])

      assert found.id == target.id
    end

    test "the comparison ignores case on both sides" do
      viewer = member()
      target = member() |> with_linkedin("Conni-Contact")

      assert [%{user: found}] = ConnectionMatch.find(viewer, [linkedin_contact("conni-contact")])
      assert found.id == target.id
    end

    test "another provider with the same handle is not a LinkedIn profile" do
      viewer = member()
      insert(:social_media_account, user: member(), provider: "GitHub", value: "conni-contact")

      assert [] = ConnectionMatch.find(viewer, [linkedin_contact("conni-contact")])
    end
  end

  describe "find/2 — the result set" do
    test "one member matched twice is listed once, and the address wins the label" do
      viewer = member()

      target =
        member()
        |> with_email("conni@example.com")
        |> with_linkedin("conni")

      assert [%{user: found, via: :email}] =
               ConnectionMatch.find(viewer, [
                 %{email: "conni@example.com", linkedin: "conni"}
               ])

      assert found.id == target.id
    end

    test "the member doing the lookup is never their own contact" do
      viewer = member() |> with_email("me@example.com")

      assert [] = ConnectionMatch.find(viewer, [email_contact("me@example.com")])
    end

    test "a blocked pair does not find each other" do
      viewer = member()
      blocked = member() |> with_email("blocked@example.com")
      {:ok, _} = Social.block_user(viewer, blocked)

      assert [] = ConnectionMatch.find(viewer, [email_contact("blocked@example.com")])
    end

    test "someone the member already follows stays in the list" do
      viewer = member()
      target = member() |> with_email("followed@example.com")
      follow!(viewer, target)

      assert [%{user: found}] =
               ConnectionMatch.find(viewer, [email_contact("followed@example.com")])

      assert found.id == target.id
    end

    test "results are sorted by name" do
      viewer = member()
      member(first_name: "Zoe", last_name: "Adams") |> with_email("zoe@example.com")
      member(first_name: "Anna", last_name: "Zeller") |> with_email("anna@example.com")

      assert [%{user: first}, %{user: second}] =
               ConnectionMatch.find(viewer, [
                 email_contact("zoe@example.com"),
                 email_contact("anna@example.com")
               ])

      assert first.last_name == "Adams"
      assert second.last_name == "Zeller"
    end

    test "an empty contact list asks the database nothing and finds nobody" do
      assert [] = ConnectionMatch.find(member(), [])
    end
  end
end
