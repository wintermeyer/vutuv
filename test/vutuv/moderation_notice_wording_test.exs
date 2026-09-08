defmodule Vutuv.ModerationNoticeWordingTest do
  @moduledoc """
  What the takedown chain actually says, checked against the German render a
  real visitor gets (issue #2067).

  Every claim here was read by a person in a browser before it was written
  down, and each one was a sentence that was simply not true: a frozen profile
  picture announced as a post, a member invented behind an anonymous notice,
  the house rules cited for a copyright ruling, a reporter told only that "the
  necessary steps" were taken, an admin told a picture is visible because no
  copyright notice was filed on a copyright case, and a decision that arrives
  in the owner's notification list stamped with the hour the report came in.

  Not async: several tests flip `:uploads_dir_prefix` for a real picture.
  """

  use Vutuv.DataCase, async: false

  import ExUnit.CaptureLog, only: [capture_log: 1]
  import Vutuv.WebPushHelpers, only: [put_config: 2]

  alias Vutuv.{Accounts, Activity, Moderation}
  alias Vutuv.Moderation.{Case, Report}

  @note "Das Foto ist meins, das Original steht auf example.com/hafen.jpg"

  setup do
    owner = insert(:activated_user, locale: "de")
    insert(:email, user: owner, value: "eigner@example.com")
    admin = insert(:activated_user, admin?: true)
    insert(:email, user: admin)

    {:ok, owner: owner, admin: admin}
  end

  defp member_reporter do
    reporter = insert(:activated_user)
    insert(:email, user: reporter)
    reporter
  end

  defp de_reporter do
    reporter = insert(:activated_user, locale: "de")
    insert(:email, user: reporter, value: "melder@example.com")
    reporter
  end

  # One closing path, checked the way a reader meets it: the sentence the notice
  # makes about the content.
  #
  # It used to end by mapping that sentence back to a fate and asserting
  # `consistent_outcome?/2` on it — two literals from the call site compared
  # with each other, which is the "compares a sentence with itself" shape
  # issue #2071 is about. Since `deliver_or_refuse/4` now refuses to send a
  # contradicting pair at all, a notice that arrives is consistent by
  # construction and the assertion could no longer fail. What it claimed to
  # cover is covered for real below, twice: the exhaustive table over the
  # predicate, and the tenth path driven through the public API.
  defp assert_notice(address, fate_sentence) do
    for body <- bodies(mail_to(address)) do
      assert body =~ fate_sentence,
             "the notice does not say #{inspect(fate_sentence)}"
    end
  end

  defp uploads_dir do
    tmp =
      Path.join(System.tmp_dir!(), "vutuv_notice_wording_#{System.unique_integer([:positive])}")

    put_config(:uploads_dir_prefix, tmp)
    on_exit(fn -> File.rm_rf(tmp) end)
    tmp
  end

  # The colour is the fingerprint: a replacement only settles a case when the
  # bytes really differ (issue #2035).
  defp jpeg_upload(color \\ [10, 120, 200]) do
    src = Path.join(System.tmp_dir!(), "notice_src_#{System.unique_integer([:positive])}.jpg")
    {:ok, img} = Image.new(120, 90, color: color)
    {:ok, _} = Image.write(img, src)
    on_exit(fn -> File.rm(src) end)
    %Plug.Upload{filename: "selfie.jpg", path: src, content_type: "image/jpeg"}
  end

  # The member's avatar as its own reportable row (issue #2012).
  defp avatar_image(owner) do
    uploads_dir()
    {:ok, owner} = Accounts.update_user(owner, %{avatar: jpeg_upload()})
    {owner, Vutuv.Images.member_image(owner, "avatar")}
  end

  defp copyright_notice(attrs \\ %{}) do
    Map.merge(
      %{"category" => "copyright", "note" => @note, "good_faith?" => "true"},
      attrs
    )
  end

  defp outside_notice(attrs \\ %{}) do
    copyright_notice(
      Map.merge(
        %{"reporter_name" => "Rita Holder", "reporter_email" => "rita@example.com"},
        attrs
      )
    )
  end

  defp mail(fragment) do
    Enum.find(flush_emails(), &(&1.subject =~ fragment)) ||
      flunk("no email whose subject matches #{inspect(fragment)}")
  end

  # By recipient, not by subject: the four outcome subjects have no word in
  # common (a deleted content's subject never says "Meldung"), and picking the
  # mail by what it is expected to say would hide the very disagreement these
  # tests are about.
  defp mail_to(address) do
    Enum.find(flush_emails(), fn email ->
      Enum.any?(email.to, fn {_name, to} -> to == address end)
    end) || flunk("no email addressed to #{address}")
  end

  # Both halves of one mail, whitespace flattened. The HTML body wraps a
  # sentence over several source lines, so a raw `=~` on a sentence only ever
  # matches the text half — which is how a wrong HTML body would slip past.
  defp bodies(email), do: Enum.map([email.text_body, email.html_body], &flatten/1)

  defp flatten(body), do: body |> String.replace(~r/\s+/u, " ") |> String.trim()

  # Move a case's arrival into the past, so a ruling now is a different moment.
  defp backdate!(%Case{id: id}, seconds) do
    then = NaiveDateTime.add(NaiveDateTime.utc_now(:second), -seconds)

    Repo.update_all(
      from(c in Case, where: c.id == ^id),
      set: [inserted_at: then, owner_deadline_at: then, updated_at: then]
    )
  end

  describe "the mail names what was actually reported (1)" do
    test "a frozen profile picture is a picture, never a post", %{owner: owner} do
      {_owner, image} = avatar_image(owner)
      reporter = member_reporter()

      {:ok, %Case{status: "pending_owner"}} =
        Moderation.report_content(reporter, image, copyright_notice())

      for body <- bodies(mail("gemeldet")) do
        assert body =~ "eines Ihrer Bilder auf vutuv wurde gemeldet"
        refute body =~ "Beiträge"
        refute body =~ "Beitrag"
      end
    end

    test "a reported post still reads as a post", %{owner: owner} do
      post = insert(:post, user: owner)
      reporter = member_reporter()

      {:ok, %Case{status: "pending_owner"}} =
        Moderation.report_content(reporter, post, %{"category" => "bullying"})

      for body <- bodies(mail("gemeldet")) do
        assert body =~ "einer Ihrer Beiträge auf vutuv wurde gemeldet"
      end
    end

    test "a reported private message reads as a message", %{owner: owner} do
      reporter = member_reporter()
      conversation = insert_conversation_between(owner, reporter)
      message = insert(:message, conversation: conversation, sender: owner)

      {:ok, %Case{}} = Moderation.report_content(reporter, message, %{"category" => "bullying"})

      for body <- bodies(mail("gemeldet")) do
        assert body =~ "eine Ihrer privaten Nachrichten auf vutuv wurde gemeldet"
      end
    end
  end

  describe "an anonymous notice does not invent a member (2)" do
    test "the frozen mail says a person, not a member", %{owner: owner} do
      {_owner, image} = avatar_image(owner)

      {:ok, _case, _report, token} = Moderation.file_public_notice(image, outside_notice(), "de")
      flush_emails()
      {:ok, :confirmed, _report} = Moderation.confirm_public_notice(token)

      for body <- bodies(mail("gemeldet")) do
        assert body =~ "Die Meldung einer Person mit guter Bilanz"
        refute body =~ "Mitglied"
      end
    end

    test "a member's report keeps the member wording", %{owner: owner} do
      post = insert(:post, user: owner)
      reporter = member_reporter()

      {:ok, %Case{}} = Moderation.report_content(reporter, post, %{"category" => "bullying"})

      for body <- bodies(mail("gemeldet")) do
        assert body =~ "Die Meldung eines Mitglieds mit guter Bilanz"
      end
    end

    test "the notice map says which of the two it was", %{owner: owner} do
      post = insert(:post, user: owner)
      reporter = member_reporter()
      {:ok, case_record} = Moderation.report_content(reporter, post, %{"category" => "bullying"})
      assert Moderation.owner_notice(case_record).from_member?

      {_owner, image} = avatar_image(owner)
      {:ok, _case, _report, token} = Moderation.file_public_notice(image, outside_notice(), "de")
      {:ok, :confirmed, report} = Moderation.confirm_public_notice(token)
      refute Moderation.owner_notice(Repo.get!(Case, report.case_id)).from_member?
    end
  end

  describe "the strike names the ground the case page named (3)" do
    test "an upheld copyright case does not cite the house rules", %{
      owner: owner,
      admin: admin
    } do
      post = insert(:post, user: owner)
      reporter = member_reporter()

      {:ok, case_record} = Moderation.report_content(reporter, post, copyright_notice())
      flush_emails()
      {:ok, _} = Moderation.uphold_case(case_record, admin)

      for body <- bodies(mail("Verwarnung")) do
        assert body =~ "Urheberrecht"
        refute body =~ "Community-Richtlinien"
      end
    end

    test "an upheld house-rule case still cites the house rules", %{owner: owner, admin: admin} do
      post = insert(:post, user: owner)
      reporter = member_reporter()

      {:ok, case_record} = Moderation.report_content(reporter, post, %{"category" => "bullying"})
      flush_emails()
      {:ok, _} = Moderation.uphold_case(case_record, admin)

      for body <- bodies(mail("Verwarnung")) do
        assert body =~ "Community-Richtlinien"
      end
    end
  end

  describe "the reporter hears what happened to the content (4)" do
    test "an upheld picture case says the picture is gone", %{owner: owner, admin: admin} do
      {_owner, image} = avatar_image(owner)
      reporter = insert(:activated_user, locale: "de")
      insert(:email, user: reporter, value: "melder@example.com")

      {:ok, case_record} = Moderation.report_content(reporter, image, copyright_notice())
      flush_emails()
      {:ok, _} = Moderation.uphold_case(case_record, admin)

      for body <- bodies(mail("Meldung")) do
        assert body =~ "Der gemeldete Inhalt ist gelöscht."
        refute body =~ "Wir haben die nötigen Schritte unternommen."
      end
    end

    test "an upheld post case says it is not visible any more", %{owner: owner, admin: admin} do
      post = insert(:post, user: owner)
      reporter = insert(:activated_user, locale: "de")
      insert(:email, user: reporter, value: "melder@example.com")

      {:ok, case_record} = Moderation.report_content(reporter, post, %{"category" => "bullying"})
      flush_emails()
      {:ok, _} = Moderation.uphold_case(case_record, admin)

      for body <- bodies(mail("Meldung")) do
        assert body =~ "Der gemeldete Inhalt ist auf vutuv nicht mehr zu sehen."
      end
    end

    test "a rejected case says the content is still there", %{owner: owner, admin: admin} do
      post = insert(:post, user: owner)
      reporter = insert(:activated_user, locale: "de")
      insert(:email, user: reporter, value: "melder@example.com")

      {:ok, case_record} = Moderation.report_content(reporter, post, %{"category" => "bullying"})
      flush_emails()
      {:ok, _} = Moderation.reject_case(case_record, admin)

      for body <- bodies(mail("Meldung")) do
        assert body =~ "Der gemeldete Inhalt ist auf vutuv weiterhin zu sehen."
      end
    end

    test "the outside notifier is told the same thing", %{owner: owner, admin: admin} do
      {_owner, image} = avatar_image(owner)

      {:ok, _case, report, token} = Moderation.file_public_notice(image, outside_notice(), "de")
      {:ok, :confirmed, _report} = Moderation.confirm_public_notice(token)
      flush_emails()

      {:ok, _} = Moderation.uphold_case(Repo.get!(Case, report.case_id), admin)

      email = mail("Meldung")
      assert Enum.any?(email.to, fn {_name, address} -> address == "rita@example.com" end)

      for body <- bodies(email) do
        assert body =~ "Der gemeldete Inhalt ist gelöscht."
      end
    end

    test "the fate is measured after the ruling settled the content", %{
      owner: owner,
      admin: admin
    } do
      {_owner, image} = avatar_image(owner)
      reporter = member_reporter()
      {:ok, case_record} = Moderation.report_content(reporter, image, copyright_notice())

      assert Moderation.reported_content_fate(case_record) == :hidden
      {:ok, upheld} = Moderation.uphold_case(case_record, admin)
      assert Moderation.reported_content_fate(upheld) == :removed
    end
  end

  # The two paths that close a case where the content cannot simply be looked
  # at afterwards: one erases the row that would answer, the other leaves a row
  # standing whose bytes are somebody else's. Measuring blind said the friendly
  # thing on both, which is worse than the silence they had before (issue
  # #2067, first repair round).
  describe "a closing path whose content cannot be measured afterwards" do
    test "deleting the account tells the notifier the content is gone", %{
      owner: owner,
      admin: admin
    } do
      post = insert(:post, user: owner)

      {:ok, _case, report, token} = Moderation.file_public_notice(post, outside_notice(), "de")
      {:ok, :confirmed, _report} = Moderation.confirm_public_notice(token)
      flush_emails()

      {:ok, :deleted} =
        Moderation.remove_owner(Repo.get!(Case, report.case_id), admin, :delete, "spam")

      for body <- bodies(mail_to("rita@example.com")) do
        refute body =~ "weiterhin zu sehen",
               "the account and its post are being deleted, and the rights holder is told " <>
                 "the content is still on vutuv"

        refute body =~ "nicht mehr zu sehen",
               "the account and its post are being deleted, and the rights holder is told " <>
                 "only that the content is hidden"

        assert body =~ "Der gemeldete Inhalt ist gelöscht."
      end
    end

    test "replacing a flagged picture reads as revised, not as deleted", %{owner: owner} do
      {owner, image} = avatar_image(owner)
      reporter = insert(:activated_user, locale: "de")
      insert(:email, user: reporter, value: "melder@example.com")

      # A house-rule report on a picture only flags it (issue #2030), so the
      # owner may still replace it — and since #2035 the row keeps its id.
      {:ok, %Case{status: "flagged"}} =
        Moderation.report_content(reporter, image, %{"category" => "family"})

      flush_emails()
      {:ok, _owner} = Accounts.update_user(owner, %{avatar: jpeg_upload([220, 40, 40])})

      email = mail_to("melder@example.com")

      refute email.subject =~ "gelöscht",
             "the reported picture was replaced, not deleted, and the subject says deleted"

      for body <- bodies(email) do
        refute body =~ "Der Besitzer hat den gemeldeten Inhalt gelöscht.",
               "the reported picture was replaced, not deleted"

        assert body =~ "Der Besitzer hat den gemeldeten Inhalt überarbeitet."
        assert body =~ "Der gemeldete Inhalt ist auf vutuv weiterhin zu sehen."
      end
    end

    # The four closing paths the two describes above do not reach, so all nine
    # are walked rather than sampled — which is how these two got through:
    # coverage that follows the states somebody thought of stops at the states
    # somebody thought of.
    test "the owner deleting the reported content says it is deleted", %{owner: owner} do
      post = insert(:post, user: owner)
      reporter = de_reporter()
      {:ok, case_record} = Moderation.report_content(reporter, post, %{"category" => "bullying"})
      flush_emails()

      :ok = Moderation.delete_reported_content(case_record, owner)

      assert_notice("melder@example.com", "Der gemeldete Inhalt ist gelöscht.")
    end

    test "the owner editing a reported post says it is visible", %{owner: owner} do
      post = insert(:post, user: owner)
      reporter = de_reporter()
      {:ok, _case} = Moderation.report_content(reporter, post, %{"category" => "bullying"})
      flush_emails()

      :ok = Moderation.content_edited(Repo.reload!(post))

      assert_notice(
        "melder@example.com",
        "Der gemeldete Inhalt ist auf vutuv weiterhin zu sehen."
      )
    end

    test "an upheld profile case says the profile is back", %{owner: owner, admin: admin} do
      reporter = de_reporter()
      second = member_reporter()

      {:ok, _case} = Moderation.report_content(reporter, owner, %{"category" => "bullying"})
      {:ok, case_record} = Moderation.report_content(second, owner, %{"category" => "bullying"})
      assert case_record.status == "escalated"
      flush_emails()

      {:ok, _} = Moderation.uphold_case(case_record, admin)

      assert_notice(
        "melder@example.com",
        "Der gemeldete Inhalt ist auf vutuv weiterhin zu sehen."
      )
    end

    test "deactivating the account says the content is not visible", %{
      owner: owner,
      admin: admin
    } do
      post = insert(:post, user: owner)
      reporter = de_reporter()
      {:ok, case_record} = Moderation.report_content(reporter, post, %{"category" => "bullying"})
      flush_emails()

      {:ok, _} = Moderation.remove_owner(case_record, admin, :deactivate, "spam")

      assert_notice(
        "melder@example.com",
        "Der gemeldete Inhalt ist auf vutuv nicht mehr zu sehen."
      )
    end

    # The invariant that would have caught both above, so a tenth path cannot
    # ship the contradiction: only two of the four endings make a claim about
    # the content in their own subject, and each has exactly one fate that
    # agrees with it.
    test "no closing path lets the subject and the fate disagree" do
      for {status, fate} <- [
            {"resolved_deleted", :removed},
            {"resolved_edited", :visible}
          ] do
        assert Moderation.consistent_outcome?(Case.reporter_outcome(status), fate),
               "#{status} must end in #{inspect(fate)}"
      end

      refute Moderation.consistent_outcome?("removed", :visible)
      refute Moderation.consistent_outcome?("removed", :hidden)
      refute Moderation.consistent_outcome?("revised", :removed)

      # The two admin rulings claim nothing about the content in their subject,
      # so every fate is honest beside them.
      for outcome <- ["upheld", "not_upheld"], fate <- [:removed, :hidden, :visible] do
        assert Moderation.consistent_outcome?(outcome, fate)
      end
    end

    # The tenth path, and the reason the invariant above proved nothing: it
    # hands `consistent_outcome?/2` the fate it expects, so it compares a
    # sentence with itself. Here the *system* produces both halves — a caller
    # reaching for the public `content_deleted/1` on a post that is merely
    # frozen, which is the closing path a reviewer wrote and watched send
    # "…wurde gelöscht" over "…nicht mehr zu sehen" (issue #2071).
    test "a contradicting ending sends no notice, loudly", %{owner: owner} do
      post = insert(:post, user: owner)
      reporter = de_reporter()

      {:ok, case_record} = Moderation.report_content(reporter, post, %{"category" => "bullying"})
      assert Repo.reload!(post).frozen_at
      flush_emails()

      log = capture_log(fn -> :ok = Moderation.content_deleted(post) end)

      assert log =~ "consistent_outcome?"
      assert log =~ case_record.id

      assert flush_emails() == [],
             "a notice went out whose subject and body disagree about the content"

      # And not silently: the claim is handed back, so the reports still owe
      # their reporter a notice rather than being stamped as answered.
      assert Repo.exists?(Report.awaiting_outcome(case_record.id))
    end
  end

  describe "the admin panel says why the picture is still there (5)" do
    test "an unconfirmed copyright notice is the reason, not the category", %{owner: owner} do
      {_owner, image} = avatar_image(owner)
      {:ok, case_record, _report, _token} = Moderation.file_public_notice(image, outside_notice())

      case_record = Repo.preload(case_record, :reports)
      assert Moderation.pending_copyright_notice?(case_record)
      refute Moderation.copyright_case?(case_record)
    end

    test "upholding an unfrozen picture case deletes rather than hides", %{owner: owner} do
      {_owner, image} = avatar_image(owner)
      reporter = member_reporter()

      {:ok, case_record} = Moderation.report_content(reporter, image, %{"category" => "family"})
      assert case_record.status == "flagged"

      assert Moderation.uphold_content_effect(case_record, Repo.reload!(image)) == :deleted
    end

    test "a frozen post case stays hidden, an unfrozen one does not", %{owner: owner} do
      post = insert(:post, user: owner)
      reporter = member_reporter()
      {:ok, case_record} = Moderation.report_content(reporter, post, %{"category" => "bullying"})

      assert Moderation.uphold_content_effect(case_record, Repo.reload!(post)) == :stays_hidden

      other = insert(:post, user: owner)
      open = %Case{content_type: "post", content_id: other.id, status: "flagged"}
      assert Moderation.uphold_content_effect(open, other) == :untouched
    end
  end

  describe "the ruling rises in the owner's notifications (6)" do
    test "the entry is stamped with the decision, not with the report", %{
      owner: owner,
      admin: admin
    } do
      post = insert(:post, user: owner)
      reporter = member_reporter()
      {:ok, case_record} = Moderation.report_content(reporter, post, %{"category" => "bullying"})

      # The report arrived two days ago; the ruling is now.
      backdate!(case_record, 2 * 86_400)

      {:ok, rejected} = Moderation.reject_case(Repo.get!(Case, case_record.id), admin)

      %{entries: entries} = Activity.notifications_page(owner.id)
      entry = Enum.find(entries, &(&1.kind == "moderation")) || flunk("no moderation entry")

      assert NaiveDateTime.compare(entry.at, rejected.resolved_at) == :eq
    end

    test "a decision after the member last read is unread", %{owner: owner, admin: admin} do
      post = insert(:post, user: owner)
      reporter = member_reporter()
      {:ok, case_record} = Moderation.report_content(reporter, post, %{"category" => "bullying"})

      backdate!(case_record, 2 * 86_400)

      # The member read their notifications the day after the report and a day
      # before the ruling: the freeze is old news, the ruling is not.
      read_at = NaiveDateTime.add(NaiveDateTime.utc_now(:second), -86_400)
      owner = Repo.update!(Ecto.Changeset.change(owner, notifications_read_at: read_at))
      assert Activity.unread_notification_count(owner) == 0

      {:ok, _} = Moderation.reject_case(Repo.get!(Case, case_record.id), admin)

      assert Activity.unread_notification_count(owner) == 1
    end

    # The row is one per case, rewritten in place, and `Activity.dismiss_ref/1`
    # reads its `source_id` back out of the rendered id — so retiming the row
    # must not retag it. Nothing else in the suite acknowledges a moderation
    # row, so a changed id would have gone out silently: the click would settle
    # nothing and the badge would stand.
    test "the member can still tick the row off, and the badge drops", %{
      owner: owner,
      admin: admin
    } do
      post = insert(:post, user: owner)
      reporter = member_reporter()
      {:ok, case_record} = Moderation.report_content(reporter, post, %{"category" => "bullying"})
      {:ok, _} = Moderation.reject_case(Repo.get!(Case, case_record.id), admin)

      %{entries: entries} = Activity.notifications_page(owner.id)
      entry = Enum.find(entries, &(&1.kind == "moderation")) || flunk("no moderation entry")

      assert Activity.unread_notification_count(owner) == 1
      assert %{kind: kind, source_id: source_id} = Activity.dismiss_ref(entry)
      assert source_id == case_record.id

      Activity.mark_notification_seen(owner.id, kind, source_id)
      assert Activity.unread_notification_count(owner) == 0
    end
  end
end
