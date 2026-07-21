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
               profile-addresses-menu)

  # Two `<details data-menu>` dropdowns are legitimate non-section menus: the
  # shell's avatar account menu (on every page) and the profile header's
  # Report/Block actions menu (#profile-actions-menu, shown to any logged-in
  # visitor). Neither is a profile-section ⋯ menu, so a page-wide `data-menu`
  # check must exclude both. Scope the check to data-menu dropdowns that are
  # neither (same spirit as the #delete-entry pinning in the second describe
  # block).
  defp section_card_menus(html) do
    ~r/<details[^>]*\bdata-menu\b[^>]*>/
    |> Regex.scan(html)
    |> List.flatten()
    |> Enum.reject(&(&1 =~ "data-account-menu" or &1 =~ ~s(id="profile-actions-menu")))
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

      # A full section is a clean showcase: a "Manage" link into its /settings
      # editor, and the inline add tile is gone (adding more happens there).
      # Tags are always full on a fresh account (sign-up requires three).
      for path <- [~p"/settings/work_experiences", ~p"/settings/links", ~p"/settings/tags"] do
        assert html =~ ~s(href="#{path}"), "expected manage link for #{path}"
        refute html =~ ~s(href="#{path}/new"), "the add tile is gone once #{path} has entries"
      end

      # An empty section keeps the dashed add tile (onboarding) to the new form.
      for path <- [
            ~p"/settings/phone_numbers",
            ~p"/settings/addresses",
            ~p"/settings/social_media_accounts"
          ] do
        assert html =~ ~s(href="#{path}/new"), "expected add tile for empty #{path}"
      end

      # General Info edits via /settings/profile; per-row pencils stay off the profile.
      assert html =~ ~s(href="#{~p"/settings/profile"}")
      refute html =~ ~s(href="#{~p"/settings/work_experiences/#{job}/edit"}")
      refute html =~ ~s(href="#{~p"/settings/links/#{url}/edit"}")
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

      refute html =~ ~s(href="#{~p"/settings/work_experiences/new"}")
      refute html =~ ~s(href="#{~p"/settings/emails"}")
      refute html =~ ~s(href="#{~p"/settings/links/#{data.url}/edit"}")
    end
  end

  describe "profile completion checklist" do
    # The owner's onboarding nudge: a few high-impact steps, shown only while
    # something is still undone, and gone once the profile is complete. It is
    # owner-only (a visitor never sees it). Since sign-up requires three tags,
    # the tag step arrives already checked: the list opens at 1/4, visible
    # progress instead of a wall of zeros.

    test "a new owner sees the checklist with the tag step already done", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      html = conn |> get(~p"/#{user}") |> html_response(200)
      checklist = completion_text(html)

      assert checklist =~ "Complete your profile"
      assert checklist =~ "Add a tag"
      assert checklist =~ "Add a profile photo"
      assert checklist =~ "Add a tagline"
      assert checklist =~ "Write your first post"
      # The registration tags already check the first step off.
      assert checklist =~ "1/4"
    end

    # The checklist leads to photo / tagline / first post; work experience is
    # deliberately not pushed there (its section card keeps its own add tile).
    test "the checklist does not push work experience", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      html = conn |> get(~p"/#{user}") |> html_response(200)

      refute completion_text(html) =~ "Add work experience"
      # The section tile itself stays available on the page.
      assert html =~ ~s(href="#{~p"/settings/work_experiences/new"}")
    end

    # The first-post step borrows one of the member's own sign-up tags as a
    # concrete prompt (and quietly demonstrates that #hashtags work in posts).
    test "the first-post step suggests a topic from the member's own tags", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      html = conn |> get(~p"/#{user}") |> html_response(200)

      # The registration fixture's alphabetically first tag (the hint picks
      # the most-endorsed tag, slug as tiebreaker — so alpha-tag-… wins).
      [first_tag | _] = String.split(@registration_tags)
      assert completion_text(html) =~ "For example, a thought on ##{first_tag}."
    end

    test "the checklist disappears once every step is done", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      {:ok, user} =
        Repo.update(Ecto.Changeset.change(user, avatar: "me.jpg", headline: "Builder of things"))

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

    test "the checklist links to the LinkedIn importer", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      html = conn |> get(~p"/#{user}") |> html_response(200)

      # A little pitch plus a link straight into the LinkedIn data import, so a
      # new member can fill several of the steps at once.
      assert completion_text(html) =~ "LinkedIn"
      assert completion_html(html) =~ ~p"/settings/import/linkedin"
    end

    test "the checklist still shows just under an hour after sign-up", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      # 59 minutes old: still inside the one-hour onboarding window.
      backdate_account(user, 59 * 60)

      html = conn |> get(~p"/#{user}") |> html_response(200)

      assert html =~ "Complete your profile"
    end

    test "the checklist is gone more than an hour after sign-up", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      # 61 minutes old: past the one-hour window, so the nudge never returns.
      backdate_account(user, 61 * 60)

      html = conn |> get(~p"/#{user}") |> html_response(200)

      refute html =~ "Complete your profile"
    end

    test "an owner who dismissed the checklist never sees it again", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      # The × persists onboarding_dismissed?; a fresh account with it set stays
      # inside the window yet shows nothing.
      {:ok, _} = Repo.update(Ecto.Changeset.change(user, onboarding_dismissed?: true))

      html = conn |> get(~p"/#{user}") |> html_response(200)

      refute html =~ "Complete your profile"
    end
  end

  # The checklist card's own text, so assertions about its steps can't be
  # satisfied (or broken) by the identically-worded section tiles elsewhere on
  # the profile.
  defp completion_text(html) do
    html
    |> completion_node()
    |> LazyHTML.text()
  end

  # The checklist card's raw HTML, for asserting on links (hrefs) inside it.
  defp completion_html(html) do
    html
    |> completion_node()
    |> LazyHTML.to_html()
  end

  defp completion_node(html) do
    html
    |> LazyHTML.from_document()
    |> LazyHTML.query("#profile-completion")
  end

  # Rewind the account's creation so it sits `seconds_ago` before now, to place
  # it inside or outside the one-hour onboarding window.
  defp backdate_account(user, seconds_ago) do
    inserted_at =
      NaiveDateTime.utc_now()
      |> NaiveDateTime.add(-seconds_ago, :second)
      |> NaiveDateTime.truncate(:second)

    Repo.update_all(
      from(u in Vutuv.Accounts.User, where: u.id == ^user.id),
      set: [inserted_at: inserted_at]
    )
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

      html = conn |> get(~p"/settings/work_experiences/#{job}/edit") |> html_response(200)
      assert_delete_control(html, ~p"/settings/work_experiences/#{job}")

      html = conn |> recycle() |> get(~p"/settings/work_experiences/new") |> html_response(200)
      refute delete_control(html)
    end

    test "link", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      url = insert(:url, user: user)

      html = conn |> get(~p"/settings/links/#{url}/edit") |> html_response(200)
      assert_delete_control(html, ~p"/settings/links/#{url}")

      html = conn |> recycle() |> get(~p"/settings/links/new") |> html_response(200)
      refute delete_control(html)
    end

    test "phone number", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      phone = insert(:phone_number, user: user)

      html = conn |> get(~p"/settings/phone_numbers/#{phone}/edit") |> html_response(200)
      assert_delete_control(html, ~p"/settings/phone_numbers/#{phone}")

      html = conn |> recycle() |> get(~p"/settings/phone_numbers/new") |> html_response(200)
      refute delete_control(html)
    end

    test "social media account", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      account = insert(:social_media_account, user: user)

      html =
        conn
        |> get(~p"/settings/social_media_accounts/#{account}/edit")
        |> html_response(200)

      assert_delete_control(html, ~p"/settings/social_media_accounts/#{account}")

      html =
        conn |> recycle() |> get(~p"/settings/social_media_accounts/new") |> html_response(200)

      refute delete_control(html)
    end

    test "address", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      address = insert(:address, user: user)

      html = conn |> get(~p"/settings/addresses/#{address}/edit") |> html_response(200)
      assert_delete_control(html, ~p"/settings/addresses/#{address}")

      html = conn |> recycle() |> get(~p"/settings/addresses/new") |> html_response(200)
      refute delete_control(html)
    end

    test "email", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      email = Repo.get_by(Vutuv.Accounts.Email, user_id: user.id)

      html = conn |> get(~p"/settings/emails/#{email}/edit") |> html_response(200)
      assert_delete_control(html, ~p"/settings/emails/#{email}")
    end
  end
end
