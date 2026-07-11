defmodule VutuvWeb.JobPostingController do
  @moduledoc """
  The public job-posting detail page (issue #932). Like the profile and
  organization pages it is a controller in front of a LiveView so it can
  negotiate the agent-format siblings (`/jobs/:slug.md/.txt/.json/.xml`); the
  HTML render is `VutuvWeb.JobPostingLive.Show`.

  `apply/2` is the "easy apply" endpoint: it counts the click and routes to the
  employer's channel — an outbound URL, a prefilled mailto, or a vutuv
  conversation with the poster — so vutuv never stores an applications table
  (staying out of §26 BDSG candidate-data controllership).
  """

  use VutuvWeb, :controller

  import Phoenix.LiveView.Controller, only: [live_render: 3]

  alias Vutuv.Jobs
  alias VutuvWeb.AgentDocs
  alias VutuvWeb.AgentDocs.JobPostingDoc
  alias VutuvWeb.ControllerHelpers

  def show(conn, %{"slug" => slug}) do
    case Jobs.fetch_visible_job_posting(slug, conn.assigns[:current_user]) do
      {:ok, posting} -> render_page(conn, posting)
      {:error, :not_found} -> ControllerHelpers.render_error(conn, 404)
    end
  end

  defp render_page(conn, posting) do
    case AgentDocs.negotiate(conn) do
      :html ->
        conn
        |> AgentDocs.put_html_alternates()
        |> put_layout(html: false)
        |> live_render(VutuvWeb.JobPostingLive.Show,
          session: Map.put(base_session(conn), "slug", posting.slug)
        )

      format ->
        send_job_doc(conn, format, posting)
    end
  end

  # The agent siblings render the anonymous public view, so they 404 for any
  # posting that is not a live, geo? posting no matter who asks.
  defp send_job_doc(conn, format, posting) do
    if Jobs.agent_visible?(posting) do
      # The doc builder reads the employer, tags and location, so preload here
      # (the visibility fetch is deliberately bare).
      doc = posting |> Jobs.preload_for_show() |> JobPostingDoc.build_show()
      AgentDocs.send_doc(conn, format, doc)
    else
      ControllerHelpers.render_error(conn, 404)
    end
  end

  def apply(conn, %{"slug" => slug}) do
    viewer = conn.assigns[:current_user]

    case Jobs.fetch_visible_job_posting(slug, viewer) do
      {:ok, posting} -> do_apply(conn, posting, viewer)
      {:error, :not_found} -> ControllerHelpers.render_error(conn, 404)
    end
  end

  defp do_apply(conn, %{apply_kind: :url, apply_url: url} = posting, _viewer)
       when is_binary(url) do
    Jobs.increment_apply_click(posting)
    redirect(conn, external: url)
  end

  defp do_apply(conn, %{apply_kind: :email, apply_email: email} = posting, _viewer)
       when is_binary(email) do
    Jobs.increment_apply_click(posting)
    subject = URI.encode_www_form(gettext("Application: %{title}", title: posting.title))
    redirect(conn, external: "mailto:#{email}?subject=#{subject}")
  end

  defp do_apply(conn, %{apply_kind: :message}, nil) do
    conn
    |> put_flash(:info, gettext("Please log in to message the poster."))
    |> redirect(to: ~p"/login")
  end

  defp do_apply(conn, %{apply_kind: :message} = posting, _viewer) do
    posting = Jobs.preload_for_show(posting)
    Jobs.increment_apply_click(posting)
    url = AgentDocs.abs_url("/jobs/#{posting.slug}")
    body = gettext("I'm interested in your posting: %{url}", url: url)
    redirect(conn, to: ~p"/messages/with/#{posting.user.username}?#{[body: body]}")
  end

  defp do_apply(conn, _posting, _viewer), do: ControllerHelpers.render_error(conn, 404)

  defp base_session(conn) do
    %{
      "user_id" => conn.assigns[:current_user_id],
      "locale" => conn.assigns[:locale],
      "request_path" => conn.request_path
    }
  end
end
