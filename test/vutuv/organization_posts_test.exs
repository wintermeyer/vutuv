defmodule Vutuv.OrganizationPostsTest do
  @moduledoc """
  Posts published in an organization's name (issue #1334): the three-column
  authorship, who may publish, and — the part that is easy to get wrong — that
  none of the **personal** scopes pick such a post up. A member's own profile,
  archive and feed must not show what they published for an organization; that
  association is exactly what `acting_user_id` keeps internal.

  `async: false` for the same reason the other organization suites are: the
  helpers flip the global `:verify_organization_domains` flag.
  """
  use Vutuv.DataCase, async: false

  import Vutuv.OrganizationsHelpers

  alias Vutuv.Organizations
  alias Vutuv.Posts
  alias Vutuv.Posts.Post
  alias Vutuv.Repo

  setup do
    Application.put_env(:vutuv, :verify_organization_domains, true)

    on_exit(fn ->
      Application.put_env(:vutuv, :verify_organization_domains, false)
      Application.delete_env(:vutuv, :organizations_dns_resolver)
    end)

    :ok
  end

  # An organization plus its owner, who has been granted the publisher role
  # (never implied — see issue #1333).
  defp publishing_organization do
    {organization, owner} = active_organization()
    {:ok, _} = Organizations.add_role(organization, owner, "publisher", owner)
    {organization, owner}
  end

  describe "create_organization_post/3" do
    # An organization post fills `organization_id`, never `user_id` — so the
    # attach step's `i.user_id == ^post.user_id` compared a column with nil,
    # which Ecto refuses outright rather than matching nothing. The composer
    # offers photo upload whether or not you are acting as a page, so this was a
    # 500 on the ordinary path of posting a picture in a page's name. Calibrated
    # against the un-fixed code, where it raises rather than failing.
    test "carries photos, which belong to the member who uploaded them" do
      {organization, owner} = publishing_organization()

      tmp = Path.join(System.tmp_dir!(), "org-photo-#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp)
      on_exit(fn -> File.rm_rf(tmp) end)

      source = Path.join(tmp, "photo.jpg")
      {:ok, image} = Image.new(32, 32, color: [200, 30, 30])
      {:ok, _} = Image.write(image, source)

      {:ok, pending} = Posts.create_pending_image(owner, source, "photo.jpg")

      assert {:ok, post} =
               Posts.create_organization_post(organization, owner, %{
                 body: "Unser neues Büro.",
                 image_ids: [pending.id]
               })

      assert post.organization_id == organization.id
      assert post.user_id == nil
      assert [attached] = Repo.preload(post, :images).images
      assert attached.id == pending.id
      assert attached.user_id == owner.id
    end

    test "refuses a photo uploaded by somebody else" do
      {organization, owner} = publishing_organization()
      stranger = insert(:activated_user)
      foreign = insert(:post_image, user: stranger, post: nil)

      assert {:error, :invalid_images} =
               Posts.create_organization_post(organization, owner, %{
                 body: "Nicht meins.",
                 image_ids: [foreign.id]
               })
    end

    test "records the organization as author and the member as who pressed publish" do
      {organization, owner} = publishing_organization()

      assert {:ok, post} =
               Posts.create_organization_post(organization, owner, %{body: "We are hiring."})

      assert post.organization_id == organization.id
      assert post.acting_user_id == owner.id
      assert is_nil(post.user_id)

      # The public author is the organization; the human is internal.
      assert %Organizations.Organization{} = author = Posts.author(post)
      assert author.id == organization.id
      assert Posts.author_id(post) == organization.id
      assert Posts.organization_post?(post)
    end

    test "refuses a member without the publisher role, whatever else they hold" do
      {organization, owner} = active_organization()
      admin = insert(:activated_user)
      {:ok, _} = Organizations.add_role(organization, admin, "admin", owner)
      stranger = insert(:activated_user)

      # The owner has not granted themselves publisher yet, and an admin
      # administers the page rather than speaking for it.
      assert {:error, :forbidden} =
               Posts.create_organization_post(organization, owner, %{body: "x"})

      assert {:error, :forbidden} =
               Posts.create_organization_post(organization, admin, %{body: "x"})

      assert {:error, :forbidden} =
               Posts.create_organization_post(organization, stranger, %{body: "x"})
    end

    test "the database refuses a post that claims both authors or neither" do
      {organization, owner} = publishing_organization()

      both = %Post{
        user_id: owner.id,
        organization_id: organization.id,
        body: "",
        published_on: Vutuv.BerlinTime.today()
      }

      assert_raise Ecto.ConstraintError, ~r/posts_exactly_one_author/, fn ->
        Repo.insert!(both)
      end

      neither = %Post{body: "", published_on: Vutuv.BerlinTime.today()}

      assert_raise Ecto.ConstraintError, ~r/posts_exactly_one_author/, fn ->
        Repo.insert!(neither)
      end
    end
  end

  describe "the author's own surfaces do not leak the organization post" do
    setup do
      {organization, owner} = publishing_organization()

      {:ok, personal} = Posts.create_post(owner, %{body: "Something of my own."})

      {:ok, organization_post} =
        Posts.create_organization_post(organization, owner, %{body: "Something in our name."})

      %{owner: owner, organization: organization, personal: personal, org_post: organization_post}
    end

    test "the member's post archive lists only their own", ctx do
      %{owner: owner, personal: personal, org_post: org_post} = ctx
      {entries, _total} = Posts.author_posts_page(owner, owner, %{})
      ids = Enum.map(entries, & &1.post.id)

      assert personal.id in ids
      refute org_post.id in ids
    end

    test "the member's feed does not carry what they published for the organization", ctx do
      %{owner: owner, personal: personal, org_post: org_post} = ctx
      ids = owner |> Posts.feed_page() |> Map.fetch!(:entries) |> Enum.map(& &1.post.id)

      assert personal.id in ids
      refute org_post.id in ids
    end
  end

  describe "editing and deleting follows the role, not the person" do
    test "every current publisher may act as the author; a departed one may not" do
      {organization, owner} = publishing_organization()
      other = insert(:activated_user)
      {:ok, _} = Organizations.add_role(organization, other, "publisher", owner)
      outsider = insert(:activated_user)

      {:ok, post} = Posts.create_organization_post(organization, owner, %{body: "Ours."})

      assert Posts.author?(post, owner)
      # Not the member who pressed publish — anyone the organization currently
      # trusts to speak for it, because the post belongs to the organization.
      assert Posts.author?(post, other)
      refute Posts.author?(post, outsider)

      # Withdrawing the role takes the power away at once, without touching the
      # stored `acting_user_id`.
      {:ok, _} = Organizations.set_roles(organization, other, [], owner)
      refute Posts.author?(Repo.reload!(post) |> Repo.preload(:organization), other)
    end
  end
end
