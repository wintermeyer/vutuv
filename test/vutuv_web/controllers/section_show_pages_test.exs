defmodule VutuvWeb.SectionShowPagesTest do
  # not async: the owner test logs in through the real PIN mailbox
  use VutuvWeb.ConnCase

  # The profile-section entry pages (work experience, link, social media
  # account, address, phone number, email) are real public pages, not admin
  # detail views: the entry itself is the page title (no "About this ..."
  # boilerplate), the breadcrumb ends in the entry, and the values act like
  # what they are (tel:/mailto:/external links). The owner additionally gets
  # the Edit/Delete row; visitors never see owner-only metadata.

  setup do
    user =
      insert_activated_user(
        username: "show_page_owner",
        first_name: "Greta",
        last_name: "Gradient"
      )

    %{user: user}
  end

  describe "work experience show" do
    test "titles the page with the entry and shows the description", %{conn: conn, user: user} do
      job =
        insert(:work_experience,
          user: user,
          title: "Bridge Engineer",
          organization: "Span AG",
          description: "Built suspension bridges."
        )

      html = get(conn, ~p"/#{user}/work_experiences/#{job}") |> html_response(200)

      assert html =~ "Bridge Engineer @ Span AG"
      assert html =~ "Built suspension bridges."
      refute html =~ "About this Experience"
    end

    test "the index lists the description too", %{conn: conn, user: user} do
      insert(:work_experience, user: user, description: "Built suspension bridges.")

      html = get(conn, ~p"/#{user}/work_experiences") |> html_response(200)
      assert html =~ "Built suspension bridges."
    end
  end

  describe "phone number show" do
    test "renders the number as a tel: link with a localized type", %{conn: conn, user: user} do
      phone = insert(:phone_number, user: user, value: "+49 30 555 0100", number_type: "Work")

      html = get(conn, ~p"/#{user}/phone_numbers/#{phone}") |> html_response(200)

      assert html =~ ~s(href="tel:+49305550100")
      # Shown in canonical international grouping (Vutuv.Phone.display/1), so a
      # non-canonically-spaced stored value is regrouped, not echoed verbatim.
      assert html =~ "+49 30 5550100"
      refute html =~ "About this Phone Number"
    end
  end

  describe "email show" do
    test "renders a mailto: link and hides the visibility row from visitors",
         %{conn: conn, user: user} do
      email = insert(:email, user: user, public?: true, value: "greta@example.com")

      html = get(conn, ~p"/#{user}/emails/#{email}") |> html_response(200)

      assert html =~ ~s(href="mailto:greta@example.com")
      refute html =~ "Visibility"
    end

    test "the owner still sees the visibility row", %{conn: conn} do
      {conn, owner} = create_and_login_user(conn)
      %{emails: [email]} = Repo.preload(owner, :emails)

      html = get(conn, ~p"/#{owner}/emails/#{email}") |> html_response(200)

      assert html =~ "Visibility"
    end
  end

  describe "link show" do
    test "links out and titles the page with the description", %{conn: conn, user: user} do
      url = insert(:url, user: user, value: "http://bridges.example.org/", description: "Blog")

      html = get(conn, ~p"/#{user}/links/#{url.id}") |> html_response(200)

      assert html =~ ~s(href="http://bridges.example.org/")
      assert html =~ "Blog"
      refute html =~ "About this Link"
    end
  end

  describe "social media account show" do
    test "links the username to the provider profile", %{conn: conn, user: user} do
      account = insert(:social_media_account, user: user, provider: "GitHub", value: "greta")

      html = get(conn, ~p"/#{user}/social_media_accounts/#{account.id}") |> html_response(200)

      assert html =~ "github.com/greta"
      refute html =~ "About this Social Media Profile"
    end
  end

  describe "address show" do
    test "titles the page with the address description", %{conn: conn, user: user} do
      address =
        insert(:address, user: user, description: "Office", city: "Berlin", zip_code: "10115")

      html = get(conn, ~p"/#{user}/addresses/#{address.id}") |> html_response(200)

      assert html =~ "Office"
      assert html =~ "Berlin"
      refute html =~ "About this Address"
    end
  end
end
