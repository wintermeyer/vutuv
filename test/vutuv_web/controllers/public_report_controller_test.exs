defmodule VutuvWeb.PublicReportControllerTest do
  @moduledoc """
  The notice form at `/system/report` (issue #2009), driven the way a rights
  holder without an account drives it: paste an address, send, read the mail,
  follow the link, press the button.

  Every one of these submits goes through `submit_with_csrf/3`, because
  `Phoenix.ConnTest` skips CSRF on a plain `post/3` and this is the app's one
  unauthenticated write endpoint — a form whose token does not survive its own
  redisplay is a form nobody can use.
  """

  use VutuvWeb.ConnCase, async: false

  import Vutuv.WebPushHelpers, only: [put_config: 2]

  alias Vutuv.Moderation
  alias Vutuv.Moderation.Report

  setup %{conn: conn} do
    owner = insert_activated_user()
    post = insert(:post, user: owner)
    {:ok, %{conn: conn, owner: owner, post: post}}
  end

  defp post_url(post), do: VutuvWeb.Endpoint.url() <> Vutuv.Posts.path(post)

  defp params(url, attrs \\ %{}) do
    %{
      "report" =>
        Map.merge(
          %{
            "url" => url,
            "category" => "copyright",
            "note" => "That photograph is mine; the original is at example.com/photo",
            "reporter_name" => "Rita Holder",
            "reporter_email" => "rita@example.com",
            "good_faith?" => "true"
          },
          attrs
        )
    }
  end

  defp submit(conn, url, attrs \\ %{}) do
    conn
    |> get(~p"/system/report")
    |> submit_with_csrf(~p"/system/report", params(url, attrs))
  end

  # The confirmation link out of the mail Swoosh caught.
  defp confirm_link do
    [email | _] = flush_emails()
    [_, path] = Regex.run(~r{(/system/report/confirm/[a-z0-9]+)}, email.text_body)
    path
  end

  describe "the form" do
    test "is reachable logged out and offers every category", %{conn: conn} do
      html = conn |> get(~p"/system/report") |> html_response(200)

      assert html =~ "notice-form"
      assert html =~ "report[url]"
      assert html =~ "report[reporter_email]"
      assert html =~ "notice-good-faith"

      for category <- Report.categories(), do: assert(html =~ ~s(value="#{category}"))
    end

    test "is linked from the footer and the Impressum", %{conn: conn} do
      assert conn |> get(~p"/community") |> html_response(200) =~ ~s(href="/system/report")
      assert conn |> get(~p"/impressum") |> html_response(200) =~ ~s(href="/system/report")
    end

    # The form's own rendered action, not a path the test knows: a Save button
    # posting to a retired URL is exactly what shipped once here.
    test "submits to the URL it renders", %{conn: conn, post: post} do
      conn = get(conn, ~p"/system/report")
      assert html_response(conn, 200) =~ ~s(action="/system/report")

      conn = submit_with_csrf(conn, ~p"/system/report", params(post_url(post)))
      assert html_response(conn, 200) =~ "Please confirm your report"
    end
  end

  describe "a pasted URL" do
    test "resolves in every spelling of the same page", %{conn: conn, post: post} do
      base = post_url(post)
      host = URI.parse(base).host
      path = URI.parse(base).path

      spellings = [
        base,
        base <> "/",
        base <> "?utm_source=newsletter",
        base <> "#comments",
        "http://" <> host <> path,
        "https://www." <> host <> path,
        "https://" <> String.upcase(host) <> path,
        # No scheme at all: an address copied out of a link's text rather than
        # out of the browser bar.
        host <> path,
        "  " <> base <> "  "
      ]

      for {url, index} <- Enum.with_index(spellings) do
        conn = submit(conn, url, %{"reporter_email" => "rita#{index}@example.com"})

        assert html_response(conn, 200) =~ "Please confirm your report",
               "#{url} should have resolved to the post"
      end

      assert Repo.aggregate(Report, :count) == length(spellings)
    end

    test "an address on another server says so", %{conn: conn} do
      conn = submit(conn, "https://mastodon.social/@somebody/1")

      assert html_response(conn, 422) =~ "not on this site"
    end

    test "a page that is not there is not found", %{conn: conn} do
      conn = submit(conn, VutuvWeb.Endpoint.url() <> "/no-such-handle")

      assert html_response(conn, 422) =~ "could not find that page"
    end

    # The anti-oracle rule: a frozen post is not public, so the form must not
    # confirm it exists — the answer is the one a typo gets.
    test "content an anonymous visitor cannot see is not found either", %{
      conn: conn,
      post: post
    } do
      url = post_url(post)
      Repo.update_all(Vutuv.Posts.Post, set: [frozen_at: NaiveDateTime.utc_now(:second)])

      conn = submit(conn, url)
      assert html_response(conn, 422) =~ "could not find that page"
    end
  end

  describe "the confirmation" do
    setup %{conn: conn, post: post} do
      conn = submit(conn, post_url(post))
      assert html_response(conn, 200) =~ "rita@example.com"
      {:ok, %{conn: conn, link: confirm_link()}}
    end

    test "the receipt mail goes to the address that was typed", %{post: post} do
      # `flush_emails/0` was drained by confirm_link/0, so re-read the report.
      report = Repo.get_by!(Report, reporter_email: "rita@example.com")
      assert report.case_id == Moderation.open_case_for(post).id
      assert is_nil(report.confirmed_at)
    end

    # A link scanner in a mail gateway follows every URL in a message. The GET
    # may therefore only show a button; the POST behind it is the takedown.
    test "the link's GET changes nothing", %{conn: conn, link: link, post: post} do
      html = conn |> recycle() |> get(link) |> html_response(200)

      assert html =~ "Confirm the report"
      assert is_nil(Repo.get!(Vutuv.Posts.Post, post.id).frozen_at)
      assert is_nil(Repo.get_by!(Report, reporter_email: "rita@example.com").confirmed_at)
    end

    test "pressing the button freezes the content and reaches the admins", %{
      conn: conn,
      link: link,
      post: post
    } do
      conn = conn |> recycle() |> get(link)
      conn = submit_with_csrf(conn, link, %{})

      assert html_response(conn, 200) =~ "with our admins"
      assert Repo.get!(Vutuv.Posts.Post, post.id).frozen_at
      assert Repo.get_by!(Report, reporter_email: "rita@example.com").confirmed_at
    end

    test "an unknown token is a 404", %{conn: conn} do
      conn = get(conn, ~p"/system/report/confirm/#{Vutuv.Token.random_token()}")
      assert conn.status == 404
    end

    # Told apart from the 404 on purpose: somebody holding a week-old link has
    # to be sent back to the form, not left thinking their address was wrong.
    test "an expired link says so and offers the form again", %{conn: conn, link: link} do
      Repo.update_all(Report,
        set: [confirmation_expires_at: NaiveDateTime.add(NaiveDateTime.utc_now(:second), -60)]
      )

      html =
        conn
        |> recycle()
        |> put_req_header("accept-language", "de-DE,de")
        |> get(link)
        |> html_response(410)

      assert html =~ "Dieser Link ist abgelaufen"
      assert html =~ "Meldung erneut senden"
      assert html =~ ~s(href="/system/report")
    end
  end

  describe "what a script gets" do
    test "the same address gets one receipt per piece of content", %{conn: conn, post: post} do
      conn = submit(conn, post_url(post))
      assert html_response(conn, 200) =~ "Please confirm your report"
      assert length(flush_emails()) == 1

      conn = submit(conn, post_url(post))
      assert html_response(conn, 422) =~ "already sent us this report"
      assert flush_emails() == []
      assert Repo.aggregate(Report, :count) == 1
    end

    test "the form is rate limited per client", %{conn: conn, owner: owner} do
      put_config(:rate_limit, enabled: true)
      Vutuv.RateLimiter.reset()

      posts = for _ <- 1..8, do: insert(:post, user: owner)

      responses =
        for {post, index} <- Enum.with_index(posts) do
          conn
          |> submit(post_url(post), %{"reporter_email" => "flood#{index}@example.com"})
          |> Map.fetch!(:status)
        end

      assert 429 in responses
    end
  end

  describe "German" do
    test "the form and the receipt mail are written in it", %{conn: conn, post: post} do
      conn = put_req_header(conn, "accept-language", "de-DE,de")

      html = conn |> get(~p"/system/report") |> html_response(200)
      assert html =~ "Adresse der Seite"
      assert html =~ "Ihr Name"
      assert html =~ "Melden Sie ehrlich"

      conn = submit(conn, post_url(post))
      assert html_response(conn, 200) =~ "Bitte bestätigen Sie Ihre Meldung"

      [email | _] = flush_emails()
      assert email.subject == "Bitte bestätigen Sie Ihre Meldung"
      assert email.text_body =~ "wir haben Ihre Meldung erhalten"
    end
  end
end
