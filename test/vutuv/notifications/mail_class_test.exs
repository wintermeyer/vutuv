defmodule Vutuv.Notifications.MailClassTest do
  @moduledoc """
  Issue #1474: every outbound message declares what kind of mail it is, and the
  chokepoint derives the handling from that class instead of from a private
  flag only some builders happened to set.

  Three things are asserted here. Every builder is listed (a new one fails the
  build until somebody decides its class), each builder really produces the
  class it is listed with, and each class really gets its policy — suppression,
  unsubscribe headers, bulk headers.
  """
  use Vutuv.DataCase, async: false

  alias Vutuv.Notifications.Bounces
  alias Vutuv.Notifications.Emailer

  @pin "123456"
  @address "member@example.com"

  # Every public builder in the Emailer, with the class it must produce. The
  # reflection test below fails when a builder is added without a line here.
  #
  # Two lines are deliberate exceptions worth knowing about:
  #
  #   registration_attempt_email — a *third party* triggers it by typing
  #     somebody else's address into the sign-up form, so it stays suppressible.
  #     Making it critical would let anyone keep mailing an address vutuv has
  #     already been told is dead.
  #   ad_booking_email — critical although it is an operator notice: it is the
  #     only record of a booking a member just paid for, and the invoice is
  #     written by hand from it.
  @builders [
    {:login_email, :critical},
    {:email_creation_email, :critical},
    {:user_deletion_email, :critical},
    {:username_change_email, :critical},
    {:security_alert_email, :critical},
    {:ad_booking_email, :critical},
    {:registration_attempt_email, :transactional},
    {:verification_notice, :transactional},
    {:daily_report_email, :transactional},
    {:account_deleted_notice, :transactional},
    {:organization_verified_notice, :transactional},
    {:organization_unverified_notice, :transactional},
    {:organization_domain_dropped_notice, :transactional},
    {:organization_domain_grace_email, :transactional},
    {:organization_domain_verified_email, :transactional},
    {:organization_page_unverified_email, :transactional},
    {:moderation_frozen_email, :transactional},
    {:moderation_review_email, :transactional},
    {:moderation_revised_email, :transactional},
    {:moderation_warning_email, :transactional},
    {:moderation_suspension_email, :transactional},
    {:moderation_deactivation_email, :transactional},
    {:moderation_admin_urgent_email, :transactional},
    {:moderation_admin_digest_email, :transactional},
    {:image_rejected_email, :transactional},
    {:job_posting_expiry_reminder_email, :transactional},
    {:unread_messages_email, :notification},
    {:new_follower_email, :notification},
    {:endorsement_email, :notification},
    {:notification_digest_email, :notification},
    {:reference_check_email, :notification},
    {:saved_search_alert_email, :bulk},
    {:newsletter_email, :bulk}
  ]

  describe "every builder declares a class" do
    test "the table above lists every public builder" do
      Code.ensure_loaded!(Emailer)

      exported =
        Emailer.__info__(:functions)
        |> Enum.map(fn {name, _arity} -> name end)
        |> Enum.filter(&(Atom.to_string(&1) =~ ~r/_(email|notice)$/))
        # base_email/0 is the starting point, not a message.
        |> Enum.reject(&(&1 == :base_email))
        |> Enum.uniq()

      listed = Enum.map(@builders, fn {name, _class} -> name end)

      assert Enum.sort(exported) == Enum.sort(listed),
             """
             Every email builder must declare a mail class (see put_class/2).

             Not listed in this test: #{inspect(exported -- listed)}
             Listed but no longer exported: #{inspect(listed -- exported)}
             """
    end

    test "each builder produces the class it is listed with" do
      for {name, expected} <- @builders do
        assert Emailer.mail_class(build_mail(name)) == expected,
               "#{name} should be #{expected}, got #{Emailer.mail_class(build_mail(name))}"
      end
    end
  end

  describe "the class decides whether mail may be withheld" do
    setup do
      user = insert(:activated_user, locale: "en")

      insert(:email,
        user: user,
        value: "dead@example.com",
        undeliverable_at: ~N[2026-08-01 09:00:00]
      )

      assert Bounces.suppressed?("dead@example.com")

      %{user: user}
    end

    test "a dead address stops transactional mail", %{user: user} do
      assert Emailer.moderation_warning_email(user, "dead@example.com")
             |> Emailer.deliver() == :suppressed
    end

    test "but never the login PIN", %{user: user} do
      assert {:ok, _} =
               Emailer.login_email(@pin, "dead@example.com", user)
               |> Emailer.deliver()
    end

    test "and never the new-sign-in warning", %{user: user} do
      # The mark is one this installation set itself, possibly wrongly, while
      # the sign-in being reported is happening now.
      {_token, session} =
        Vutuv.Sessions.start_session(user, Plug.Test.conn(:get, "/"), alert: false)

      assert {:ok, _} =
               Emailer.security_alert_email(user, "dead@example.com", session, [:new_device])
               |> Emailer.deliver()
    end
  end

  describe "the class decides the headers" do
    test "critical and transactional mail can never be opted out of" do
      for {name, class} <- @builders, class in [:critical, :transactional] do
        headers = build_mail(name).headers

        refute Map.has_key?(headers, "List-Unsubscribe"),
               "#{name} is #{class} mail and must carry no unsubscribe header"

        refute Map.has_key?(headers, "Precedence"),
               "#{name} is #{class} mail and must not be marked bulk"
      end
    end

    test "notification mail carries the one-click unsubscribe but is not bulk" do
      for {name, :notification} <- @builders do
        headers = build_mail(name).headers

        assert headers["List-Unsubscribe-Post"] == "List-Unsubscribe=One-Click",
               "#{name} is notification mail and must be unsubscribable"

        refute Map.has_key?(headers, "Precedence"), "#{name} must not be marked bulk"
      end
    end

    test "bulk mail is marked bulk and is unsubscribable" do
      for {name, :bulk} <- @builders do
        headers = build_mail(name).headers

        assert headers["Precedence"] == "bulk", "#{name} is bulk mail"
        assert headers["List-Unsubscribe"] =~ "/unsubscribe/", "#{name} must be unsubscribable"
      end
    end

    test "declaring the bulk class is what pulls the bulk headers in" do
      refute Map.has_key?(Emailer.base_email().headers, "Precedence")

      bulk = Emailer.put_class(Emailer.base_email(), :bulk)

      assert bulk.headers["Precedence"] == "bulk"
    end
  end

  # --- builders ---------------------------------------------------------------
  # One call per builder, with the smallest fixture that renders. Structs are
  # built inline where no factory exists: these mails only read a handful of
  # fields, and a real row would say nothing more about the class.

  defp build_mail(:login_email),
    do: Emailer.login_email(@pin, @address, user())

  defp build_mail(:email_creation_email),
    do: Emailer.email_creation_email(@pin, @address, user())

  defp build_mail(:user_deletion_email),
    do: Emailer.user_deletion_email(@pin, @address, user())

  defp build_mail(:username_change_email),
    do: Emailer.username_change_email(@pin, @address, user(), "a-new-handle")

  defp build_mail(:registration_attempt_email),
    do: Emailer.registration_attempt_email(user(), @address)

  defp build_mail(:verification_notice) do
    user = user()
    # The factory sequences the address; this table builds every mail twice.
    insert(:email, user: user)

    Emailer.verification_notice(user)
  end

  defp build_mail(:security_alert_email) do
    user = user()

    {_token, session} =
      Vutuv.Sessions.start_session(user, Plug.Test.conn(:get, "/"), alert: false)

    Emailer.security_alert_email(user, @address, session, [:new_device])
  end

  defp build_mail(:unread_messages_email),
    do:
      Emailer.unread_messages_email(
        @address,
        insert(:activated_user, locale: "en"),
        user(),
        Vutuv.UUIDv7.generate(),
        "Coffee this week?"
      )

  defp build_mail(:new_follower_email),
    do: Emailer.new_follower_email(@address, insert(:activated_user, locale: "en"), user())

  defp build_mail(:endorsement_email),
    do: Emailer.endorsement_email(@address, insert(:activated_user, locale: "en"), user(), "ecto")

  defp build_mail(:notification_digest_email),
    do:
      Emailer.notification_digest_email(
        @address,
        insert(:activated_user, locale: "en"),
        [%{kind: "handle_change", old_handle: "old", new_handle: "new"}],
        0
      )

  defp build_mail(:reference_check_email) do
    user = insert(:activated_user, locale: "en")
    reference = insert(:job_reference, user: user)

    Emailer.reference_check_email(@address, user, reference, "2")
  end

  defp build_mail(:saved_search_alert_email) do
    user = insert(:activated_user, locale: "en")
    search = insert(:saved_search, user: user, kind: :people)

    Emailer.saved_search_alert_email(user, @address, [{search, [insert(:user)]}])
  end

  defp build_mail(:newsletter_email),
    do:
      Emailer.newsletter_email(%{
        to_name: "Member",
        to_email: @address,
        subject: "Rundbrief",
        locale: "de",
        content_html: "<p>Hallo</p>",
        content_text: "Hallo",
        unsubscribe_url: "https://example.com/unsubscribe/token"
      })

  # Built, not inserted: only one ad can be booked per day, and this table
  # builds every mail several times over.
  defp build_mail(:ad_booking_email),
    do: Emailer.ad_booking_email(build(:ad), user())

  defp build_mail(:daily_report_email),
    do: Emailer.daily_report_email(%Vutuv.Reports.DailyReport{date: ~D[2026-08-15], posts: 3})

  defp build_mail(:account_deleted_notice),
    do:
      Emailer.account_deleted_notice(%{
        id: Vutuv.UUIDv7.generate(),
        name: "Zaphod Beeblebrox",
        username: "zaphod",
        emails: ["z@example.com"],
        phone_numbers: [],
        post_count: 1,
        joined_at: ~N[2024-01-02 10:00:00],
        deleted_at: ~U[2026-07-01 12:34:56Z]
      })

  defp build_mail(:organization_verified_notice),
    do: Emailer.organization_verified_notice(organization(), domain())

  defp build_mail(:organization_unverified_notice),
    do: Emailer.organization_unverified_notice(organization(), domain())

  defp build_mail(:organization_domain_dropped_notice),
    do: Emailer.organization_domain_dropped_notice(organization(), domain())

  defp build_mail(:organization_domain_grace_email),
    do: Emailer.organization_domain_grace_email(user(), @address, organization(), domain(), true)

  defp build_mail(:organization_domain_verified_email),
    do: Emailer.organization_domain_verified_email(user(), @address, organization(), domain())

  defp build_mail(:organization_page_unverified_email),
    do: Emailer.organization_page_unverified_email(user(), @address, organization(), domain())

  defp build_mail(:moderation_frozen_email),
    do: Emailer.moderation_frozen_email(user(), @address, moderation_case())

  defp build_mail(:moderation_review_email),
    do: Emailer.moderation_review_email(user(), @address, moderation_case())

  defp build_mail(:moderation_revised_email),
    do: Emailer.moderation_revised_email(user(), @address)

  defp build_mail(:moderation_warning_email),
    do: Emailer.moderation_warning_email(user(), @address)

  defp build_mail(:moderation_suspension_email),
    do: Emailer.moderation_suspension_email(user(), @address, ~N[2026-09-01 00:00:00])

  defp build_mail(:moderation_deactivation_email),
    do: Emailer.moderation_deactivation_email(user(), @address)

  defp build_mail(:moderation_admin_urgent_email) do
    owner = insert(:user)

    case_record = %{
      moderation_case()
      | owner: owner,
        reports: [
          %Vutuv.Moderation.Report{
            category: "spam",
            note: "look at this",
            inserted_at: ~N[2026-08-15 10:00:00]
          }
        ]
    }

    Emailer.moderation_admin_urgent_email(user(), @address, case_record)
  end

  defp build_mail(:moderation_admin_digest_email),
    do: Emailer.moderation_admin_digest_email(user(), @address, 3)

  defp build_mail(:image_rejected_email),
    do:
      Emailer.image_rejected_email(user(), @address, %Vutuv.Moderation.ImageScan{
        kind: "avatar",
        category: "shocking"
      })

  defp build_mail(:job_posting_expiry_reminder_email),
    do:
      Emailer.job_posting_expiry_reminder_email(user(), @address, %Vutuv.Jobs.JobPosting{
        title: "Elixir Developer",
        slug: "elixir-developer",
        expires_on: ~D[2026-09-01]
      })

  defp user, do: insert(:user, locale: "en")

  defp organization, do: insert(:organization)

  defp domain do
    %Vutuv.Organizations.OrganizationDomain{
      domain: "acme.example",
      method: "dns",
      grace_deadline_at: ~N[2026-09-01 00:00:00]
    }
  end

  defp moderation_case, do: %Vutuv.Moderation.Case{id: Vutuv.UUIDv7.generate()}
end
