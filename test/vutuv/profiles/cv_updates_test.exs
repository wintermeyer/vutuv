defmodule Vutuv.Profiles.CvUpdatesTest do
  @moduledoc """
  CV update notifications (issue #980): a member who adds a new CV entry can
  tell the people who follow them about it. Notification only, never email,
  never for an edited entry, and every reader can switch the whole kind off.
  """
  use Vutuv.DataCase, async: true

  import Ecto.Query

  alias Vutuv.Activity
  alias Vutuv.Profiles.CvUpdates
  alias Vutuv.Profiles.Education
  alias Vutuv.Profiles.Qualification
  alias Vutuv.Profiles.WorkExperience
  alias Vutuv.Repo
  alias Vutuv.Social.Follow

  defp announce_work_experience(author, attrs \\ []) do
    attrs = Keyword.merge([title: "Head of Bridges", organization: "Span AG"], attrs)
    entry = insert(:work_experience, [user: author, announce_to_followers?: true] ++ attrs)
    CvUpdates.announce(author, entry)
    entry
  end

  defp kinds(user), do: Enum.map(Activity.notifications_page(user.id).entries, & &1.kind)

  describe "the derived feed" do
    test "an announced work experience reaches a follower" do
      author = insert_activated_user()
      follower = insert_activated_user()
      follow!(follower, author)

      announce_work_experience(author)

      assert [item] = Activity.notifications_page(follower.id).entries
      assert item.kind == "cv_update"
      assert item.entry_count == 1
      assert [entry] = item.entries
      assert entry.section == "work_experiences"
      assert entry.title == "Head of Bridges"
      assert entry.subtitle == "Span AG"
      assert item.actor_param == author.username
      assert Activity.unread_notification_count(follower.id) == 1
    end

    test "an entry without the announce flag stays private" do
      author = insert_activated_user()
      follower = insert_activated_user()
      follow!(follower, author)

      insert(:work_experience, user: author, title: "Quiet job")

      assert kinds(follower) == []
      assert Activity.unread_notification_count(follower.id) == 0
    end

    test "education and qualification entries announce too" do
      author = insert_activated_user()
      follower = insert_activated_user()
      follow!(follower, author)

      education =
        insert(:education,
          user: author,
          school: "Bridge University",
          degree: "MSc Structures",
          announce_to_followers?: true
        )

      CvUpdates.announce(author, education)

      qualification =
        insert(:qualification,
          user: author,
          name: "Bridge Inspector",
          issuer: "TÜV",
          announce_to_followers?: true
        )

      CvUpdates.announce(author, qualification)

      # Same author, same three-hour window: one grouped notification naming both.
      assert [item] = Activity.notifications_page(follower.id).entries
      assert item.entry_count == 2

      assert item.entries |> Enum.map(& &1.section) |> Enum.sort() ==
               ["educations", "qualifications"]

      education_entry = Enum.find(item.entries, &(&1.section == "educations"))
      assert education_entry.title == "MSc Structures"
      assert education_entry.subtitle == "Bridge University"

      qualification_entry = Enum.find(item.entries, &(&1.section == "qualifications"))
      assert qualification_entry.title == "Bridge Inspector"
      assert qualification_entry.param == qualification.id
    end

    test "only people who follow the author are told" do
      author = insert_activated_user()
      stranger = insert_activated_user()

      announce_work_experience(author)

      assert kinds(stranger) == []
    end

    test "the author is not notified about their own entry" do
      author = insert_activated_user()

      announce_work_experience(author)

      assert kinds(author) == []
    end

    test "an entry added before the follow is not backfilled" do
      author = insert_activated_user()
      follower = insert_activated_user()

      entry = announce_work_experience(author)

      # The follow starts a day after the entry was created.
      later = NaiveDateTime.add(entry.inserted_at, 86_400, :second)
      insert(:follow, follower: follower, followee: author, inserted_at: later)

      assert kinds(follower) == []
    end

    test "a muted follow gets no CV updates either" do
      author = insert_activated_user()
      follower = insert_activated_user()
      insert(:follow, follower: follower, followee: author, muted: true)

      announce_work_experience(author)

      assert kinds(follower) == []
    end

    test "a reader who switched the kind off sees none of them" do
      author = insert_activated_user()
      follower = insert_activated_user(cv_update_notifications?: false)
      follow!(follower, author)

      announce_work_experience(author)

      assert kinds(follower) == []
      assert Activity.unread_notification_count(follower.id) == 0
    end

    test "a deleted entry takes its notification with it" do
      author = insert_activated_user()
      follower = insert_activated_user()
      follow!(follower, author)

      entry = announce_work_experience(author)
      Repo.delete!(entry)

      assert kinds(follower) == []
    end

    test "reading the notifications page clears the CV update badge" do
      author = insert_activated_user()
      follower = insert_activated_user()
      follow!(follower, author)

      announce_work_experience(author)
      Activity.mark_notifications_read(follower.id)

      assert Activity.unread_notification_count(follower.id) == 0
      assert Activity.notifications_count(follower.id) == 1
    end
  end

  describe "grouping (one notification per author per three hours)" do
    test "a burst of entries is one notification, not one each" do
      author = insert_activated_user()
      follower = insert_activated_user()
      follow!(follower, author)

      for title <- ["Head of Bridges", "Site Manager", "Junior Engineer"] do
        announce_work_experience(author, title: title)
      end

      assert [item] = Activity.notifications_page(follower.id).entries
      assert item.entry_count == 3

      assert Enum.map(item.entries, & &1.title) == [
               "Junior Engineer",
               "Site Manager",
               "Head of Bridges"
             ]

      # The badge counts what the page renders: one item, not three.
      assert Activity.unread_notification_count(follower.id) == 1
      assert Activity.notifications_count(follower.id) == 1
    end

    test "entries in different windows stay separate notifications" do
      author = insert_activated_user()
      follower = insert_activated_user()
      follow!(follower, author)

      now = NaiveDateTime.utc_now(:second)
      long_ago = NaiveDateTime.add(now, -2 * CvUpdates.bucket_seconds(), :second)
      # The follow predates both entries — a notification is only for entries
      # added after you followed.
      Repo.update_all(from(f in Follow, where: f.follower_id == ^follower.id),
        set: [inserted_at: NaiveDateTime.add(long_ago, -60, :second)]
      )

      insert(:work_experience,
        user: author,
        title: "Yesterday's job",
        announce_to_followers?: true,
        inserted_at: long_ago
      )

      announce_work_experience(author, title: "Today's job")

      items = Activity.notifications_page(follower.id).entries
      assert length(items) == 2
      assert Enum.all?(items, &(&1.entry_count == 1))
      assert Activity.unread_notification_count(follower.id) == 2
    end

    test "a group beyond the preview cap counts everything but names a few" do
      author = insert_activated_user()
      follower = insert_activated_user()
      follow!(follower, author)

      for i <- 1..7, do: announce_work_experience(author, title: "Role #{i}")

      assert [item] = Activity.notifications_page(follower.id).entries
      assert item.entry_count == 7
      assert length(item.entries) == 5
    end

    test "reading a group and then adding to it makes it unread again" do
      author = insert_activated_user()
      follower = insert_activated_user()
      follow!(follower, author)

      announce_work_experience(author, title: "First")
      Activity.mark_notifications_read(follower.id)
      assert Activity.unread_notification_count(follower.id) == 0

      # A minute later, still inside the same three-hour window. (The timestamp
      # is explicit because the read marker has second precision, so two rows
      # written in the same test second would tie.)
      announce_work_experience(author,
        title: "Second",
        inserted_at: NaiveDateTime.add(NaiveDateTime.utc_now(:second), 60, :second)
      )

      assert Activity.unread_notification_count(follower.id) == 1
      assert [%{entry_count: 2}] = Activity.notifications_page(follower.id).entries
    end
  end

  describe "the live push" do
    test "an eligible follower is pushed the same payload the feed shows" do
      author = insert_activated_user(first_name: "Greta", last_name: "Gradient")
      follower = insert_activated_user()
      follow!(follower, author)
      Activity.subscribe(follower.id)

      announce_work_experience(author)

      assert_receive {:new_notification, notification}
      assert notification.kind == "cv_update"
      assert notification.entry_count == 1
      assert [entry] = notification.entries
      assert entry.section == "work_experiences"
      assert entry.title == "Head of Bridges"
      assert entry.subtitle == "Span AG"
      assert notification.actor_name == "Greta Gradient"
      assert notification.actor_param == author.username

      # The pushed row carries the DERIVED group id, so the page updates that
      # row instead of stacking a second one.
      assert [%{id: id}] = Activity.notifications_page(follower.id).entries
      assert notification.id == id
    end

    test "a second entry in the same window re-pushes the whole group" do
      author = insert_activated_user()
      follower = insert_activated_user()
      follow!(follower, author)
      Activity.subscribe(follower.id)

      announce_work_experience(author, title: "First")
      assert_receive {:new_notification, %{entry_count: 1, id: first_id}}

      announce_work_experience(author, title: "Second")
      assert_receive {:new_notification, %{entry_count: 2, id: ^first_id} = grouped}

      assert Enum.map(grouped.entries, & &1.title) == ["Second", "First"]
    end

    test "no push without the flag, for a muted follow or an opted-out reader" do
      author = insert_activated_user()
      muter = insert_activated_user()
      opted_out = insert_activated_user(cv_update_notifications?: false)
      insert(:follow, follower: muter, followee: author, muted: true)
      follow!(opted_out, author)

      Activity.subscribe(muter.id)
      Activity.subscribe(opted_out.id)

      # Not announced at all.
      CvUpdates.announce(author, insert(:work_experience, user: author))
      announce_work_experience(author)

      refute_receive {:new_notification, _}
    end
  end

  describe "the author's choice" do
    test "the flag can only be set while the entry is created" do
      author = insert_activated_user()

      quiet =
        %WorkExperience{user_id: author.id}
        |> WorkExperience.changeset(%{
          "title" => "Dev",
          "organization" => "Acme",
          "announce_to_followers?" => "false"
        })
        |> Repo.insert!()

      refute quiet.announce_to_followers?

      loud =
        %WorkExperience{user_id: author.id}
        |> WorkExperience.changeset(%{
          "title" => "Dev",
          "organization" => "Acme GmbH",
          "announce_to_followers?" => "true"
        })
        |> Repo.insert!()

      assert loud.announce_to_followers?

      # An update can never flip it: the checkbox is a create-time decision, so
      # editing an old entry cannot fire a fresh round of notifications.
      updated =
        quiet
        |> WorkExperience.changeset(%{
          "title" => "Senior Dev",
          "announce_to_followers?" => "true"
        })
        |> Repo.update!()

      refute updated.announce_to_followers?
    end

    test "the same create-time rule holds for education and qualification" do
      author = insert_activated_user()

      education =
        %Education{user_id: author.id}
        |> Education.changeset(%{"school" => "Uni", "announce_to_followers?" => "true"})
        |> Repo.insert!()

      assert education.announce_to_followers?

      qualification =
        %Qualification{user_id: author.id}
        |> Qualification.changeset(%{"name" => "Cert", "announce_to_followers?" => "true"})
        |> Repo.insert!()

      assert qualification.announce_to_followers?

      still_announced =
        education
        |> Education.changeset(%{"announce_to_followers?" => "false"})
        |> Repo.update!()

      assert still_announced.announce_to_followers?
    end
  end
end
