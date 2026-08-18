defmodule Vutuv.IdentityTest do
  use Vutuv.DataCase, async: true

  import Ecto.Query
  import Vutuv.Factory
  import Vutuv.Identity.Query

  alias Vutuv.Identity
  alias Vutuv.Posts.Post

  describe "Identity protocol, User" do
    test "kind/id/handle/display_name" do
      user = insert(:user, honorific_prefix: "Dr.", first_name: "Max", last_name: "Muster")

      assert Identity.kind(user) == :user
      assert Identity.id(user) == user.id
      assert Identity.handle(user) == user.username
      assert Identity.display_name(user) == "Dr. Max Muster"
    end

    test "path and ref build from the handle" do
      user = insert(:user)

      assert Identity.path(user) == "/" <> user.username

      assert Identity.ref(user) == %{
               name: Identity.display_name(user),
               username: user.username,
               url: VutuvWeb.Endpoint.url() <> "/" <> user.username
             }
    end

    test "image, topic and ap_type" do
      user = insert(:user, avatar: "some-token")

      assert Identity.image(user) == "some-token"
      assert Identity.topic(user) == "user:#{user.id}"
      assert Identity.ap_type(user) == "Person"
    end

    test "hidden? follows the anonymous profile visibility" do
      refute Identity.hidden?(insert(:activated_user))
      # Unconfirmed members are not publicly visible.
      assert Identity.hidden?(insert(:user))

      frozen =
        insert(:activated_user,
          frozen_at: NaiveDateTime.truncate(NaiveDateTime.utc_now(), :second)
        )

      assert Identity.hidden?(frozen)
    end
  end

  describe "Identity protocol, Organization" do
    test "kind/id/display_name" do
      organization = insert(:organization, name: "Acme GmbH")

      assert Identity.kind(organization) == :organization
      assert Identity.id(organization) == organization.id
      assert Identity.display_name(organization) == "Acme GmbH"
    end

    test "handle and path prefer the opt-in root handle" do
      bare = insert(:organization)
      handled = insert(:organization, username: "acme-handle")

      assert Identity.handle(bare) == nil
      assert Identity.path(bare) == "/organizations/#{bare.slug}"
      assert Identity.handle(handled) == "acme-handle"
      assert Identity.path(handled) == "/acme-handle"
    end

    test "ref carries name, slug and the canonical URL" do
      organization = insert(:organization)

      assert Identity.ref(organization) == %{
               name: organization.name,
               slug: organization.slug,
               url: VutuvWeb.Endpoint.url() <> "/organizations/#{organization.slug}"
             }
    end

    test "image, topic and ap_type" do
      organization = insert(:organization, logo: "logo-token")

      assert Identity.image(organization) == "logo-token"
      assert Identity.topic(organization) == "organization:#{organization.id}"
      assert Identity.ap_type(organization) == "Organization"
    end

    test "hidden? follows the public page visibility" do
      refute Identity.hidden?(insert(:organization))
      assert Identity.hidden?(insert(:organization, status: "pending"))

      frozen =
        insert(:organization,
          frozen_at: NaiveDateTime.truncate(NaiveDateTime.utc_now(), :second)
        )

      assert Identity.hidden?(frozen)
    end
  end

  describe "party_is/2" do
    test "matches only the given party's rows, whichever kind" do
      user = insert(:activated_user)
      organization = insert(:organization)
      user_post = insert(:post, user: user)
      organization_post = insert(:post, user: nil, organization: organization)

      found_for_user =
        Repo.all(from(p in Post, where: party_is(p, user), select: p.id))

      found_for_organization =
        Repo.all(from(p in Post, where: party_is(p, organization), select: p.id))

      assert found_for_user == [user_post.id]
      assert found_for_organization == [organization_post.id]
    end
  end

  describe "join_party/3 + shown_party/2" do
    test "keeps every member row and only publicly visible pages" do
      member_post = insert(:post, user: insert(:user))
      shown_page_post = insert(:post, user: nil, organization: insert(:organization))

      frozen_page =
        insert(:organization,
          frozen_at: NaiveDateTime.truncate(NaiveDateTime.utc_now(), :second)
        )

      _hidden_page_post = insert(:post, user: nil, organization: frozen_page)

      shown =
        from(p in Post)
        |> join_party(:user_id, :organization_id)
        |> where([p, u, o], shown_party(u, o))
        |> select([p], p.id)
        |> Repo.all()

      assert member_post.id in shown
      assert shown_page_post.id in shown
      assert length(shown) == 2
    end
  end
end
