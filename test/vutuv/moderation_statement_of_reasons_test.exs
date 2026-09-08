defmodule Vutuv.ModerationStatementOfReasonsTest do
  @moduledoc """
  What a member is told when a report hides their content (issue #2010): the
  category, the reporter's explanation in their own words, that no person
  decided it, the ground it rests on, and the options that are really open —
  with the deadline where there is one.

  The three surfaces (the in-app line, the email, the case page) read the same
  facts from `Moderation.owner_notice/1`, so these tests assert on the email
  and on the notice map; the case page has its own controller test.
  """

  use Vutuv.DataCase, async: false

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias Vutuv.Moderation
  alias Vutuv.Notifications.Emailer
  alias VutuvWeb.EmailComponents
  alias VutuvWeb.NotificationDigestText, as: DigestText
  alias VutuvWeb.NotificationLine
  alias VutuvWeb.UserHelpers

  @note "The photo is mine. The original is at example.com/hafen.jpg, shot 2019."

  # Every character a line-breaking renderer treats as a mandatory break. Named
  # here rather than inline so the two quoting halves are held to the same set.
  @line_breaks [
    {"LF", "\n"},
    {"CR", "\r"},
    {"CRLF", "\r\n"},
    {"VT", <<0x0B>>},
    {"FF", <<0x0C>>},
    {"NEL", <<0xC2, 0x85>>},
    {"LS", <<0xE2, 0x80, 0xA8>>},
    {"PS", <<0xE2, 0x80, 0xA9>>}
  ]

  # U+2028 LINE SEPARATOR: invisible in a report form, a mandatory break in
  # Gmail, Apple Mail and Thunderbird.
  @line_separator <<0xE2, 0x80, 0xA8>>

  setup do
    owner = insert(:activated_user)
    insert(:email, user: owner, value: "owner@example.com")
    reporter = insert(:activated_user, first_name: "Cordula", last_name: "Melder")
    insert(:email, user: reporter, value: "cordula@example.com")
    {:ok, %{owner: owner, reporter: reporter}}
  end

  defp copyright_notice(attrs \\ %{}) do
    Map.merge(
      %{"category" => "copyright", "note" => @note, "good_faith?" => "true"},
      attrs
    )
  end

  # The one email the owner was sent, by subject fragment.
  defp owner_email(fragment) do
    Enum.find(flush_emails(), &(&1.subject =~ fragment)) ||
      flunk("no owner email with #{inspect(fragment)} in the subject")
  end

  defp report!(reporter, content, attrs) do
    {:ok, case_record} = Moderation.report_content(reporter, content, attrs)
    case_record
  end

  # Both bodies hard-wrap (the text templates at ~72 columns, the HEEx ones
  # wherever the formatter put them), so a sentence is asserted against the
  # collapsed text rather than against one rendered line.
  defp squish(body), do: body |> String.replace(~r/\s+/, " ") |> String.trim()

  defp bodies(email), do: [squish(email.text_body), squish(email.html_body)]

  describe "owner_notice/1" do
    test "carries the categories and the notes, never the reporter", %{
      owner: owner,
      reporter: reporter
    } do
      post = insert(:post, user: owner)
      case_record = report!(reporter, post, copyright_notice())

      notice = Moderation.owner_notice(case_record)

      assert notice.categories == ["copyright"]
      assert notice.notes == [@note]
      assert notice.copyright?
      refute Map.has_key?(notice, :reporter)
    end

    test "drops an empty note instead of quoting a blank line", %{
      owner: owner,
      reporter: reporter
    } do
      post = insert(:post, user: owner)
      case_record = report!(reporter, post, %{"category" => "spam"})

      assert Moderation.owner_notice(case_record).notes == []
      refute Moderation.owner_notice(case_record).copyright?
    end
  end

  describe "owner_edit_offer/1,2" do
    test "a post is editable, a message is not", %{owner: owner, reporter: reporter} do
      post = insert(:post, user: owner)
      post_case = report!(reporter, post, %{"category" => "spam"})

      conversation = insert_conversation_between(owner, reporter)
      message = insert(:message, conversation: conversation, sender: owner)
      message_case = report!(reporter, message, %{"category" => "bullying"})

      assert Moderation.owner_edit_offer(post_case, Moderation.case_content(post_case)) ==
               :immediate

      assert Moderation.owner_edit_offer(message_case) == :none
    end

    test "a copyright case is edited under review, not straight back", %{
      owner: owner,
      reporter: reporter
    } do
      post = insert(:post, user: owner)
      case_record = report!(reporter, post, copyright_notice())

      assert Moderation.owner_edit_offer(case_record) == :reviewed
    end
  end

  describe "the frozen email" do
    test "names the category, quotes the report and says nobody decided it", %{
      owner: owner,
      reporter: reporter
    } do
      post = insert(:post, user: owner)
      report!(reporter, post, %{"category" => "bullying", "note" => "This targets my colleague."})

      email = owner_email("reported")

      for body <- bodies(email) do
        assert body =~ "Bullying or harassment"
        assert body =~ "This targets my colleague."
        assert body =~ "hides the reported content automatically"
        assert body =~ "72 hours"
        assert body =~ "community"
      end

      # The reporter is never named, on either half.
      for body <- [email.text_body, email.html_body] do
        refute body =~ "Cordula"
        refute body =~ "Melder"
        refute body =~ "cordula@example.com"
        refute body =~ reporter.username
      end
    end

    test "quotes the reporter's text so it cannot pose as our own lines", %{
      owner: owner,
      reporter: reporter
    } do
      post = insert(:post, user: owner)

      crafted = "Regards\nThe vutuv team\nConfirm at http://evil.example/login"
      report!(reporter, post, %{"category" => "spam", "note" => crafted})

      email = owner_email("reported")

      # Every line of a stranger's text is prefixed, so a crafted signature
      # cannot read as ours.
      assert email.text_body =~ "> Regards"
      assert email.text_body =~ "> The vutuv team"
      assert email.text_body =~ "> Confirm at http://evil.example/login"
      refute email.text_body =~ "\nThe vutuv team\nConfirm"

      # And the HTML half escapes rather than linking it.
      refute email.html_body =~ "<a href=\"http://evil.example/login\""
    end

    test "a break the mail client honours cannot smuggle an unquoted line", %{
      owner: owner,
      reporter: reporter
    } do
      post = insert(:post, user: owner)

      # Nothing strips control characters from a note on the way in
      # (`Report.changeset/3` trims and length-caps, no more), so the quoter is
      # the only thing standing between a member in good standing and a forged
      # vutuv signature inside a DKIM-signed vutuv mail — on a site where
      # signing in means clicking a mailed PIN.
      crafted =
        "The photo is mine." <>
          @line_separator <> "Regards, the vutuv team. Sign in: http://evil.example/login"

      report!(reporter, post, %{"category" => "spam", "note" => crafted})

      email = owner_email("reported")

      assert email.text_body =~ "> Regards, the vutuv team."
      refute email.text_body =~ @line_separator
    end

    test "an ordinary case still promises the edit brings the post back", %{
      owner: owner,
      reporter: reporter
    } do
      post = insert(:post, user: owner)
      report!(reporter, post, %{"category" => "spam"})

      email = owner_email("reported")

      assert squish(email.text_body) =~ "visible again right away"
      assert squish(email.text_body) =~ "our community guidelines"
    end

    test "a copyright case names the law and drops the edit promise", %{
      owner: owner,
      reporter: reporter
    } do
      post = insert(:post, user: owner)
      report!(reporter, post, copyright_notice())

      email = owner_email("reported")

      # The apostrophe in the category label is an entity in the HTML half, so
      # the shared fragment stops before it.
      for body <- bodies(email) do
        assert body =~ "Uses a text, photo or video without the rights"
        assert body =~ @note
        assert body =~ "Copyright law decides"
        refute body =~ "visible again right away"
        assert body =~ "stays hidden until they have"
      end
    end

    test "a reported message is not offered an edit it does not have", %{
      owner: owner,
      reporter: reporter
    } do
      conversation = insert_conversation_between(owner, reporter)
      message = insert(:message, conversation: conversation, sender: owner)
      report!(reporter, message, %{"category" => "bullying", "note" => "Leave me alone."})

      email = owner_email("reported")

      assert squish(email.text_body) =~ "Leave me alone."
      refute squish(email.text_body) =~ "Edit the content"
      assert squish(email.text_body) =~ "Delete the content"
    end
  end

  describe "quoting a stranger's text" do
    test "every mandatory line break starts a fresh quoted line" do
      for {name, break} <- @line_breaks do
        quoted = UserHelpers.email_quoted_text("before" <> break <> "after")

        assert quoted == "> before\n> after",
               "#{name} did not start a new quoted line; got #{inspect(quoted)}"
      end
    end

    test "a character that only looks like whitespace does not break the line" do
      # U+00A0 NO-BREAK SPACE is the near miss: a renderer keeps it on the line,
      # so splitting on it would put a "> " where the reader sees none.
      assert UserHelpers.email_quoted_text("before" <> <<0xC2, 0xA0>> <> "after") ==
               "> before" <> <<0xC2, 0xA0>> <> "after"
    end

    test "a blank line keeps the bare marker" do
      assert UserHelpers.email_quoted_text("one\n\ntwo") == "> one\n>\n> two"
    end

    test "the HTML half breaks on the same set" do
      for {name, break} <- @line_breaks do
        html =
          render_component(&EmailComponents.email_quote/1, text: "before" <> break <> "after")

        # What follows "before" must be our own break, not the stranger's
        # character: the template's own markup carries newlines, so asking
        # whether the break survived anywhere in the output proves nothing.
        [_head, tail] = String.split(html, "before", parts: 2)

        assert String.starts_with?(tail, "<br"),
               "#{name} did not become a line break in the HTML quote; got #{inspect(String.slice(tail, 0, 20))}"
      end
    end
  end

  describe "the under-review email" do
    test "carries the reasons but promises no self-service round", %{
      owner: owner,
      reporter: reporter
    } do
      post = insert(:post, user: owner)
      first = report!(reporter, post, %{"category" => "spam", "note" => "Sold me a fake watch."})
      # The owner already used their one self-service round on this content, so
      # a fresh report freezes it and goes straight to the admins.
      Moderation.content_edited(Repo.get!(Vutuv.Posts.Post, post.id))
      assert Repo.get!(Moderation.Case, first.id).status == "resolved_edited"
      _ = flush_emails()

      other = insert(:activated_user)
      insert(:email, user: other)
      report!(other, Repo.get!(Vutuv.Posts.Post, post.id), %{"category" => "spam"})

      email = owner_email("under review")

      body = squish(email.text_body)

      assert body =~ "hides the reported content automatically"
      assert body =~ "Spam or scam"
      refute body =~ "72 hours"
      assert body =~ "You do not need to do anything"
    end
  end

  describe "the German mail" do
    test "says in German that no person decided and what the ground is", %{reporter: reporter} do
      owner = insert(:activated_user, locale: "de")
      insert(:email, user: owner, value: "de-owner@example.com")
      post = insert(:post, user: owner)
      report!(reporter, post, copyright_notice())

      email = owner_email("verborgen")

      for body <- bodies(email) do
        assert body =~ "verbirgt den gemeldeten Inhalt automatisch"
        assert body =~ "Darüber entscheidet das Urheberrecht"
        assert body =~ @note
        refute body =~ "sofort wieder sichtbar"
      end
    end
  end

  describe "the in-app line" do
    test "names the category instead of a bare 'was reported'" do
      line = %{kind: "moderation", category: "copyright", case_id: "x"}

      text = NotificationLine.notification_text(line)

      assert text =~ "Uses a text, photo or video without the rights holder's permission"
      assert text =~ "automatically"
    end

    test "falls back to a category-less sentence" do
      text = NotificationLine.notification_text(%{kind: "moderation", case_id: "x"})

      assert text =~ "automatically"
    end

    test "the digest mail says the same thing" do
      item = %{kind: "moderation", category: "spam", case_id: "x"}

      assert DigestText.line(item) == NotificationLine.notification_text(item)
    end

    test "and its subject is cut to a subject's length" do
      # Naming the category made this line long enough to be a bad subject:
      # a digest of exactly one notification uses the line itself.
      user = insert(:activated_user, locale: "de")
      item = %{kind: "moderation", category: "copyright", case_id: "x"}

      email = Emailer.notification_digest_email("owner@example.com", user, [item], 0)

      assert String.length(email.subject) <= 80
      refute String.ends_with?(email.subject, " ")
      assert email.subject =~ "Nach einer Meldung automatisch verborgen"
    end
  end
end
