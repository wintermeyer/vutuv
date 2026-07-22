defmodule VutuvWeb.CvUpdateNotificationTest do
  @moduledoc """
  The web side of CV update notifications (issue #980): the author's checkbox on
  the three new-entry forms, the reader's switch on the notification settings
  page, and how the event reads on /notifications.
  """
  use VutuvWeb.ConnCase, async: true

  alias Vutuv.Accounts.User
  alias Vutuv.Profiles.WorkExperience
  alias Vutuv.Repo

  # A second browser session, for the member on the receiving end.
  defp login_follower do
    conn = build_conn() |> Plug.Test.init_test_session(%{})
    create_and_login_user(conn, registration_attrs("follower"))
  end

  describe "the author's checkbox" do
    test "the new-entry forms offer it, ticked, once the member has a follower", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      follow!(insert_activated_user(), user)
      follow!(insert_activated_user(), user)

      for path <- [
            ~p"/settings/work_experiences/new",
            ~p"/settings/educations/new",
            ~p"/settings/qualifications/new"
          ] do
        body = html_response(get(conn, path), 200)

        assert body =~ "Tell my 2 followers about this"
        # Ticked by default: adding a role is usually news worth sharing, and
        # unticking it is one click.
        assert announce_checkbox(body) =~ "checked"
      end
    end

    test "a member with no followers never sees it", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)

      body = html_response(get(conn, ~p"/settings/work_experiences/new"), 200)
      refute body =~ "announce_to_followers?"
    end

    test "the edit form never offers it", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      follow!(insert_activated_user(), user)
      work_experience = insert(:work_experience, user: user)

      body = html_response(get(conn, ~p"/settings/work_experiences/#{work_experience}/edit"), 200)
      refute body =~ "announce_to_followers?"
    end
  end

  describe "creating an announced entry" do
    test "reaches the follower's notifications with a link to the entry", %{conn: conn} do
      {follower_conn, follower} = login_follower()
      {conn, author} = create_and_login_user(conn)
      follow!(follower, author)

      post(conn, ~p"/settings/work_experiences", %{
        "work_experience" => %{
          "title" => "Head of Bridges",
          "organization" => "Span AG",
          "kind" => "employment",
          "announce_to_followers?" => "true"
        }
      })

      entry = Repo.get_by!(WorkExperience, user_id: author.id, title: "Head of Bridges")
      assert entry.announce_to_followers?

      body = html_response(get(follower_conn, ~p"/notifications"), 200)

      assert body =~ "added a new position to their CV: Head of Bridges · Span AG"
      assert body =~ "CV update"
      # The entry's own page on the author's profile …
      assert body =~ ~s(href="/#{author.username}/work_experiences/#{entry.slug}")
      # … and the profile itself, from the actor line.
      assert body =~ ~s(href="/#{author.username}")
    end

    test "a second entry joins the first row instead of adding one", %{conn: conn} do
      {follower_conn, follower} = login_follower()
      {conn, author} = create_and_login_user(conn)
      follow!(follower, author)

      for title <- ["Head of Bridges", "Site Manager"] do
        post(conn, ~p"/settings/work_experiences", %{
          "work_experience" => %{
            "title" => title,
            "organization" => "Span AG",
            "kind" => "employment",
            "announce_to_followers?" => "true"
          }
        })
      end

      body = html_response(get(follower_conn, ~p"/notifications"), 200)

      # One row, counting both, with each entry named and linked.
      assert body =~ "added 2 new entries to their CV"
      refute body =~ "added a new position to their CV"
      assert body =~ "Head of Bridges · Span AG"
      assert body =~ "Site Manager · Span AG"
      assert [_] = Regex.scan(~r/CV update/, body)
    end

    test "an unticked box tells nobody", %{conn: conn} do
      {follower_conn, follower} = login_follower()
      {conn, author} = create_and_login_user(conn)
      follow!(follower, author)

      post(conn, ~p"/settings/work_experiences", %{
        "work_experience" => %{
          "title" => "Quiet Job",
          "organization" => "Span AG",
          "kind" => "employment",
          "announce_to_followers?" => "false"
        }
      })

      body = html_response(get(follower_conn, ~p"/notifications"), 200)

      refute body =~ "Quiet Job"
      refute body =~ "CV update"
    end
  end

  describe "the reader's switch" do
    test "the notification settings page saves it", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      body = html_response(get(conn, ~p"/settings/notifications"), 200)
      assert body =~ "cv_update_notifications?"
      # The card posts to the notifications action, not the privacy one.
      assert body =~ ~s(action="/settings/notifications")

      conn =
        put(conn, ~p"/settings/notifications", %{
          "user" => %{"cv_update_notifications?" => "false"}
        })

      assert redirected_to(conn) == ~p"/settings/notifications"
      refute Repo.get!(User, user.id).cv_update_notifications?
    end

    test "with it off the events disappear from the feed", %{conn: conn} do
      author = insert_activated_user()
      {conn, follower} = create_and_login_user(conn)
      follow!(follower, author)

      entry =
        insert(:work_experience,
          user: author,
          title: "Head of Bridges",
          announce_to_followers?: true
        )

      assert html_response(get(conn, ~p"/notifications"), 200) =~ entry.title

      put(conn, ~p"/settings/notifications", %{"user" => %{"cv_update_notifications?" => "false"}})

      refute html_response(get(conn, ~p"/notifications"), 200) =~ entry.title
    end
  end

  # The rendered checkbox input for the announce flag (the `checkbox/3` helper
  # emits a hidden "false" input first, so pick the real one).
  defp announce_checkbox(body) do
    ~r/<input[^>]*announce_to_followers\?[^>]*>/
    |> Regex.scan(body)
    |> List.flatten()
    |> Enum.find("", &String.contains?(&1, "checkbox"))
  end
end
