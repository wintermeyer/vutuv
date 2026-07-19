defmodule Vutuv.ModerationTest do
  use Vutuv.DataCase, async: true
  alias Vutuv.{Chat, Moderation, Posts, Social}
  alias Vutuv.Moderation.{Case, Event, Notifier, Report, Strike}

  # Asserts one of the emails delivered so far has `fragment` in its subject
  # (Swoosh's assert_email_sent/1 pops mailbox messages in order, which
  # breaks on flows that send several emails).
  defp assert_email_subject(fragment) do
    subjects = Enum.map(flush_emails(), & &1.subject)

    assert Enum.any?(subjects, &(&1 =~ fragment)),
           "no email with #{inspect(fragment)} in the subject; got #{inspect(subjects)}"
  end

  setup do
    owner = insert(:activated_user)
    insert(:email, user: owner)
    reporter = insert(:activated_user)
    insert(:email, user: reporter)
    {:ok, %{owner: owner, reporter: reporter}}
  end

  defp insert_post(owner, attrs \\ []) do
    insert(:post, Keyword.merge([user: owner], attrs))
  end

  defp report!(reporter, content, attrs \\ %{}) do
    {:ok, case_record} =
      Moderation.report_content(reporter, content, Map.merge(%{"category" => "bullying"}, attrs))

    case_record
  end

  # A reporter with a bad track record: an admin marked one of their past
  # reports as abusive within the trust window.
  defp make_untrusted!(reporter) do
    target = insert(:activated_user)
    post = insert_post(target)
    case_record = report!(reporter, post)
    admin = insert(:activated_user, admin?: true)
    report = Repo.get_by!(Report, case_id: case_record.id)
    {:ok, _} = Moderation.reject_case(case_record, admin, [report.id])
    reporter
  end

  describe "report_content/3 on a post" do
    test "a trusted report freezes the post and opens a pending_owner case", %{
      owner: owner,
      reporter: reporter
    } do
      post = insert_post(owner)

      assert {:ok, %Case{} = case_record} =
               Moderation.report_content(reporter, post, %{
                 "category" => "family",
                 "note" => "not ok for kids"
               })

      assert case_record.status == "pending_owner"
      assert case_record.content_type == "post"
      assert case_record.content_id == post.id
      assert case_record.owner_id == owner.id
      assert case_record.content_snapshot == post.body
      assert case_record.owner_deadline_at

      # ~72 hours from now
      hours = NaiveDateTime.diff(case_record.owner_deadline_at, NaiveDateTime.utc_now(), :hour)
      assert hours in 71..72

      assert Repo.get!(Vutuv.Posts.Post, post.id).frozen_at

      [report] = Repo.preload(case_record, :reports).reports
      assert report.category == "family"
      assert report.note == "not ok for kids"
      assert report.reporter_id == reporter.id

      # the owner is asked to fix or dispute
      assert_email_subject("reported")
    end

    test "you cannot report your own content", %{owner: owner} do
      post = insert_post(owner)

      assert {:error, :own_content} =
               Moderation.report_content(owner, post, %{"category" => "spam"})
    end

    test "the same reporter cannot report the same content twice", %{
      owner: owner,
      reporter: reporter
    } do
      post = insert_post(owner)
      report!(reporter, post)

      assert {:error, :already_reported} =
               Moderation.report_content(reporter, post, %{"category" => "spam"})
    end

    test "a second reporter joins the existing open case", %{owner: owner, reporter: reporter} do
      post = insert_post(owner)
      case_record = report!(reporter, post)

      other = insert(:activated_user)
      # Reload: the post is frozen now, but reports on an open case must
      # still be accepted (they add weight to the case).
      post = Repo.get!(Vutuv.Posts.Post, post.id)
      assert post.frozen_at

      assert %Case{id: same_id} = report!(other, post)
      assert same_id == case_record.id
      assert Repo.aggregate(Report, :count) == 2
    end

    test "a report from an untrusted reporter only flags, without freezing", %{owner: owner} do
      bad_reporter = make_untrusted!(insert(:activated_user))
      post = insert_post(owner)

      case_record = report!(bad_reporter, post)

      assert case_record.status == "flagged"
      refute Repo.get!(Vutuv.Posts.Post, post.id).frozen_at
    end

    test "a trusted report upgrades a flagged case to a freeze", %{
      owner: owner,
      reporter: reporter
    } do
      bad_reporter = make_untrusted!(insert(:activated_user))
      post = insert_post(owner)
      flagged = report!(bad_reporter, post)
      assert flagged.status == "flagged"

      upgraded = report!(reporter, post)
      assert upgraded.id == flagged.id
      assert upgraded.status == "pending_owner"
      assert Repo.get!(Vutuv.Posts.Post, post.id).frozen_at
    end

    test "two trusted reporters racing on a flagged case freeze, log and notify once", %{
      owner: owner,
      reporter: trusted_b
    } do
      # The Ecto SQL sandbox serializes, so a real two-connection race cannot be
      # reproduced here (issue #778). Drive the upgrade twice with the SAME
      # stale `flagged` struct instead: that is exactly what two reporters who
      # both read the case as flagged before either upgraded it would do. The
      # (case_id, reporter_id) unique index only stops the same reporter from
      # racing, so two different reporters can both enter the upgrade.
      bad = make_untrusted!(insert(:activated_user))
      trusted_c = insert(:activated_user)
      insert(:email, user: trusted_c)

      post = insert_post(owner)
      flagged = report!(bad, post)
      assert flagged.status == "flagged"

      # Clear the emails the make_untrusted! setup produced for other cases.
      _ = flush_emails()

      # First reporter wins the atomic claim: one freeze, one content_frozen
      # log row, one owner notification.
      assert {:ok, first} = Moderation.maybe_upgrade_case(flagged, trusted_b, post)
      assert first.status == "pending_owner"

      # Second reporter holds the same stale flagged struct and loses the claim,
      # so it must NOT freeze/log/notify a second time.
      assert {:ok, second} = Moderation.maybe_upgrade_case(flagged, trusted_c, post)
      assert second.status == "pending_owner"

      frozen_events =
        Repo.all(
          from(e in Event, where: e.case_id == ^flagged.id and e.action == "content_frozen")
        )

      assert length(frozen_events) == 1
      assert Repo.get!(Posts.Post, post.id).frozen_at

      subjects = Enum.map(flush_emails(), & &1.subject)
      assert Enum.count(subjects, &(&1 =~ "reported")) == 1
    end

    test "a reporter who cannot see the post cannot report it", %{owner: owner} do
      stranger = insert(:activated_user)

      {:ok, post} =
        Posts.create_post(owner, %{
          "body" => "secret",
          "denials" => [%{"wildcard" => "everyone"}]
        })

      assert {:error, :not_allowed} =
               Moderation.report_content(stranger, post, %{"category" => "spam"})
    end

    test "an unknown category is rejected", %{owner: owner, reporter: reporter} do
      post = insert_post(owner)

      assert {:error, %Ecto.Changeset{}} =
               Moderation.report_content(reporter, post, %{"category" => "nonsense"})
    end
  end

  describe "report_content/3 on a message" do
    setup %{owner: owner, reporter: reporter} do
      conversation = insert_conversation_between(owner, reporter)
      message = insert(:message, conversation: conversation, sender: owner)
      {:ok, %{conversation: conversation, message: message}}
    end

    test "the other participant can report; the message freezes", %{
      reporter: reporter,
      message: message
    } do
      case_record = report!(reporter, message)

      assert case_record.status == "pending_owner"
      assert case_record.content_type == "message"
      assert Repo.get!(Chat.Message, message.id).frozen_at
    end

    test "a non-participant cannot report the message", %{message: message} do
      outsider = insert(:activated_user)

      assert {:error, :not_allowed} =
               Moderation.report_content(outsider, message, %{"category" => "bullying"})
    end

    test "the sender cannot report their own message", %{owner: owner, message: message} do
      assert {:error, :own_content} =
               Moderation.report_content(owner, message, %{"category" => "bullying"})
    end
  end

  describe "report_content/3 on a whole profile" do
    test "the first report only flags it for admins, no freeze", %{
      owner: owner,
      reporter: reporter
    } do
      case_record = report!(reporter, owner)

      assert case_record.status == "flagged"
      assert case_record.content_type == "user"
      refute Repo.get!(Vutuv.Accounts.User, owner.id).frozen_at
    end

    test "a second independent trusted reporter freezes the profile", %{
      owner: owner,
      reporter: reporter
    } do
      report!(reporter, owner)
      second = insert(:activated_user)

      case_record = report!(second, owner)

      assert case_record.status == "escalated"
      assert Repo.get!(Vutuv.Accounts.User, owner.id).frozen_at
    end

    test "untrusted reporters do not count toward the profile freeze", %{owner: owner} do
      bad1 = make_untrusted!(insert(:activated_user))
      bad2 = make_untrusted!(insert(:activated_user))

      report!(bad1, owner)
      case_record = report!(bad2, owner)

      assert case_record.status == "flagged"
      refute Repo.get!(Vutuv.Accounts.User, owner.id).frozen_at
    end

    test "enough independent spam reports freeze the profile even from untrusted reporters",
         %{owner: owner} do
      # The spam auto-defense: distinct spam-category reports pile up and freeze
      # a bot-blasted profile pending admin review, even when no single reporter
      # is trusted (unlike the bullying path, which needs two trusted reporters).
      # The freeze is fully reversible by reject_case.
      bad_reporters = for _ <- 1..5, do: make_untrusted!(insert(:activated_user))

      # Capture the case status and the profile's frozen state after each report,
      # since the freeze only trips on the last one.
      steps =
        bad_reporters
        |> Enum.with_index(1)
        |> Enum.map(fn {reporter, n} ->
          case_record = report!(reporter, owner, %{"category" => "spam"})
          frozen? = Repo.get!(Vutuv.Accounts.User, owner.id).frozen_at != nil
          {n, case_record.status, frozen?}
        end)

      # Four untrusted spam reports are not enough; the fifth crosses the bar.
      assert {4, "flagged", false} in steps
      assert {5, "escalated", true} in steps
    end

    test "a rejected spam auto-freeze restores the profile", %{owner: owner} do
      # Each reporter files exactly once (the (case_id, reporter_id) unique index
      # enforces it); report! returns the up-to-date case each time, so the last
      # one is the escalated (frozen) case.
      reporters = for _ <- 1..5, do: make_untrusted!(insert(:activated_user))

      case_record =
        Enum.reduce(reporters, nil, fn reporter, _acc ->
          report!(reporter, owner, %{"category" => "spam"})
        end)

      assert case_record.status == "escalated"
      assert Repo.get!(Vutuv.Accounts.User, owner.id).frozen_at

      admin = insert(:activated_user, admin?: true)
      {:ok, _} = Moderation.reject_case(case_record, admin)

      refute Repo.get!(Vutuv.Accounts.User, owner.id).frozen_at
    end
  end

  describe "trusted_reporter?/1" do
    test "a fresh user is trusted", %{reporter: reporter} do
      assert Moderation.trusted_reporter?(reporter)
    end

    test "an abusive report inside the window kills trust" do
      bad = make_untrusted!(insert(:activated_user))
      refute Moderation.trusted_reporter?(bad)
    end

    test "three rejected reports inside the window kill trust", %{reporter: reporter} do
      admin = insert(:activated_user, admin?: true)

      for _ <- 1..3 do
        target = insert(:activated_user)
        post = insert_post(target)
        case_record = report!(reporter, post)
        {:ok, _} = Moderation.reject_case(case_record, admin)
      end

      refute Moderation.trusted_reporter?(reporter)
    end

    test "rejected reports older than the window do not count", %{reporter: reporter} do
      admin = insert(:activated_user, admin?: true)

      for _ <- 1..3 do
        target = insert(:activated_user)
        post = insert_post(target)
        case_record = report!(reporter, post)
        {:ok, rejected} = Moderation.reject_case(case_record, admin)

        old = NaiveDateTime.add(NaiveDateTime.utc_now(), -400 * 86_400)

        Repo.update_all(
          from(c in Case, where: c.id == ^rejected.id),
          set: [resolved_at: old]
        )
      end

      assert Moderation.trusted_reporter?(reporter)
    end
  end

  describe "owner self-service" do
    test "dispute keeps the content frozen and escalates", %{owner: owner, reporter: reporter} do
      post = insert_post(owner)
      case_record = report!(reporter, post)

      assert {:ok, disputed} = Moderation.dispute_case(case_record, owner)
      assert disputed.status == "escalated"
      assert disputed.escalated_at
      assert Repo.get!(Vutuv.Posts.Post, post.id).frozen_at
    end

    test "only the owner can dispute", %{owner: owner, reporter: reporter} do
      post = insert_post(owner)
      case_record = report!(reporter, post)

      assert {:error, :not_allowed} = Moderation.dispute_case(case_record, reporter)
    end

    test "deleting the content closes the case", %{owner: owner, reporter: reporter} do
      post = insert_post(owner)
      case_record = report!(reporter, post)

      Moderation.content_deleted(post)

      assert Repo.get!(Case, case_record.id).status == "resolved_deleted"
    end

    test "editing the content unfreezes it, closes the case and tells the reporter", %{
      owner: owner,
      reporter: reporter
    } do
      post = insert_post(owner)
      case_record = report!(reporter, post)

      Moderation.content_edited(Repo.get!(Vutuv.Posts.Post, post.id))

      assert Repo.get!(Case, case_record.id).status == "resolved_edited"
      refute Repo.get!(Vutuv.Posts.Post, post.id).frozen_at

      assert_email_subject("revised")
    end

    test "editing while the case is escalated does not unfreeze", %{
      owner: owner,
      reporter: reporter
    } do
      post = insert_post(owner)
      case_record = report!(reporter, post)
      {:ok, _} = Moderation.dispute_case(case_record, owner)

      Moderation.content_edited(Repo.get!(Vutuv.Posts.Post, post.id))

      assert Repo.get!(Case, case_record.id).status == "escalated"
      assert Repo.get!(Vutuv.Posts.Post, post.id).frozen_at
    end

    test "a re-report after a self-service edit goes straight to the admins frozen", %{
      owner: owner,
      reporter: reporter
    } do
      post = insert_post(owner)
      report!(reporter, post)
      Moderation.content_edited(Repo.get!(Vutuv.Posts.Post, post.id))

      second = insert(:activated_user)
      case_record = report!(second, post)

      assert case_record.status == "escalated"
      assert Repo.get!(Vutuv.Posts.Post, post.id).frozen_at
    end
  end

  describe "escalate_overdue/0" do
    test "cases past the owner deadline land in the admin queue", %{
      owner: owner,
      reporter: reporter
    } do
      post = insert_post(owner)
      case_record = report!(reporter, post)

      past = NaiveDateTime.add(NaiveDateTime.utc_now(), -3600)

      Repo.update_all(
        from(c in Case, where: c.id == ^case_record.id),
        set: [owner_deadline_at: past]
      )

      assert Moderation.escalate_overdue() == 1
      assert Repo.get!(Case, case_record.id).status == "escalated"
    end

    test "cases still inside the deadline stay put", %{owner: owner, reporter: reporter} do
      post = insert_post(owner)
      case_record = report!(reporter, post)

      assert Moderation.escalate_overdue() == 0
      assert Repo.get!(Case, case_record.id).status == "pending_owner"
    end

    test "writes exactly one escalated_deadline event per escalated case", %{
      owner: owner,
      reporter: reporter
    } do
      past = NaiveDateTime.add(NaiveDateTime.utc_now(), -3600)

      for _ <- 1..2 do
        c = report!(reporter, insert_post(owner))
        Repo.update_all(from(x in Case, where: x.id == ^c.id), set: [owner_deadline_at: past])
      end

      count = Moderation.escalate_overdue()

      events = Repo.all(from(e in Event, where: e.action == "escalated_deadline"))
      # The returned count, the rows updated and the events written must agree.
      assert count == 2
      assert length(events) == count
    end
  end

  describe "admin rulings" do
    setup do
      {:ok, %{admin: insert(:activated_user, admin?: true)}}
    end

    test "uphold keeps the post frozen and strikes the owner with a warning", %{
      owner: owner,
      reporter: reporter,
      admin: admin
    } do
      post = insert_post(owner)
      case_record = report!(reporter, post)

      assert {:ok, upheld} = Moderation.uphold_case(case_record, admin)
      assert upheld.status == "upheld"
      assert upheld.resolved_by_id == admin.id
      assert Repo.get!(Vutuv.Posts.Post, post.id).frozen_at

      [strike] = Repo.all(from(s in Strike, where: s.user_id == ^owner.id))
      assert strike.level == 1
      assert strike.role == "owner"

      user = Repo.get!(Vutuv.Accounts.User, owner.id)
      refute user.suspended_until
      refute user.deactivated_at

      assert_email_subject("warning")
    end

    test "a second uphold on the same case is a no-op, not a second strike", %{
      owner: owner,
      reporter: reporter,
      admin: admin
    } do
      post = insert_post(owner)
      case_record = report!(reporter, post)

      assert {:ok, upheld} = Moderation.uphold_case(case_record, admin)
      # A double-submit / second admin acting on the already-resolved case.
      assert {:error, :not_open} = Moderation.uphold_case(upheld, admin)
      assert {:error, :not_open} = Moderation.uphold_case(case_record, admin)

      assert [%{level: 1}] = Repo.all(from(s in Strike, where: s.user_id == ^owner.id))

      user = Repo.get!(Vutuv.Accounts.User, owner.id)
      refute user.suspended_until
      refute user.deactivated_at
    end

    test "a second reject on the same case is a no-op", %{
      owner: owner,
      reporter: reporter,
      admin: admin
    } do
      post = insert_post(owner)
      case_record = report!(reporter, post)

      assert {:ok, rejected} = Moderation.reject_case(case_record, admin)
      assert {:error, :not_open} = Moderation.reject_case(rejected, admin)
    end

    test "the second strike suspends for a week", %{owner: owner, admin: admin} do
      for _ <- 1..2 do
        reporter = insert(:activated_user)
        post = insert_post(owner)
        case_record = report!(reporter, post)
        {:ok, _} = Moderation.uphold_case(case_record, admin)
      end

      user = Repo.get!(Vutuv.Accounts.User, owner.id)
      assert user.suspended_until
      refute user.deactivated_at

      days = NaiveDateTime.diff(user.suspended_until, NaiveDateTime.utc_now(), :day)
      assert days in 6..7
    end

    test "the third strike deactivates the account for good", %{owner: owner, admin: admin} do
      # All three reports are filed while the account is in good standing
      # (a suspended account's content cannot be seen, so not reported).
      cases =
        for _ <- 1..3 do
          report!(insert(:activated_user), insert_post(owner))
        end

      for case_record <- cases do
        {:ok, _} = Moderation.uphold_case(case_record, admin)
      end

      user = Repo.get!(Vutuv.Accounts.User, owner.id)
      assert user.deactivated_at
    end

    test "expired strikes do not count toward the ladder", %{owner: owner, admin: admin} do
      expired = NaiveDateTime.add(NaiveDateTime.utc_now(), -86_400)
      insert(:strike, user: owner, role: "owner", level: 1, expires_at: expired)
      insert(:strike, user: owner, role: "owner", level: 2, expires_at: expired)

      reporter = insert(:activated_user)
      post = insert_post(owner)
      case_record = report!(reporter, post)
      {:ok, _} = Moderation.uphold_case(case_record, admin)

      user = Repo.get!(Vutuv.Accounts.User, owner.id)
      refute user.suspended_until
      refute user.deactivated_at
    end

    test "upholding a profile case unfreezes the profile and lets the ladder rule", %{
      owner: owner,
      admin: admin
    } do
      report!(insert(:activated_user), owner)
      case_record = report!(insert(:activated_user), owner)
      assert Repo.get!(Vutuv.Accounts.User, owner.id).frozen_at

      {:ok, _} = Moderation.uphold_case(case_record, admin)

      user = Repo.get!(Vutuv.Accounts.User, owner.id)
      refute user.frozen_at
      refute user.suspended_until
    end

    test "reject unfreezes the content", %{owner: owner, reporter: reporter, admin: admin} do
      post = insert_post(owner)
      case_record = report!(reporter, post)

      assert {:ok, rejected} = Moderation.reject_case(case_record, admin)
      assert rejected.status == "rejected"
      refute Repo.get!(Vutuv.Posts.Post, post.id).frozen_at
    end

    test "reject with abusive marks strikes the reporter", %{
      owner: owner,
      reporter: reporter,
      admin: admin
    } do
      post = insert_post(owner)
      case_record = report!(reporter, post)
      report = Repo.get_by!(Report, case_id: case_record.id)

      {:ok, _} = Moderation.reject_case(case_record, admin, [report.id])

      assert Repo.get!(Report, report.id).abusive?

      [strike] = Repo.all(from(s in Strike, where: s.user_id == ^reporter.id))
      assert strike.role == "reporter"
      assert strike.level == 1
    end
  end

  describe "remove_owner/4 (decisive spam ruling)" do
    setup do
      {:ok, %{admin: insert(:activated_user, admin?: true)}}
    end

    test "deactivate resolves the case and hides the account without a strike", %{
      owner: owner,
      reporter: reporter,
      admin: admin
    } do
      case_record = report!(reporter, owner, %{"category" => "spam"})

      assert {:ok, resolved} = Moderation.remove_owner(case_record, admin, :deactivate)
      assert resolved.resolved_by_id == admin.id

      user = Repo.get!(Vutuv.Accounts.User, owner.id)
      assert user.deactivated_at
      assert user.moderation_reason == "spam"

      # No warn-first ladder: the spammer is removed outright.
      assert Repo.all(from(s in Strike, where: s.user_id == ^owner.id)) == []

      # The decisive ruling is recorded in the case audit log.
      assert Repo.exists?(
               from(e in Event,
                 where: e.case_id == ^case_record.id and e.action == "owner_removed"
               )
             )
    end

    test "deactivate on an already-resolved case is a no-op", %{
      owner: owner,
      reporter: reporter,
      admin: admin
    } do
      case_record = report!(reporter, owner, %{"category" => "spam"})
      assert {:ok, _} = Moderation.remove_owner(case_record, admin, :deactivate)
      assert {:error, :not_open} = Moderation.remove_owner(case_record, admin, :deactivate)
    end

    test "a custom reason is stamped on the account", %{
      owner: owner,
      reporter: reporter,
      admin: admin
    } do
      case_record = report!(reporter, owner, %{"category" => "spam"})
      {:ok, _} = Moderation.remove_owner(case_record, admin, :deactivate, "abuse")
      assert Repo.get!(Vutuv.Accounts.User, owner.id).moderation_reason == "abuse"
    end

    test "delete removes the account entirely", %{
      owner: owner,
      reporter: reporter,
      admin: admin
    } do
      case_record = report!(reporter, owner, %{"category" => "spam"})

      assert {:ok, :deleted} = Moderation.remove_owner(case_record, admin, :delete)
      refute Repo.get(Vutuv.Accounts.User, owner.id)
    end
  end

  describe "queue and stats" do
    setup do
      {:ok, %{admin: insert(:activated_user, admin?: true)}}
    end

    test "list_queue returns flagged and escalated cases, escalated first", %{
      owner: owner,
      reporter: reporter
    } do
      bad_reporter = make_untrusted!(insert(:activated_user))

      flagged_post = insert_post(owner)
      report!(bad_reporter, flagged_post)

      disputed_post = insert_post(owner)
      disputed = report!(reporter, disputed_post)
      {:ok, _} = Moderation.dispute_case(disputed, owner)

      pending_post = insert_post(owner)
      report!(insert(:activated_user), pending_post)

      queue = Moderation.list_queue()
      assert [%Case{status: "escalated"}, %Case{status: "flagged"}] = queue
      assert Moderation.open_queue_count() == 2
    end

    test "reporter_stats counts totals, rejections and abusive marks", %{
      owner: owner,
      reporter: reporter,
      admin: admin
    } do
      post = insert_post(owner)
      case_record = report!(reporter, post)
      report = Repo.get_by!(Report, case_id: case_record.id)
      {:ok, _} = Moderation.reject_case(case_record, admin, [report.id])

      post2 = insert_post(owner)
      report!(reporter, post2)

      stats = Moderation.reporter_stats(reporter)
      assert stats.total == 2
      assert stats.rejected == 1
      assert stats.abusive == 1
    end
  end

  describe "admin digest" do
    test "mails every admin when cases are waiting, stays silent otherwise", %{
      owner: owner,
      reporter: reporter
    } do
      admin = insert(:activated_user, admin?: true)
      insert(:email, user: admin, value: "digest-admin@example.com")

      Notifier.admins_digest(0)
      refute Enum.any?(flush_emails(), &(&1.subject =~ "waiting"))

      post = insert_post(owner)
      case_record = report!(reporter, post)
      {:ok, _} = Moderation.dispute_case(case_record, owner)

      Notifier.admins_digest(Moderation.open_queue_count())
      assert_email_subject("waiting")
    end
  end

  describe "account gates" do
    test "login_block/1" do
      assert Moderation.login_block(insert(:activated_user)) == nil

      suspended =
        insert(:activated_user,
          suspended_until: NaiveDateTime.add(NaiveDateTime.utc_now(), 86_400)
        )

      assert {:suspended, _until} = Moderation.login_block(suspended)

      # an expired suspension no longer blocks
      lapsed =
        insert(:activated_user,
          suspended_until: NaiveDateTime.add(NaiveDateTime.utc_now(), -86_400)
        )

      assert Moderation.login_block(lapsed) == nil

      deactivated = insert(:activated_user, deactivated_at: NaiveDateTime.utc_now())
      assert Moderation.login_block(deactivated) == :deactivated
    end

    test "account_hidden?/1" do
      refute Moderation.account_hidden?(insert(:activated_user))

      assert Moderation.account_hidden?(
               insert(:activated_user, frozen_at: NaiveDateTime.utc_now())
             )

      assert Moderation.account_hidden?(
               insert(:activated_user,
                 suspended_until: NaiveDateTime.add(NaiveDateTime.utc_now(), 3600)
               )
             )

      assert Moderation.account_hidden?(
               insert(:activated_user, deactivated_at: NaiveDateTime.utc_now())
             )
    end
  end

  describe "reporting severs the relationship between reporter and owner" do
    # Reporting someone is a statement that the contact is unwanted: the two
    # accounts are separated at report time - the mutual follow (vernetzt) gone,
    # conversation frozen for both - before any second report or admin ruling.
    setup %{owner: owner, reporter: reporter} do
      connect!(reporter, owner)
      conversation = insert_conversation_between(reporter, owner)
      message = insert(:message, conversation: conversation, sender: owner)
      insert(:message, conversation: conversation, sender: reporter)
      {:ok, %{conversation: conversation, message: message}}
    end

    test "a post report cuts the follows and freezes the conversation", %{
      owner: owner,
      reporter: reporter,
      conversation: conversation
    } do
      report!(reporter, insert_post(owner))

      refute Social.connected?(reporter.id, owner.id)
      refute Social.user_follows_user?(reporter.id, owner.id)
      refute Social.user_follows_user?(owner.id, reporter.id)
      assert Repo.get!(Vutuv.Chat.Conversation, conversation.id).frozen_at

      # Hidden from both sidebars, no unread badge, no thread access.
      assert Chat.list_conversations(owner) == []
      assert Chat.list_conversations(reporter) == []
      assert Chat.unread_conversations_count(owner) == 0
      assert Chat.unread_conversations_count(reporter) == 0
      refute Chat.get_conversation(owner, conversation.id)
      refute Chat.get_conversation(reporter, conversation.id)
      assert Chat.messages_page(owner, conversation.id).entries == []

      # Writing into the frozen pair fails silently (like a decline), and
      # opening the pair anew refuses without saying why.
      assert {:ok, :dropped} = Chat.send_message(owner, conversation.id, "hello?")
      assert {:error, :frozen} = Chat.find_or_create_conversation(owner, reporter)
      assert {:error, :frozen} = Chat.find_or_create_conversation(reporter, owner)
    end

    test "a profile report severs immediately, before any second report or ruling", %{
      owner: owner,
      reporter: reporter,
      conversation: conversation
    } do
      case_record = report!(reporter, owner)

      # The first profile report only flags - the profile itself is NOT frozen...
      assert case_record.status == "flagged"
      refute Repo.get!(Vutuv.Accounts.User, owner.id).frozen_at

      # ...but the relationship is already cut.
      refute Social.connected?(owner.id, reporter.id)
      refute Social.user_follows_user?(owner.id, reporter.id)
      assert Repo.get!(Vutuv.Chat.Conversation, conversation.id).frozen_at
    end

    test "joining an existing case severs the later reporter too", %{
      owner: owner,
      reporter: reporter
    } do
      second = insert(:activated_user)
      connect!(second, owner)
      second_conversation = insert_conversation_between(second, owner)

      post = insert_post(owner)
      report!(reporter, post)
      report!(second, post)

      refute Social.user_follows_user?(second.id, owner.id)
      assert Repo.get!(Vutuv.Chat.Conversation, second_conversation.id).frozen_at
    end

    test "admins still see the frozen conversation as evidence", %{
      reporter: reporter,
      message: message
    } do
      report!(reporter, message)

      context = Chat.moderation_context(message)
      assert Enum.any?(context, &(&1.id == message.id))
    end

    test "a report with no standing relationship is a clean no-op", %{owner: owner} do
      stranger = insert(:activated_user)

      assert {:ok, _} =
               Moderation.report_content(stranger, insert_post(owner), %{"category" => "spam"})

      assert Repo.all(Vutuv.Moderation.Severance) == []
    end

    test "rejecting the case restores the follows (and the vernetzt status) and conversation", %{
      owner: owner,
      reporter: reporter,
      conversation: conversation
    } do
      case_record = report!(reporter, insert_post(owner))
      admin = insert(:activated_user, admin?: true)

      {:ok, _} = Moderation.reject_case(case_record, admin)

      assert Social.user_follows_user?(reporter.id, owner.id)
      assert Social.user_follows_user?(owner.id, reporter.id)
      assert Social.connected?(reporter.id, owner.id)
      refute Repo.get!(Vutuv.Chat.Conversation, conversation.id).frozen_at
      assert [%{restored_at: %NaiveDateTime{}}] = Repo.all(Vutuv.Moderation.Severance)
    end

    test "rejecting the case does NOT restore ties when one party now blocks the other", %{
      owner: owner,
      reporter: reporter,
      conversation: conversation
    } do
      # The reporter reports, then blocks the owner: the block deliberately
      # severs the follows and keeps the conversation frozen. An admin rejecting
      # the report must not silently undo the block.
      case_record = report!(reporter, insert_post(owner))
      {:ok, _block} = Social.block_user(reporter, owner)
      admin = insert(:activated_user, admin?: true)

      {:ok, _} = Moderation.reject_case(case_record, admin)

      refute Social.user_follows_user?(reporter.id, owner.id)
      refute Social.user_follows_user?(owner.id, reporter.id)
      refute Social.connected?(reporter.id, owner.id)
      assert Repo.get!(Vutuv.Chat.Conversation, conversation.id).frozen_at

      # Freeze-ownership passed to the block: unblocking now thaws the
      # conversation (it must not be stuck frozen forever after the report
      # released its own freeze).
      :ok = Social.unblock_user(reporter, owner)
      refute Repo.get!(Vutuv.Chat.Conversation, conversation.id).frozen_at
    end

    test "upholding the case keeps the separation in place", %{
      owner: owner,
      reporter: reporter,
      conversation: conversation
    } do
      case_record = report!(reporter, insert_post(owner))
      admin = insert(:activated_user, admin?: true)

      {:ok, _} = Moderation.uphold_case(case_record, admin)

      refute Social.user_follows_user?(owner.id, reporter.id)
      assert Repo.get!(Vutuv.Chat.Conversation, conversation.id).frozen_at
      assert [%{restored_at: nil}] = Repo.all(Vutuv.Moderation.Severance)
    end

    test "restoring never duplicates a follow the two already rebuilt", %{
      owner: owner,
      reporter: reporter
    } do
      case_record = report!(reporter, insert_post(owner))
      # They reconnected on their own (followed each other again) while open.
      connect!(reporter, owner)
      admin = insert(:activated_user, admin?: true)

      {:ok, _} = Moderation.reject_case(case_record, admin)

      follows =
        Repo.all(
          from(f in Vutuv.Social.Follow,
            where: f.follower_id == ^reporter.id and f.followee_id == ^owner.id
          )
        )

      assert length(follows) == 1
      assert Social.connected?(reporter.id, owner.id)
    end

    test "the reporter is told about the protection and the restore in their feed", %{
      owner: owner,
      reporter: reporter
    } do
      case_record = report!(reporter, insert_post(owner))

      entries = Vutuv.Activity.notifications_page(reporter.id).entries
      assert Enum.any?(entries, &(&1.kind == "report_protection" and &1.status == "severed"))

      admin = insert(:activated_user, admin?: true)
      {:ok, _} = Moderation.reject_case(case_record, admin)

      entries = Vutuv.Activity.notifications_page(reporter.id).entries
      assert Enum.any?(entries, &(&1.kind == "report_protection" and &1.status == "restored"))
    end
  end

  describe "the audit log" do
    test "records the whole case history for the admins", %{owner: owner, reporter: reporter} do
      connect!(reporter, owner)
      case_record = report!(reporter, insert_post(owner))

      actions = case_record |> Moderation.case_events() |> Enum.map(& &1.action)
      assert "report_filed" in actions
      assert "content_frozen" in actions
      assert "relationship_severed" in actions

      filed =
        case_record |> Moderation.case_events() |> Enum.find(&(&1.action == "report_filed"))

      assert filed.actor_id == reporter.id

      {:ok, case_record} = Moderation.dispute_case(case_record, owner)
      admin = insert(:activated_user, admin?: true)
      {:ok, _} = Moderation.uphold_case(case_record, admin)

      actions = case_record |> Moderation.case_events() |> Enum.map(& &1.action)
      assert "owner_disputed" in actions
      assert "upheld" in actions
      assert "strike_issued" in actions
    end

    test "a rejection logs the ruling and the relationship restore", %{
      owner: owner,
      reporter: reporter
    } do
      connect!(reporter, owner)
      case_record = report!(reporter, insert_post(owner))
      admin = insert(:activated_user, admin?: true)

      {:ok, _} = Moderation.reject_case(case_record, admin)

      events = Moderation.case_events(case_record)
      actions = Enum.map(events, & &1.action)
      assert "rejected" in actions
      assert "relationship_restored" in actions

      rejected = Enum.find(events, &(&1.action == "rejected"))
      assert rejected.actor_id == admin.id
    end
  end

  describe "evidence screenshots" do
    test "profile cases shoot the public profile, message cases the token page, posts nothing",
         %{owner: owner, reporter: reporter} do
      alias Vutuv.Moderation.EvidenceScreenshot

      profile_case = report!(reporter, owner)
      assert EvidenceScreenshot.evidence_url(profile_case) =~ "/#{owner.username}"

      conversation = insert_conversation_between(owner, reporter)
      message = insert(:message, conversation: conversation, sender: owner)
      message_case = report!(reporter, message)
      url = EvidenceScreenshot.evidence_url(message_case)
      assert url =~ "/moderation/evidence/"

      token = url |> String.split("/moderation/evidence/") |> List.last()
      assert {:ok, case_id} = EvidenceScreenshot.verify_token(token)
      assert case_id == message_case.id

      post_case = report!(reporter, insert_post(owner))
      assert EvidenceScreenshot.evidence_url(post_case) == nil
    end
  end

  describe "the urgent admin email" do
    test "carries the substance of the case, not just a link", %{
      owner: owner,
      reporter: reporter
    } do
      admin = insert(:activated_user, admin?: true)
      insert(:email, user: admin)

      report!(reporter, owner, %{"category" => "bullying", "note" => "harasses me in DMs"})

      email =
        Enum.find(flush_emails(), &(&1.subject =~ "profile")) ||
          flunk("no urgent admin email was sent")

      assert email.text_body =~ "@#{owner.username}"
      assert email.text_body =~ "Bullying or harassment"
      assert email.text_body =~ "harasses me in DMs"
      assert email.text_body =~ "admin/moderation/"
    end
  end
end
