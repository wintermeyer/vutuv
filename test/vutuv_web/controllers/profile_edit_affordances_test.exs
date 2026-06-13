defmodule VutuvWeb.ProfileEditAffordancesTest do
  use VutuvWeb.ConnCase, async: true

  import Vutuv.Factory

  # The owner's add affordance is one visible "Add" button in each section's
  # card header (a <.add_action> brand link to the new-entry form, carrying a
  # data-add-action hook) — the same look and spot as the management pages, so
  # there is one "Add is the button next to the title" idea everywhere. A
  # "Manage" footer link leads to the management page that carries per-row
  # edit/delete. Visitors get none of this owner chrome (and no ⋯ menu).
  # Deletion stays on the edit forms (see the second describe block) and the
  # management pages, one step away from the profile.

  defp insert_profile_data(user) do
    %{
      job: insert(:work_experience, user: user),
      url: insert(:url, user: user),
      phone: insert(:phone_number, user: user),
      address: insert(:address, user: user),
      social: insert(:social_media_account, user: user),
      user_tag: insert(:user_tag, user: user, tag: insert(:tag))
    }
  end

  @menu_ids ~w(profile-skills-menu profile-experience-menu profile-links-menu
               profile-contact-menu profile-about-menu profile-social-media-menu
               profile-phone-numbers-menu profile-addresses-menu)

  # The shell's avatar account menu is a legitimate `<details data-menu>` that
  # renders on every page now, so a page-wide `data-menu` check no longer means
  # "the profile section has a ⋯ menu". Scope the check to data-menu dropdowns
  # that are NOT the account menu (same spirit as the #delete-entry pinning in
  # the second describe block).
  defp section_card_menus(html) do
    ~r/<details[^>]*\bdata-menu\b[^>]*>/
    |> Regex.scan(html)
    |> List.flatten()
    |> Enum.reject(&(&1 =~ "data-account-menu"))
  end

  describe "profile section owner affordances" do
    test "full sections show a Manage link; empty sections show the dashed add tile", %{
      conn: conn
    } do
      {conn, user} = create_and_login_user(conn)
      # Fill experience + links; leave phone/address/social/tags empty.
      job = insert(:work_experience, user: user)
      url = insert(:url, user: user)

      html = conn |> get(~p"/#{user}") |> html_response(200)

      # No quiet ⋯ menu on the profile sections (the shell's account menu is a
      # legitimate data-menu and is excluded); empty cards still carry the tile.
      assert section_card_menus(html) == []
      assert html =~ "data-empty-add"

      for id <- @menu_ids do
        refute html =~ ~s(id="#{id}"), "the quiet ⋯ menu ##{id} is gone"
      end

      # A full section is a clean showcase: a "Manage" link to its page, and the
      # inline add tile is gone (adding more happens on the management page).
      for path <- [~p"/#{user}/work_experiences", ~p"/#{user}/links"] do
        assert html =~ ~s(href="#{path}"), "expected manage link for #{path}"
        refute html =~ ~s(href="#{path}/new"), "the add tile is gone once #{path} has entries"
      end

      # An empty section keeps the dashed add tile (onboarding) to the new form.
      for path <- [
            ~p"/#{user}/phone_numbers",
            ~p"/#{user}/addresses",
            ~p"/#{user}/social_media_accounts",
            ~p"/#{user}/tags"
          ] do
        assert html =~ ~s(href="#{path}/new"), "expected add tile for empty #{path}"
      end

      # General Info edits the user via /edit; per-row pencils stay off the profile.
      assert html =~ ~s(href="#{~p"/#{user}/edit"}")
      refute html =~ ~s(href="#{~p"/#{user}/work_experiences/#{job}/edit"}")
      refute html =~ ~s(href="#{~p"/#{user}/links/#{url}/edit"}")
    end

    test "a logged-in visitor sees the sections but no card menus", %{conn: conn} do
      {conn, _visitor} = create_and_login_user(conn)

      user = insert_activated_user()
      data = insert_profile_data(user)
      email = insert(:email, user: user, public?: true)

      html = conn |> get(~p"/#{user}") |> html_response(200)

      # The entries themselves render for visitors...
      assert html =~ data.job.title
      assert html =~ email.value

      # ...but no profile-section ⋯ menu (the shell account menu is excluded)
      # and none of the owner-only management links.
      assert section_card_menus(html) == []

      for id <- @menu_ids do
        refute html =~ ~s(id="#{id}")
      end

      refute html =~ ~s(href="#{~p"/#{user}/work_experiences/new"}")
      refute html =~ ~s(href="#{~p"/#{user}/emails"}")
      refute html =~ ~s(href="#{~p"/#{user}/links/#{data.url}/edit"}")
    end
  end

  describe "profile completion checklist" do
    # The owner's onboarding nudge: a few high-impact steps, shown only while
    # something is still undone, and gone once the profile is complete. It is
    # owner-only (a visitor never sees it).

    test "a new owner sees the checklist with every step still to do", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      html = conn |> get(~p"/#{user}") |> html_response(200)

      assert html =~ "Complete your profile"
      assert html =~ "Add a profile photo"
      assert html =~ "Add a headline"
      # A blank factory profile has none of the five done.
      assert html =~ "0/5"
    end

    test "the checklist disappears once every step is done", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      {:ok, user} =
        Repo.update(Ecto.Changeset.change(user, avatar: "me.jpg", headline: "Builder of things"))

      insert(:user_tag, user: user, tag: insert(:tag))
      insert(:work_experience, user: user)
      insert(:post, user: user)

      html = conn |> get(~p"/#{user}") |> html_response(200)

      refute html =~ "Complete your profile"
    end

    test "a visitor never sees the owner's completion checklist", %{conn: conn} do
      {conn, _visitor} = create_and_login_user(conn)
      other = insert_activated_user()

      html = conn |> get(~p"/#{other}") |> html_response(200)

      refute html =~ "Complete your profile"
    end
  end

  describe "edit forms carry the delete action" do
    # Each owned resource's edit form renders a delete control (a
    # CSRF-protected `data-method="delete"` link with a confirm prompt,
    # id="delete-entry") so deletion is always reachable from editing. The
    # new forms must not. The shell's logout link is also a data-method
    # delete link, so the assertions pin the extracted #delete-entry tag,
    # not the whole page.

    defp delete_control(html) do
      with [tag] <- Regex.run(~r/<a\b[^>]*id="delete-entry"[^>]*>/, html), do: tag
    end

    defp assert_delete_control(html, delete_path) do
      tag = delete_control(html)
      assert tag, "expected an #delete-entry control on the edit form"
      assert tag =~ ~s(data-method="delete")
      assert tag =~ ~s(href="#{delete_path}")
      assert tag =~ "data-confirm"
    end

    test "work experience", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      job = insert(:work_experience, user: user)

      html = conn |> get(~p"/#{user}/work_experiences/#{job}/edit") |> html_response(200)
      assert_delete_control(html, ~p"/#{user}/work_experiences/#{job}")

      html = conn |> recycle() |> get(~p"/#{user}/work_experiences/new") |> html_response(200)
      refute delete_control(html)
    end

    test "link", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      url = insert(:url, user: user)

      html = conn |> get(~p"/#{user}/links/#{url}/edit") |> html_response(200)
      assert_delete_control(html, ~p"/#{user}/links/#{url}")

      html = conn |> recycle() |> get(~p"/#{user}/links/new") |> html_response(200)
      refute delete_control(html)
    end

    test "phone number", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      phone = insert(:phone_number, user: user)

      html = conn |> get(~p"/#{user}/phone_numbers/#{phone}/edit") |> html_response(200)
      assert_delete_control(html, ~p"/#{user}/phone_numbers/#{phone}")

      html = conn |> recycle() |> get(~p"/#{user}/phone_numbers/new") |> html_response(200)
      refute delete_control(html)
    end

    test "social media account", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      account = insert(:social_media_account, user: user)

      html =
        conn
        |> get(~p"/#{user}/social_media_accounts/#{account}/edit")
        |> html_response(200)

      assert_delete_control(html, ~p"/#{user}/social_media_accounts/#{account}")

      html =
        conn |> recycle() |> get(~p"/#{user}/social_media_accounts/new") |> html_response(200)

      refute delete_control(html)
    end

    test "address", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      address = insert(:address, user: user)

      html = conn |> get(~p"/#{user}/addresses/#{address}/edit") |> html_response(200)
      assert_delete_control(html, ~p"/#{user}/addresses/#{address}")

      html = conn |> recycle() |> get(~p"/#{user}/addresses/new") |> html_response(200)
      refute delete_control(html)
    end

    test "email", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      email = Repo.get_by(Vutuv.Accounts.Email, user_id: user.id)

      html = conn |> get(~p"/#{user}/emails/#{email}/edit") |> html_response(200)
      assert_delete_control(html, ~p"/#{user}/emails/#{email}")
    end
  end
end
