defmodule VutuvWeb.ModerationEvidenceControllerTest do
  @moduledoc """
  The token-guarded page headless Chromium shoots when a private message is
  reported: visible with a valid, fresh token only - it renders private
  messages, so anything else must be a hard 404.
  """
  use VutuvWeb.ConnCase

  alias Vutuv.Moderation
  alias Vutuv.Moderation.EvidenceScreenshot

  defp message_case do
    owner = insert_activated_user()
    insert(:email, user: owner)
    reporter = insert(:activated_user)
    conversation = insert_conversation_between(owner, reporter)
    insert(:message, conversation: conversation, sender: reporter, body: "earlier context")
    message = insert(:message, conversation: conversation, sender: owner, body: "the bad one")

    {:ok, case_record} =
      Moderation.report_content(reporter, message, %{"category" => "bullying"})

    {case_record, message}
  end

  test "renders the reported message with context for a valid token", %{conn: conn} do
    {case_record, _message} = message_case()

    conn = get(conn, ~p"/moderation/evidence/#{EvidenceScreenshot.sign_token(case_record.id)}")
    response = html_response(conn, 200)

    assert response =~ "the bad one"
    assert response =~ "earlier context"
    assert response =~ "reported message"
    assert get_resp_header(conn, "x-robots-tag") == ["noindex"]
  end

  test "a bad token is a 404", %{conn: conn} do
    assert conn |> get(~p"/moderation/evidence/garbage") |> html_response(404)
  end

  test "a token for a non-message case is a 404", %{conn: conn} do
    owner = insert_activated_user()
    insert(:email, user: owner)
    reporter = insert(:activated_user)
    {:ok, case_record} = Moderation.report_content(reporter, owner, %{"category" => "spam"})

    token = EvidenceScreenshot.sign_token(case_record.id)
    assert conn |> get(~p"/moderation/evidence/#{token}") |> html_response(404)
  end
end
