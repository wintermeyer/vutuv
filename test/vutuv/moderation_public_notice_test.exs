defmodule Vutuv.ModerationPublicNoticeTest do
  @moduledoc """
  The notice a rights holder without an account files at `/system/report`
  (issue #2009): what it can and cannot cause before the address is confirmed,
  and what the now-nullable `moderation_reports.reporter_id` does to everything
  that used to assume a reporter has a user row.
  """

  use Vutuv.DataCase, async: true

  import Ecto.Query

  alias Vutuv.Moderation
  alias Vutuv.Moderation.{Case, Report}
  alias Vutuv.Notifications.Emailer

  setup do
    owner = insert(:activated_user)
    insert(:email, user: owner)
    {:ok, %{owner: owner}}
  end

  defp notice(attrs \\ %{}) do
    Map.merge(
      %{
        "category" => "copyright",
        "note" => "The photo is mine, the original is at example.com/photo",
        "good_faith?" => "true",
        "reporter_name" => "Rita Holder",
        "reporter_email" => "rita@example.com"
      },
      attrs
    )
  end

  defp file!(content, attrs \\ %{}) do
    {:ok, case_record, _report, token} = Moderation.file_public_notice(content, notice(attrs))
    {case_record, token}
  end

  # Backdates the notice's deadline rather than travelling the clock: the
  # column is the deadline, so this is exactly the state a week's silence
  # leaves behind.
  defp expire!(token) do
    {1, _} =
      Repo.update_all(
        from(r in Report, where: r.confirmation_hash == ^Vutuv.Token.hash_token(token)),
        set: [confirmation_expires_at: NaiveDateTime.add(NaiveDateTime.utc_now(:second), -60)]
      )

    :ok
  end

  # A picture row without the upload behind it: these tests never move a byte
  # (a house-rule notice hides nothing, and a refused changeset writes nothing),
  # so the row alone is what they need.
  defp image_row(owner) do
    Repo.insert!(%Vutuv.Images.Image{
      kind: "avatar",
      user_id: owner.id,
      token: Vutuv.Uploads.gen_token()
    })
  end

  describe "file_public_notice/2" do
    test "opens a flagged case and hides nothing until the address is confirmed", %{owner: owner} do
      post = insert(:post, user: owner)

      {case_record, token} = file!(post)

      assert case_record.status == "flagged"
      assert case_record.content_type == "post"
      assert case_record.content_id == post.id
      assert is_nil(Repo.get!(Vutuv.Posts.Post, post.id).frozen_at)
      assert is_binary(token)

      [report] = Repo.preload(case_record, :reports).reports
      assert is_nil(report.reporter_id)
      assert report.reporter_email == "rita@example.com"
      assert report.reporter_name == "Rita Holder"
      assert is_nil(report.confirmed_at)
      # Only the hash is stored; the token itself only ever rode the mail.
      assert report.confirmation_hash == Vutuv.Token.hash_token(token)
      refute Report.effective?(report)
    end

    test "the address is normalized, so one person is one reporter", %{owner: owner} do
      post = insert(:post, user: owner)

      {case_record, _token} = file!(post, %{"reporter_email" => "  Rita@Example.COM "})

      [report] = Repo.preload(case_record, :reports).reports
      assert report.reporter_email == "rita@example.com"
    end

    test "the case is in the admin queue from the start", %{owner: owner} do
      post = insert(:post, user: owner)
      {case_record, _token} = file!(post)

      assert case_record.id in Enum.map(Moderation.list_queue(), & &1.id)
    end

    test "one address files one notice per piece of content", %{owner: owner} do
      post = insert(:post, user: owner)
      {_case_record, _token} = file!(post)

      assert {:error, :already_reported} = Moderation.file_public_notice(post, notice())
    end

    test "an incomplete notice is refused", %{owner: owner} do
      post = insert(:post, user: owner)

      for missing <- ["note", "reporter_name", "reporter_email", "good_faith?"] do
        attrs = Map.delete(notice(), missing)
        assert {:error, %Ecto.Changeset{}} = Moderation.file_public_notice(post, attrs)
      end
    end

    test "every category needs the explanation and the declaration, not only copyright", %{
      owner: owner
    } do
      post = insert(:post, user: owner)
      attrs = notice(%{"category" => "spam"}) |> Map.delete("good_faith?")

      assert {:error, %Ecto.Changeset{} = changeset} =
               Moderation.file_public_notice(post, attrs)

      assert Keyword.has_key?(changeset.errors, :good_faith?)
    end

    test "a category the content type does not offer is refused", %{owner: owner} do
      image = image_row(owner)

      assert {:error, %Ecto.Changeset{} = changeset} =
               Moderation.file_public_notice(image, notice(%{"category" => "spam"}))

      assert Keyword.has_key?(changeset.errors, :category)
    end

    test "a notice joins the open case a member's report already opened", %{owner: owner} do
      post = insert(:post, user: owner)
      member = insert(:activated_user)
      insert(:email, user: member)
      {:ok, member_case} = Moderation.report_content(member, post, %{"category" => "bullying"})

      {case_record, _token} = file!(post)

      assert case_record.id == member_case.id
      assert length(Repo.preload(case_record, :reports).reports) == 2
    end
  end

  describe "confirm_public_notice/1" do
    test "the freeze, the owner notice and the admin mail all wait for the click", %{owner: owner} do
      admin = insert(:activated_user, admin?: true)
      insert(:email, user: admin)
      post = insert(:post, user: owner)

      {_case_record, token} = file!(post)
      assert flush_emails() == []

      assert {:ok, :confirmed, report} = Moderation.confirm_public_notice(token)
      assert report.confirmed_at

      assert Repo.get!(Vutuv.Posts.Post, post.id).frozen_at
      subjects = Enum.map(flush_emails(), & &1.subject)
      assert Enum.any?(subjects, &(&1 =~ "reported"))
    end

    test "a second click is not an error and does not act twice", %{owner: owner} do
      post = insert(:post, user: owner)
      {case_record, token} = file!(post)

      assert {:ok, :confirmed, _report} = Moderation.confirm_public_notice(token)
      events_after_first = length(Moderation.case_events(case_record))

      assert {:ok, :already_confirmed, _report} = Moderation.confirm_public_notice(token)
      assert length(Moderation.case_events(case_record)) == events_after_first
    end

    test "an unknown or empty token is refused" do
      assert {:error, :invalid} = Moderation.confirm_public_notice(Vutuv.Token.random_token())
      assert {:error, :invalid} = Moderation.confirm_public_notice("")
      assert {:error, :invalid} = Moderation.confirm_public_notice(nil)
    end

    test "public_notice_state/1 tells the three cases apart", %{owner: owner} do
      post = insert(:post, user: owner)
      {_case_record, token} = file!(post)

      assert Moderation.public_notice_state(token) == :pending
      {:ok, :confirmed, _report} = Moderation.confirm_public_notice(token)
      assert Moderation.public_notice_state(token) == :confirmed
      assert Moderation.public_notice_state(Vutuv.Token.random_token()) == :unknown
    end

    test "a house-rule notice about a picture still hides nothing (#2030)", %{owner: owner} do
      image = image_row(owner)
      {_case_record, token} = file!(image, %{"category" => "bullying"})

      assert {:ok, :confirmed, _report} = Moderation.confirm_public_notice(token)
      assert is_nil(Repo.get!(Vutuv.Images.Image, image.id).frozen_at)
    end

    test "content deleted before the click leaves the case standing", %{owner: owner} do
      post = insert(:post, user: owner)
      {case_record, token} = file!(post)
      Repo.delete!(post)

      assert {:ok, :confirmed, _report} = Moderation.confirm_public_notice(token)
      assert Repo.get!(Case, case_record.id).status == "flagged"
    end
  end

  describe "an unconfirmed notice counts for nothing" do
    # These three are the calibrated NULL-trap tests. Drop `Report.effective?/1`
    # from `maybe_upgrade_case/4`'s report list and the first two go red: an
    # unconfirmed notice then reads back as a **trusted** reporter, because a
    # nil `reporter_id` falls out of `trusted_reporter_ids/1`'s `IN` list with
    # no stats row and therefore defaults to {0, 0}. The tally only runs on a
    # confirmation, so each test confirms exactly one notice — an all-unconfirmed
    # case never reaches the upgrade path at all and would prove nothing.
    test "an unconfirmed notice does not stand in for the second trusted reporter", %{
      owner: owner
    } do
      {_case_record, _unconfirmed} = file!(owner, %{"reporter_email" => "one@example.com"})
      {case_record, token} = file!(owner, %{"reporter_email" => "two@example.com"})

      {:ok, :confirmed, _} = Moderation.confirm_public_notice(token)

      assert Repo.get!(Case, case_record.id).status == "flagged"
      assert is_nil(Repo.get!(Vutuv.Accounts.User, owner.id).frozen_at)
    end

    test "unconfirmed spam notices do not trip the spam auto-defense", %{owner: owner} do
      for n <- 1..4 do
        {:ok, _case_record, _report, _token} =
          Moderation.file_public_notice(
            owner,
            notice(%{"category" => "spam", "reporter_email" => "brigade#{n}@example.com"})
          )
      end

      {_case_record, token} =
        file!(owner, %{"category" => "spam", "reporter_email" => "brigade5@example.com"})

      {:ok, :confirmed, _} = Moderation.confirm_public_notice(token)

      assert is_nil(Repo.get!(Vutuv.Accounts.User, owner.id).frozen_at)
      assert Moderation.open_case_for(owner).status == "flagged"
    end

    test "two confirmed notices do freeze a profile", %{owner: owner} do
      {_case_record, token_a} = file!(owner, %{"reporter_email" => "one@example.com"})
      {_case_record, token_b} = file!(owner, %{"reporter_email" => "two@example.com"})

      {:ok, :confirmed, _} = Moderation.confirm_public_notice(token_a)
      assert is_nil(Repo.get!(Vutuv.Accounts.User, owner.id).frozen_at)

      {:ok, :confirmed, _} = Moderation.confirm_public_notice(token_b)
      assert Repo.get!(Vutuv.Accounts.User, owner.id).frozen_at
    end
  end

  describe "an unconfirmed notice reaches nothing the owner sees or can do" do
    setup %{owner: owner} do
      post = insert(:post, user: owner)
      member = insert(:activated_user)
      insert(:email, user: member)
      # A member's ordinary spam report freezes the post and starts the 72-hour
      # self-service window.
      {:ok, case_record} = Moderation.report_content(member, post, %{"category" => "spam"})

      {_case_record, _token} =
        file!(post, %{"note" => "A stranger's unverified 2,000 characters."})

      {:ok, %{post: post, case: Repo.get!(Case, case_record.id)}}
    end

    # Calibration: drop the `Report.effective?/1` filter inside
    # `copyright_case?/1` and this goes red — an unconfirmed notice turned the
    # case into a copyright case, so an edit escalated instead of unfreezing
    # and a member lost their own self-service to a stranger who never proved
    # they can read their mail.
    test "the owner's edit still lifts the freeze", %{post: post, case: case_record} do
      refute Moderation.copyright_case?(case_record)
      assert Moderation.owner_edit_offer(case_record, post) == :immediate

      assert :ok == Moderation.content_edited(post)
      assert Repo.get!(Case, case_record.id).status == "resolved_edited"
      assert is_nil(Repo.get!(Vutuv.Posts.Post, post.id).frozen_at)
    end

    # Calibration: drop the filter inside `owner_notice/1` and the stranger's
    # note appears in the list this map hands to the case page and the owner's
    # mail.
    test "the statement of reasons does not quote it", %{case: case_record} do
      notice = Moderation.owner_notice(case_record)

      assert notice.categories == ["spam"]
      refute notice.copyright?
      refute Enum.any?(notice.notes, &(&1 =~ "unverified"))
    end

    test "the in-app line names the member's category, not the stranger's", %{
      case: case_record
    } do
      assert Moderation.notice_category_by_case([case_record.id]) == %{case_record.id => "spam"}
    end
  end

  describe "the confirmation link expires" do
    test "a dead link confirms nothing and says so", %{owner: owner} do
      post = insert(:post, user: owner)
      {_case_record, token} = file!(post)
      expire!(token)

      assert Moderation.public_notice_state(token) == :expired
      assert {:error, :expired} = Moderation.confirm_public_notice(token)
      assert is_nil(Repo.get!(Vutuv.Posts.Post, post.id).frozen_at)
    end

    test "the sweep drops it and settles the case it was holding open", %{owner: owner} do
      post = insert(:post, user: owner)
      {case_record, token} = file!(post)
      expire!(token)

      assert Moderation.sweep_expired_notices() == 1
      assert Repo.aggregate(Report, :count) == 0
      assert Repo.get!(Case, case_record.id).status == "rejected"
    end

    test "a case another report still holds keeps standing", %{owner: owner} do
      post = insert(:post, user: owner)
      member = insert(:activated_user)
      insert(:email, user: member)
      {:ok, case_record} = Moderation.report_content(member, post, %{"category" => "spam"})
      {_case_record, token} = file!(post)
      expire!(token)

      assert Moderation.sweep_expired_notices() == 1
      assert Repo.get!(Case, case_record.id).status == "pending_owner"
      assert Repo.aggregate(Report, :count) == 1
    end
  end

  describe "one mailbox is one reporter" do
    test "a +tag cannot buy a second notice about the same content", %{owner: owner} do
      post = insert(:post, user: owner)
      {_case_record, _token} = file!(post, %{"reporter_email" => "rita+one@example.com"})

      assert {:error, :already_reported} =
               Moderation.file_public_notice(
                 post,
                 notice(%{"reporter_email" => "rita+two@example.com"})
               )
    end

    test "a Gmail dot cannot either, and a dot elsewhere is a different person" do
      assert Report.canonical_email("R.i.ta+work@Gmail.com") == "rita@gmail.com"
      assert Report.canonical_email("rita+work@googlemail.com") == "rita@googlemail.com"
      # Every other provider treats dots as significant, so folding them there
      # would merge two people who are not the same.
      assert Report.canonical_email("r.ita@example.com") == "r.ita@example.com"
      assert Report.canonical_email("rita+tag@example.com") == "rita@example.com"
    end

    test "the address is stored as it was typed, so an admin can write back", %{owner: owner} do
      post = insert(:post, user: owner)
      {case_record, _token} = file!(post, %{"reporter_email" => "Rita+Work@Example.com"})

      [report] = Repo.preload(case_record, :reports).reports
      assert report.reporter_email == "rita+work@example.com"
      assert report.reporter_email_key == "rita@example.com"
    end
  end

  describe "a stranger's name is one line" do
    # Calibration: take `UserHelpers.single_line/1` out of
    # `outside_changeset/3` and this goes red — the name reached a `.text.eex`
    # body, which escapes nothing, so the mail opened with the attacker's own
    # sentences above ours and above the real confirmation link.
    test "line breaks in the name are collapsed before they are stored", %{owner: owner} do
      post = insert(:post, user: owner)

      {case_record, _token} =
        file!(post, %{
          "reporter_name" =>
            "Rita\nWARNING: your account closes in 24 hours.\r\nConfirm: https://evil.example/verify"
        })

      [report] = Repo.preload(case_record, :reports).reports
      refute report.reporter_name =~ ~r/\R/u
      assert report.reporter_name =~ "Rita"
    end

    # The other half of the same defence: one line stops the value posing as a
    # paragraph of ours, the cap stops it filling the line it is on.
    test "the receipt mail caps the greeting name" do
      long = String.duplicate("a", 200)

      email =
        Emailer.public_notice_receipt_email(%{
          name: long,
          email: "rita@example.com",
          locale: "de",
          type: "post",
          category: "copyright",
          content_url: "https://example.com/" <> String.duplicate("b", 900),
          confirm_url: "https://example.com/system/report/confirm/token"
        })

      [{to_name, _address}] = email.to
      assert String.length(to_name) == 80
      assert String.length(email.text_body) < 1_500
    end
  end

  describe "the trust ladder by confirmed address" do
    test "an address whose notice was marked abusive loses the instant freeze", %{owner: owner} do
      admin = insert(:activated_user, admin?: true)
      insert(:email, user: admin)

      first_owner = insert(:activated_user)
      insert(:email, user: first_owner)
      first_post = insert(:post, user: first_owner)
      {first_case, first_token} = file!(first_post)
      {:ok, :confirmed, _} = Moderation.confirm_public_notice(first_token)
      report = Repo.get_by!(Report, case_id: first_case.id)
      {:ok, _} = Moderation.reject_case(first_case, admin, [report.id])

      post = insert(:post, user: owner)
      {case_record, token} = file!(post)
      {:ok, :confirmed, _} = Moderation.confirm_public_notice(token)

      assert Repo.get!(Case, case_record.id).status == "flagged"
      assert is_nil(Repo.get!(Vutuv.Posts.Post, post.id).frozen_at)
    end

    test "marking an outside notice abusive does not raise on the missing user row", %{
      owner: owner
    } do
      admin = insert(:activated_user, admin?: true)
      insert(:email, user: admin)
      post = insert(:post, user: owner)
      {case_record, token} = file!(post)
      {:ok, :confirmed, _} = Moderation.confirm_public_notice(token)
      report = Repo.get_by!(Report, case_id: case_record.id)

      assert {:ok, _} = Moderation.reject_case(case_record, admin, [report.id])
      assert Repo.get!(Report, report.id).abusive?
    end
  end

  describe "the places that assumed a reporter has a user row" do
    setup %{owner: owner} do
      post = insert(:post, user: owner)
      # A house-rule notice rather than a copyright one, so the owner's edit
      # takes the ordinary "tell every reporter" branch below.
      {case_record, token} = file!(post, %{"category" => "bullying"})
      {:ok, :confirmed, _} = Moderation.confirm_public_notice(token)
      {:ok, %{post: post, case: Repo.preload(case_record, reports: :reporter)}}
    end

    test "report_stats/1 answers per report, so a nil reporter is not a lookup key", %{
      case: case_record
    } do
      stats = Moderation.report_stats(case_record.reports)

      for report <- case_record.reports do
        assert %{total: _, rejected: _, abusive: _} = stats[report.id]
      end
    end

    test "list_reporter_stats/0 shows the outside notifier by address", %{case: _case_record} do
      rows = Moderation.list_reporter_stats()
      outside = Enum.filter(rows, &is_nil(&1.reporter))

      assert [%{email: "rita@example.com", total: 1}] = outside
    end

    test "reporter_stats_map/1 survives a nil in the id list" do
      assert Moderation.reporter_stats_map([nil]) == %{}
    end

    # Calibration: the reporters' notice used to hand every report to a
    # `deliver_to/2` matching on `%User{}`, so a nil reporter raised a
    # FunctionClauseError and took the owner's own edit down with it. It
    # branches on the column now (`Notifier.reporters_case_closed/1`).
    test "the owner's edit does not crash on a reporter with no user row", %{
      post: post,
      case: case_record
    } do
      assert Repo.get!(Case, case_record.id).status == "pending_owner"
      assert :ok == Moderation.content_edited(post)
      assert Repo.get!(Case, case_record.id).status == "resolved_edited"
    end
  end
end
