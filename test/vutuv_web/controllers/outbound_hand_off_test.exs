defmodule VutuvWeb.OutboundHandOffTest do
  @moduledoc """
  The two form submissions whose destination is another site (issue #1569):
  "follow us from your own server" and the job board's easy apply.

  `form-action 'self'` is checked against every hop of a submission, redirects
  included, so answering either POST with a 302 to the outside is dropped by
  Chrome and WebKit — silently, which is why the button read as dead. The fix
  is a shape, not a header: the submission ends at a 200 here and the hop that
  leaves vutuv is an ordinary navigation. **These tests are calibrated against
  the un-fixed code**: every one of them goes red on a `redirect(external:)`.

  Only the two outbound channels moved. That the same-origin ones did *not* is
  covered where they already were — the apply-by-conversation redirect in
  `VutuvWeb.JobPostingTest`, the refusal flashes in
  `VutuvWeb.UserProfileFediverseTest`.

  Not async — the HTTP stub for the remote WebFinger lookup lives in the
  application env.
  """
  use VutuvWeb.ConnCase, async: false

  import Vutuv.FediverseHelpers
  import Vutuv.JobsHelpers

  alias Vutuv.Repo
  alias VutuvWeb.Fediverse.Docs

  describe "follow from your own server" do
    test "ends the submission here and links on to the dialog", %{conn: conn} do
      user = insert_activated_user(fediverse_followers?: true)
      serve_subscribe_template()

      conn = post(conn, ~p"/#{user}/fediverse/follow", %{"address" => "@them@social.example"})

      dialog =
        "https://social.example/authorize_interaction?uri=" <>
          URI.encode_www_form("acct:" <> Docs.acct(user))

      # 200, not 302: the hop the browser refused is gone...
      body = html_response(conn, 200)
      assert body =~ ~s|href="#{dialog}"|
      # ...and it is taken without a click, so the page is never seen.
      assert body =~ ~s|content="0;url=#{dialog}"|
    end

    test "German visitors read the server's name in the heading", %{conn: conn} do
      user = insert_activated_user(fediverse_followers?: true)
      serve_subscribe_template()

      conn =
        conn
        |> put_req_header("accept-language", "de-DE,de")
        |> post(~p"/#{user}/fediverse/follow", %{"address" => "@them@social.example"})

      body = html_response(conn, 200)
      assert body =~ "Weiter zu social.example"
      assert body =~ "Bestätigen Sie das Folgen auf Ihrem eigenen Server."
    end
  end

  describe "easy apply" do
    test "an employer's website is linked and taken automatically", %{conn: conn} do
      posting =
        publish_job!(nil, %{"apply_kind" => "url", "apply_url" => "https://acme.example/jobs"})

      conn = post(conn, ~p"/jobs/#{posting.slug}/apply")

      body = html_response(conn, 200)
      assert body =~ ~s|href="https://acme.example/jobs"|
      assert body =~ ~s|content="0;url=https://acme.example/jobs"|
      assert Repo.reload!(posting).apply_click_count == 1

      # Nobody reads a page the browser replaces in the same frame, so it does
      # not pay for the shell — but it must keep the head the refresh lives in.
      refute body =~ ~s|id="app-shell"|
    end

    test "a mailto waits for the click", %{conn: conn} do
      posting =
        publish_job!(nil, %{"apply_kind" => "email", "apply_email" => "jobs@acme.example"})

      conn = post(conn, ~p"/jobs/#{posting.slug}/apply")

      body = html_response(conn, 200)
      assert body =~ ~s|href="mailto:jobs@acme.example?subject=|
      assert body =~ "jobs@acme.example"

      # A browser hands a URL to an external program on a user gesture, not on
      # a page's say-so, so this one is a button and not a self-forward.
      refute body =~ ~s|http-equiv="refresh"|
      assert Repo.reload!(posting).apply_click_count == 1

      # This one IS read, so it gets the chrome — a bare dead end is worse.
      assert body =~ ~s|id="app-shell"|
    end
  end
end
