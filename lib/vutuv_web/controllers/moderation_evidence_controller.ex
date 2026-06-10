defmodule VutuvWeb.ModerationEvidenceController do
  @moduledoc """
  The standalone page headless Chromium shoots when a private message is
  reported (`Vutuv.Moderation.EvidenceScreenshot`): the reported message with
  its conversation context, rendered without the app shell. The thread is
  private, so the short-lived signed token in the URL is the only key -
  anything else is a 404.
  """

  use VutuvWeb, :controller

  alias Vutuv.Moderation
  alias Vutuv.Moderation.EvidenceScreenshot

  def show(conn, %{"token" => token}) do
    with {:ok, case_id} <- EvidenceScreenshot.verify_token(token),
         %Moderation.Case{content_type: "message"} = case_record <-
           Moderation.get_case_with_details(case_id),
         %Vutuv.Chat.Message{} = message <- Moderation.case_content(case_record) do
      conn
      |> put_resp_header("x-robots-tag", "noindex")
      |> put_root_layout(false)
      |> put_layout(false)
      |> render("show.html",
        case: case_record,
        context: Vutuv.Chat.moderation_context(message),
        reported_id: message.id
      )
    else
      _ -> VutuvWeb.ControllerHelpers.render_error(conn, 404)
    end
  end
end
