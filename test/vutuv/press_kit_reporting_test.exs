defmodule Vutuv.PressKitReportingTest do
  @moduledoc """
  Reporting a press photo or a logo variant, with or without an account
  (issue #2089).

  #2084 gave the kind a takedown, which opened the report gate for a **member's**
  press picture and left three things broken behind it, each measured before it
  was fixed:

    * `Vutuv.Images.preview_url/1` and `bytes_path/1` raised `BadMapError` for
      the kind — they index the profile-column map by kind and dereference the
      `nil` that comes back — so the report form and the admin case page's
      picture endpoint both 500ed, which is exactly the step an uphold needs;
    * a **page's** press picture was takedown-ready and un-reportable, because
      `Vutuv.Moderation`'s `owner_id/1` read `images.user_id` alone and that
      column is NULL for a page's row;
    * the outside notice form could not name a press picture at all: neither the
      proxy addresses nor a page's section page resolved.

  Not async: the freeze moves files on disk.
  """
  use Vutuv.DataCase, async: false

  import Vutuv.ImageHelpers, only: [put_press_picture: 1, put_press_picture: 2]
  import Vutuv.OrganizationsHelpers, only: [active_organization: 0]
  import Vutuv.WebPushHelpers, only: [put_config: 2]

  alias Vutuv.Images
  alias Vutuv.Moderation
  alias Vutuv.Moderation.ContentUrl
  alias Vutuv.PressKit
  alias Vutuv.Repo

  @copyright %{"category" => "copyright", "note" => "Mein Foto.", "good_faith?" => "true"}
  @house_rules %{"category" => "other", "note" => "Werbung."}

  setup do
    # A page is claimed through the DNS check, which the test env leaves off.
    put_config(:verify_organization_domains, true)

    reporter = insert(:activated_user)
    {:ok, reporter: reporter}
  end

  describe "a member's press picture" do
    test "is reportable and its preview URL is the picture, not a raise" do
      member = insert(:activated_user)
      image = put_press_picture(member, alt: "Am Schreibtisch")

      assert Images.takedown_ready?(image)
      assert Images.preview_url(image) =~ "/system/press_kit/#{image.token}/"
    end

    test "a copyright notice takes it off the page at once", %{reporter: reporter} do
      member = insert(:activated_user)
      insert(:email, user: member)
      image = put_press_picture(member)

      assert {:ok, case_record} = Moderation.report_content(reporter, image, @copyright)
      assert case_record.owner_id == member.id

      held = Repo.get!(Vutuv.Images.Image, image.id)
      refute is_nil(held.frozen_at)
      refute PressKit.visible_to?(held, member)
    end

    test "a house-rule report only flags it", %{reporter: reporter} do
      member = insert(:activated_user)
      image = put_press_picture(member)

      assert {:ok, case_record} = Moderation.report_content(reporter, image, @house_rules)
      assert case_record.status == "flagged"
      assert Repo.get!(Vutuv.Images.Image, image.id).frozen_at == nil
    end

    test "its owner cannot report it", %{} do
      member = insert(:activated_user)
      image = put_press_picture(member)

      assert {:error, :own_content} = Moderation.report_content(member, image, @house_rules)
    end
  end

  describe "a page's press picture" do
    setup do
      {organization, owner} = active_organization()
      {:ok, organization: organization, page_owner: owner}
    end

    test "is reportable, and the case is carried by the member who claimed the page", %{
      reporter: reporter,
      organization: organization,
      page_owner: page_owner
    } do
      image = put_press_picture(organization)

      assert Images.takedown_ready?(image)
      assert Moderation.can_report?(reporter, image)

      assert {:ok, case_record} = Moderation.report_content(reporter, image, @copyright)
      assert case_record.owner_id == page_owner.id
    end

    test "the notice goes to the member who carries the case", %{
      reporter: reporter,
      organization: organization,
      page_owner: page_owner
    } do
      insert(:email, user: page_owner)
      image = put_press_picture(organization)
      flush_emails()

      assert {:ok, _case} = Moderation.report_content(reporter, image, @copyright)

      address = Vutuv.Accounts.first_email_value(page_owner)
      assert Enum.any?(flush_emails(), &match?([{_, ^address}], &1.to))
    end

    # The honest consequence of the clause above, and the same state a page's
    # own posts have been in since #1334: with nobody to strike there is no
    # case to open, so only an admin freeze can act.
    test "is not reportable once the member who claimed the page is gone", %{
      reporter: reporter,
      organization: organization,
      page_owner: page_owner
    } do
      image = put_press_picture(organization)
      assert Moderation.can_report?(reporter, image)

      {:ok, _} = Vutuv.Accounts.delete_user(page_owner)

      refute Moderation.can_report?(reporter, image)
      assert {:error, :not_allowed} = Moderation.report_content(reporter, image, @copyright)
    end

    test "a picture the AI gate is still holding is not reportable either", %{
      reporter: reporter,
      organization: organization
    } do
      image = put_press_picture(organization, moderation: "pending")

      refute Moderation.can_report?(reporter, image)
    end
  end

  describe "the outside notice form's URL" do
    test "resolves a proxy address to the picture" do
      member = insert(:activated_user)
      image = put_press_picture(member)

      for path <- [PressKit.url(image, "large"), PressKit.download_url(image)] do
        assert {:ok, resolved} = ContentUrl.resolve(url(path))
        assert resolved.id == image.id
      end
    end

    test "resolves a member's and a page's section page to its owner" do
      member = insert(:activated_user)
      {organization, _owner} = active_organization()

      assert {:ok, %Vutuv.Accounts.User{} = resolved} =
               ContentUrl.resolve(url(PressKit.page_path(member)))

      assert resolved.id == member.id

      assert {:ok, %Vutuv.Organizations.Organization{} = page} =
               ContentUrl.resolve(url(PressKit.page_path(organization)))

      assert page.id == organization.id
    end

    test "does not resolve a picture the AI gate is still holding" do
      member = insert(:activated_user)
      image = put_press_picture(member, moderation: "pending")

      assert {:error, :not_found} = ContentUrl.resolve(url(PressKit.url(image, "large")))
    end
  end

  describe "the admin's look at the reported picture" do
    test "answers with the bytes, held or not", %{reporter: reporter} do
      member = insert(:activated_user)
      insert(:email, user: member)

      tmp =
        Path.join(System.tmp_dir!(), "vutuv_press_report_#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp)
      put_config(:uploads_dir_prefix, tmp)
      on_exit(fn -> File.rm_rf(tmp) end)

      image = put_press_picture(member)
      dir = Path.join([tmp, "press_kit", image.token])
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "large.avif"), "not-really-avif")

      assert Images.bytes_path(image) |> File.exists?()

      assert {:ok, _case} = Moderation.report_content(reporter, image, @copyright)
      frozen = Repo.get!(Vutuv.Images.Image, image.id)

      assert path = Images.bytes_path(frozen)
      assert File.exists?(path)
    end
  end

  defp url(path), do: VutuvWeb.Endpoint.url() <> path
end
