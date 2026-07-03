defmodule Vutuv.NewslettersTest do
  @moduledoc """
  The admin newsletter ("Rundbrief"): draft CRUD, the merge-variable rendering,
  the test send, and the broadcast (recipient selection, per-recipient logging,
  opt-out, and the single-send lock). Email delivers inline here
  (`config :vutuv, :async_email, false`), so the broadcast runs in-process and
  its mail lands in this process's Swoosh mailbox.
  """
  use Vutuv.DataCase

  alias Vutuv.Newsletters
  alias Vutuv.Newsletters.Markdown
  alias VutuvWeb.NewsletterToken

  defp admin, do: insert(:activated_user, first_name: "Erika", admin?: true)

  defp draft(admin, attrs \\ %{}) do
    params = Map.merge(%{"subject" => "Subject", "body" => "Body"}, attrs)
    {:ok, newsletter} = Newsletters.create_newsletter(params, admin)
    newsletter
  end

  defp member_with_email(value, attrs \\ []) do
    user = insert(:activated_user, attrs)
    insert(:email, user: user, value: value)
    user
  end

  describe "drafts" do
    test "create_newsletter/2 stores a draft owned by the admin" do
      admin = admin()

      assert {:ok, newsletter} =
               Newsletters.create_newsletter(%{"subject" => "Hi", "body" => "Hello"}, admin)

      assert newsletter.status == "draft"
      assert newsletter.author_id == admin.id
      assert is_nil(newsletter.sent_at)
    end

    test "create_newsletter/2 requires a subject and a body" do
      assert {:error, changeset} =
               Newsletters.create_newsletter(%{"subject" => "", "body" => ""}, admin())

      assert %{subject: _, body: _} = errors_on(changeset)
    end

    test "update_newsletter/2 edits the draft" do
      newsletter = draft(admin())
      assert {:ok, updated} = Newsletters.update_newsletter(newsletter, %{"subject" => "New"})
      assert updated.subject == "New"
    end

    test "delete_newsletter/1 removes it" do
      newsletter = draft(admin())
      assert {:ok, _} = Newsletters.delete_newsletter(newsletter)
      assert is_nil(Newsletters.get_newsletter(newsletter.id))
    end
  end

  describe "merge variables" do
    test "the documented catalog and the per-recipient substitution map stay in lockstep" do
      # A documented {{merge var}} that nothing fills would silently never
      # substitute; a filled key the catalog omits is invisible to admins. The
      # two lists live in different modules, so this guards against drift.
      user = insert(:activated_user, first_name: "Erika", last_name: "Mustermann")

      catalog = Newsletters.variables() |> Enum.map(&elem(&1, 0)) |> MapSet.new()

      filled =
        user |> Newsletters.substitutions("erika@example.com") |> Map.keys() |> MapSet.new()

      assert catalog == filled
    end

    test "apply_vars/3 substitutes known variables and leaves unknown ones" do
      subs = %{"first_name" => "Ann", "greeting" => "Hi Ann"}
      assert Markdown.apply_vars("{{greeting}}, {{first_name}}!", subs) == "Hi Ann, Ann!"
      assert Markdown.apply_vars("{{unknown}}", subs) == "{{unknown}}"
    end

    test "apply_vars/3 HTML-escapes values when asked" do
      subs = %{"name" => "Tom & <b>Jerry</b>"}
      assert Markdown.apply_vars("{{name}}", subs, escape: true) =~ "Tom &amp; &lt;b&gt;"
    end

    test "to_email_html/1 renders Markdown with inline styles, leaving merge tags intact" do
      html = Markdown.to_email_html("# Hello {{first_name}}\n\nSome **text**.")
      assert html =~ "<h1"
      assert html =~ "style="
      assert html =~ "{{first_name}}"
      assert html =~ "<strong>text</strong>"
    end

    test "a merge tag inside a bare URL is still substituted into the link target" do
      # Earmark's autolinker percent-encodes the braces in the href
      # (/%7B%7Busername%7D%7D) while the visible link text keeps {{username}},
      # so a substitution running only on the literal form fixes the text but
      # leaves the link target broken - the July 2026 newsletter shipped 3,075
      # profile links that 404'd exactly this way.
      html =
        "Dein Profil: https://vutuv.de/{{username}}"
        |> Markdown.to_email_html()
        |> Markdown.apply_vars(%{"username" => "erika"}, escape: true)

      assert html =~ ~s(href="https://vutuv.de/erika")
      refute html =~ "%7B"
      refute html =~ "{{username}}"
    end

    test "a merge tag in a tracked bare URL gets both the value and the click token" do
      html =
        "Dein Profil: http://localhost:4000/{{username}}"
        |> Markdown.to_email_html(track: true)
        |> Markdown.apply_vars(%{"username" => "erika"}, escape: true)
        |> Markdown.put_click_token("TOKEN-123")

      assert html =~ ~s(href="http://localhost:4000/erika?nlt=TOKEN-123")
    end

    test "to_email_html/1 turns a single newline into a line break (multi-line signatures)" do
      html = Markdown.to_email_html("Viele Grüße\nStefan Wintermeyer")
      assert html =~ "Viele Grüße"
      assert html =~ "Stefan Wintermeyer"
      assert html =~ "<br"
    end

    test "to_email_html/1 still starts a new paragraph on a blank line" do
      html = Markdown.to_email_html("First.\n\nSecond.")
      assert length(Regex.scan(~r/<p\b/, html)) == 2
    end

    test "to_email_html/1 keeps leading-space indentation after a break (as nbsp)" do
      html = Markdown.to_email_html("Viele Grüße\n  Stefan Wintermeyer")
      assert html =~ "  Stefan Wintermeyer"
    end
  end

  describe "click tracking (link rewriting)" do
    # In the test env the configured public host is "localhost", so a link to it
    # is "internal" and gets the tracking placeholder; example.com does not.
    test "to_email_html/2 with track: true adds the placeholder to internal links only" do
      html =
        Markdown.to_email_html(
          "[here](http://localhost:4000/welcome) and [there](https://example.com/x)",
          track: true
        )

      assert html =~ "http://localhost:4000/welcome?nlt=__vutuv_nlt__"
      assert html =~ "https://example.com/x"
      refute html =~ "example.com/x?nlt"
    end

    test "to_email_html/2 leaves links untouched without tracking (the admin preview)" do
      html = Markdown.to_email_html("[here](http://localhost:4000/welcome)")
      assert html =~ "http://localhost:4000/welcome"
      refute html =~ "nlt="
    end

    test "to_email_html/2 appends to a link that already has a query string" do
      html = Markdown.to_email_html("[s](http://localhost:4000/search?q=a)", track: true)
      assert html =~ "q=a"
      assert html =~ "nlt=__vutuv_nlt__"
    end

    test "put_click_token/2 swaps the placeholder for the per-recipient token" do
      html = Markdown.to_email_html("[here](http://localhost:4000/welcome)", track: true)
      out = Markdown.put_click_token(html, "TOKEN-123")

      assert out =~ "nlt=TOKEN-123"
      refute out =~ "__vutuv_nlt__"
    end

    test "the plain-text body keeps the bare link, the HTML href carries a verifiable token" do
      admin = admin()
      ann = member_with_email("ann@example.com", first_name: "Ann")

      newsletter =
        draft(admin, %{
          "subject" => "S",
          "body" => "Visit [profile](http://localhost:4000/welcome)."
        })

      newsletter_id = newsletter.id
      ann_id = ann.id

      assert {:ok, :started} = Newsletters.start_broadcast(newsletter)
      [email] = flush_emails()

      assert [_, token] = Regex.run(~r/nlt=([\w.\-]+)/, email.html_body)
      assert {:ok, ^newsletter_id, ^ann_id} = NewsletterToken.verify(token)

      # The ASCII version uses only the normal link, no tracking parameter.
      refute email.text_body =~ "nlt="
      assert email.text_body =~ "http://localhost:4000/welcome"
    end
  end

  describe "click stats" do
    setup do
      admin = admin()
      ann = member_with_email("ann@example.com", first_name: "Ann")
      bob = member_with_email("bob@example.com", first_name: "Bob")
      newsletter = draft(admin)
      {:ok, :started} = Newsletters.start_broadcast(newsletter)
      flush_emails()
      %{admin: admin, ann: ann, bob: bob, newsletter: Newsletters.get_newsletter!(newsletter.id)}
    end

    test "record_click + newsletter_stats + link_stats", ctx do
      %{newsletter: nl, ann: ann, bob: bob} = ctx

      assert :ok = Newsletters.record_click(nl.id, ann.id, "/welcome")
      assert :ok = Newsletters.record_click(nl.id, ann.id, "/welcome")
      assert :ok = Newsletters.record_click(nl.id, bob.id, "/jobs")

      stats = Newsletters.newsletter_stats(nl)
      assert stats.recipients == 2
      assert stats.total_clicks == 3
      assert stats.unique_clickers == 2
      assert_in_delta stats.click_rate, 100.0, 0.001

      assert [
               %{url: "/welcome", clicks: 2, clickers: 1},
               %{url: "/jobs", clicks: 1, clickers: 1}
             ] = Newsletters.link_stats(nl)
    end

    test "clicks by non-recipients (e.g. an admin testing) are excluded from the numbers", ctx do
      %{newsletter: nl, ann: ann, admin: admin} = ctx

      Newsletters.record_click(nl.id, ann.id, "/welcome")
      # The admin has no deliverable email, so was not a broadcast recipient.
      Newsletters.record_click(nl.id, admin.id, "/welcome")

      stats = Newsletters.newsletter_stats(nl)
      assert stats.total_clicks == 1
      assert stats.unique_clickers == 1
    end

    test "list_clicks paginates newest first, with the member preloaded", ctx do
      %{newsletter: nl, ann: ann, bob: bob} = ctx
      Newsletters.record_click(nl.id, ann.id, "/welcome")
      Newsletters.record_click(nl.id, bob.id, "/jobs")

      assert Newsletters.count_clicks(nl) == 2
      clicks = Newsletters.list_clicks(nl)
      assert length(clicks) == 2
      assert Enum.all?(clicks, &(&1.user != nil))
    end
  end

  describe "deliver_test/3" do
    test "sends one email with variables substituted and logs it as a test" do
      admin = admin()

      newsletter =
        draft(admin, %{
          "subject" => "News for {{first_name}}",
          "body" => "{{greeting}},\n\nHello."
        })

      assert {:ok, delivery} = Newsletters.deliver_test(newsletter, "probe@example.com", admin)
      assert delivery.kind == "test"
      assert delivery.status == "sent"
      assert delivery.email == "probe@example.com"
      assert is_nil(delivery.user_id)

      assert_received {:email, email}
      assert email.subject == "News for Erika"
      assert {_name, "probe@example.com"} = hd(email.to)
      assert email.html_body =~ "Hi Erika"
      assert email.text_body =~ "Hi Erika"
      # Even a test carries the one-click unsubscribe (so the preview is faithful);
      # it points at the admin's own newsletter switch.
      assert Map.has_key?(email.headers, "List-Unsubscribe-Post")
      assert email.html_body =~ "unsubscribe/"
    end

    test "rejects an invalid address and logs nothing" do
      newsletter = draft(admin())

      assert {:error, :invalid_email} =
               Newsletters.deliver_test(newsletter, "not-an-email", admin())

      assert Newsletters.list_deliveries(newsletter) == []
    end
  end

  describe "start_broadcast/1" do
    test "sends to every eligible member, logs each, and marks the newsletter sent" do
      admin = admin()
      ann = member_with_email("ann@example.com", first_name: "Ann")
      bob = member_with_email("bob@example.com", first_name: "Bob")

      newsletter = draft(admin, %{"subject" => "Hi {{first_name}}", "body" => "{{greeting}}!"})

      assert {:ok, :started} = Newsletters.start_broadcast(newsletter)

      newsletter = Newsletters.get_newsletter!(newsletter.id)
      assert newsletter.status == "sent"
      assert newsletter.sent_at
      assert newsletter.recipient_count == 2

      deliveries = Newsletters.list_deliveries(newsletter)
      assert length(deliveries) == 2
      assert Enum.all?(deliveries, &(&1.kind == "broadcast" and &1.status == "sent"))
      assert MapSet.new(deliveries, & &1.user_id) == MapSet.new([ann.id, bob.id])

      emails = flush_emails()
      assert length(emails) == 2
      subjects = Enum.map(emails, & &1.subject)
      assert "Hi Ann" in subjects
      assert "Hi Bob" in subjects
      # Broadcast mail carries the one-click unsubscribe.
      assert Enum.all?(emails, &Map.has_key?(&1.headers, "List-Unsubscribe-Post"))
    end

    test "skips members who opted out of the newsletter" do
      admin = admin()
      member_with_email("in@example.com", first_name: "In")
      member_with_email("out@example.com", first_name: "Out", newsletter_emails?: false)

      newsletter = draft(admin)
      assert {:ok, :started} = Newsletters.start_broadcast(newsletter)

      newsletter = Newsletters.get_newsletter!(newsletter.id)
      assert newsletter.recipient_count == 1
      emails = flush_emails()
      assert [%{to: [{_, "in@example.com"}]}] = emails
    end

    test "skips unconfirmed members" do
      admin = admin()
      member_with_email("ok@example.com")
      unconfirmed = insert(:user, email_confirmed?: false)
      insert(:email, user: unconfirmed, value: "pending@example.com")

      newsletter = draft(admin)
      assert {:ok, :started} = Newsletters.start_broadcast(newsletter)

      assert Newsletters.get_newsletter!(newsletter.id).recipient_count == 1
    end

    test "refuses a second broadcast" do
      admin = admin()
      member_with_email("ann@example.com")
      newsletter = draft(admin)

      assert {:ok, :started} = Newsletters.start_broadcast(newsletter)
      newsletter = Newsletters.get_newsletter!(newsletter.id)
      assert {:error, :already_sent} = Newsletters.start_broadcast(newsletter)
    end
  end

  describe "eligible_count/0" do
    test "counts confirmed, reachable, subscribed members with a deliverable email" do
      member_with_email("a@example.com")
      member_with_email("b@example.com")
      member_with_email("opted-out@example.com", newsletter_emails?: false)
      insert(:activated_user, first_name: "NoEmail")

      assert Newsletters.eligible_count() == 2
    end
  end

  describe "delivery log (filter / search / sort / paginate)" do
    test "delivery_filters/1 validates values and applies defaults" do
      assert %{kind: "test", status: nil, q: "abc", sort: "status", dir: "asc"} =
               Newsletters.delivery_filters(%{
                 "kind" => "test",
                 "status" => "bogus",
                 "q" => "  abc  ",
                 "sort" => "status",
                 "dir" => "asc"
               })

      assert %{kind: nil, status: nil, q: nil, sort: "when", dir: "desc"} =
               Newsletters.delivery_filters(%{})
    end

    test "filters by kind" do
      admin = admin()
      newsletter = draft(admin)
      {:ok, _} = Newsletters.deliver_test(newsletter, "probe@example.com", admin)
      member_with_email("member@example.com")
      {:ok, :started} = Newsletters.start_broadcast(newsletter)
      flush_emails()

      assert Newsletters.count_deliveries(newsletter, %{kind: "test"}) == 1
      assert Newsletters.count_deliveries(newsletter, %{kind: "broadcast"}) == 1

      assert [%{email: "probe@example.com"}] =
               Newsletters.list_deliveries(newsletter, %{kind: "test"})
    end

    test "searches by email and by username" do
      admin = admin()
      newsletter = draft(admin)
      member = insert(:activated_user, username: "graceh")
      insert(:email, user: member, value: "grace@hopper.test")
      {:ok, :started} = Newsletters.start_broadcast(newsletter)
      {:ok, _} = Newsletters.deliver_test(newsletter, "other@example.com", admin)
      flush_emails()

      assert [%{email: "grace@hopper.test"}] =
               Newsletters.list_deliveries(newsletter, %{q: "hopper"})

      assert [%{user: %{username: "graceh"}}] =
               Newsletters.list_deliveries(newsletter, %{q: "graceh"})

      assert Newsletters.list_deliveries(newsletter, %{q: "nomatch"}) == []
    end

    test "search escapes LIKE wildcards" do
      admin = admin()
      newsletter = draft(admin)
      {:ok, _} = Newsletters.deliver_test(newsletter, "real@example.com", admin)
      flush_emails()

      # "%" is a literal here, not a wildcard, so it matches nothing.
      assert Newsletters.list_deliveries(newsletter, %{q: "%"}) == []
    end

    test "sorts by recipient ascending and descending" do
      admin = admin()
      newsletter = draft(admin)
      {:ok, _} = Newsletters.deliver_test(newsletter, "zoe@example.com", admin)
      {:ok, _} = Newsletters.deliver_test(newsletter, "amy@example.com", admin)
      flush_emails()

      asc = Newsletters.list_deliveries(newsletter, %{sort: "recipient", dir: "asc"})
      assert Enum.map(asc, & &1.email) == ["amy@example.com", "zoe@example.com"]

      desc = Newsletters.list_deliveries(newsletter, %{sort: "recipient", dir: "desc"})
      assert Enum.map(desc, & &1.email) == ["zoe@example.com", "amy@example.com"]
    end

    test "paginates" do
      admin = admin()
      newsletter = draft(admin)
      for i <- 1..3, do: Newsletters.deliver_test(newsletter, "u#{i}@example.com", admin)
      flush_emails()

      assert Newsletters.count_deliveries(newsletter) == 3

      assert length(
               Newsletters.list_deliveries(newsletter, %{}, %{"page" => "1"},
                 per_page: 2,
                 total: 3
               )
             ) == 2

      assert length(
               Newsletters.list_deliveries(newsletter, %{}, %{"page" => "2"},
                 per_page: 2,
                 total: 3
               )
             ) == 1
    end
  end
end
