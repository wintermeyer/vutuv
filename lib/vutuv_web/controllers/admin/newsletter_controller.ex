defmodule VutuvWeb.Admin.NewsletterController do
  @moduledoc """
  The admin email newsletter ("Rundbrief"). An admin composes a newsletter
  (Markdown + merge variables), saves it as a draft, sends a test to one address
  to check it, then broadcasts it to every eligible member. Every send is logged
  (`Vutuv.Newsletters`), so the show page is also the delivery protocol.

  Admins-only via the `:admin` pipeline on the whole `/admin` scope.
  """

  use VutuvWeb, :controller

  alias Vutuv.Newsletters
  alias Vutuv.Newsletters.Newsletter
  alias VutuvWeb.ControllerHelpers

  def index(conn, _params) do
    render(conn, "index.html",
      page_title: gettext("Newsletters"),
      newsletters: Newsletters.list_newsletters(),
      eligible_count: Newsletters.eligible_count()
    )
  end

  def new(conn, _params) do
    render(conn, "new.html",
      page_title: gettext("New newsletter"),
      changeset: Newsletters.change_newsletter(%Newsletter{})
    )
  end

  def create(conn, %{"newsletter" => params}) do
    case Newsletters.create_newsletter(params, conn.assigns.current_user) do
      {:ok, newsletter} ->
        conn
        |> put_flash(:info, gettext("Draft saved."))
        |> redirect(to: ~p"/admin/newsletters/#{newsletter}")

      {:error, changeset} ->
        render(conn, "new.html", page_title: gettext("New newsletter"), changeset: changeset)
    end
  end

  def show(conn, %{"id" => id} = params) do
    with_newsletter(conn, id, fn newsletter ->
      filters = Newsletters.delivery_filters(params)
      total = Newsletters.count_deliveries(newsletter, filters)

      render(conn, "show.html",
        page_title: newsletter.subject,
        newsletter: newsletter,
        preview: Newsletters.preview(newsletter, conn.assigns.current_user),
        filters: filters,
        delivery_total: total,
        deliveries: Newsletters.list_deliveries(newsletter, filters, params, total: total)
      )
    end)
  end

  def edit(conn, %{"id" => id}) do
    with_newsletter(conn, id, fn newsletter ->
      if Newsletter.draft?(newsletter) do
        render(conn, "edit.html",
          page_title: gettext("Edit newsletter"),
          newsletter: newsletter,
          changeset: Newsletters.change_newsletter(newsletter)
        )
      else
        already_sent(conn, newsletter)
      end
    end)
  end

  def update(conn, %{"id" => id, "newsletter" => params}) do
    with_newsletter(conn, id, fn newsletter ->
      if Newsletter.draft?(newsletter) do
        save_draft(conn, newsletter, params)
      else
        already_sent(conn, newsletter)
      end
    end)
  end

  defp save_draft(conn, newsletter, params) do
    case Newsletters.update_newsletter(newsletter, params) do
      {:ok, newsletter} ->
        conn
        |> put_flash(:info, gettext("Draft saved."))
        |> redirect(to: ~p"/admin/newsletters/#{newsletter}")

      {:error, changeset} ->
        render(conn, "edit.html",
          page_title: gettext("Edit newsletter"),
          newsletter: newsletter,
          changeset: changeset
        )
    end
  end

  def delete(conn, %{"id" => id}) do
    with_newsletter(conn, id, fn newsletter ->
      {:ok, _} = Newsletters.delete_newsletter(newsletter)

      conn
      |> put_flash(:info, gettext("Newsletter deleted."))
      |> redirect(to: ~p"/admin/newsletters")
    end)
  end

  def test(conn, %{"id" => id} = params) do
    with_newsletter(conn, id, fn newsletter ->
      email = params["email"] || ""

      case Newsletters.deliver_test(newsletter, email, conn.assigns.current_user) do
        {:ok, _delivery} ->
          conn
          |> put_flash(:info, gettext("Test email sent to %{email}.", email: email))
          |> redirect(to: ~p"/admin/newsletters/#{newsletter}")

        {:error, :invalid_email} ->
          conn
          |> put_flash(:error, gettext("Please enter a valid email address."))
          |> redirect(to: ~p"/admin/newsletters/#{newsletter}")
      end
    end)
  end

  defp with_newsletter(conn, id, fun) do
    case Newsletters.get_newsletter(id) do
      nil -> ControllerHelpers.render_error(conn, 404)
      newsletter -> fun.(newsletter)
    end
  end

  defp already_sent(conn, newsletter) do
    conn
    |> put_flash(:error, gettext("A sent newsletter can no longer be edited."))
    |> redirect(to: ~p"/admin/newsletters/#{newsletter}")
  end
end
