defmodule VutuvWeb.ProfileEditAffordancesTest do
  use VutuvWeb.ConnCase, async: true

  import Vutuv.Factory

  # The owner's add/edit functionality lives in one quiet ⋯ menu per section
  # (a native <details data-menu> dropdown) instead of always-visible links
  # and per-row pencils: "Add entry" goes to the new-form, "Manage entries"
  # to the management page that carries per-row edit/delete. Visitors get
  # none of this markup. Deletion stays on the edit forms (see the second
  # describe block), one deliberate step away from the profile.

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

  describe "profile section card menus" do
    test "owner gets a card menu per section with add and manage entries", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      data = insert_profile_data(user)

      html = conn |> get(~p"/#{user}") |> html_response(200)

      for id <- @menu_ids do
        assert html =~ ~s(id="#{id}"), "expected menu ##{id}"
      end

      # Add entry + manage entries per section (General Info edits the user).
      for path <- [
            ~p"/#{user}/work_experiences",
            ~p"/#{user}/links",
            ~p"/#{user}/emails",
            ~p"/#{user}/phone_numbers",
            ~p"/#{user}/addresses",
            ~p"/#{user}/social_media_accounts",
            ~p"/#{user}/tags"
          ] do
        assert html =~ ~s(href="#{path}/new"), "expected add link for #{path}"
        assert html =~ ~s(href="#{path}"), "expected manage link for #{path}"
      end

      assert html =~ ~s(href="#{~p"/#{user}/edit"}")

      # The per-row pencils are gone; editing goes through the manage pages.
      refute html =~ ~s(href="#{~p"/#{user}/work_experiences/#{data.job}/edit"}")
      refute html =~ ~s(href="#{~p"/#{user}/links/#{data.url}/edit"}")
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

      # ...but no menu and none of the owner-only management links.
      refute html =~ "data-menu"

      for id <- @menu_ids do
        refute html =~ ~s(id="#{id}")
      end

      refute html =~ ~s(href="#{~p"/#{user}/work_experiences/new"}")
      refute html =~ ~s(href="#{~p"/#{user}/emails"}")
      refute html =~ ~s(href="#{~p"/#{user}/links/#{data.url}/edit"}")
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
