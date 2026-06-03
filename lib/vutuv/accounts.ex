defmodule Vutuv.Accounts do
  @moduledoc """
  The Accounts context. Handles user registration, authentication,
  email management, and slugs.
  """

  import Ecto.Query
  require Logger

  alias Plug.Conn
  alias Vutuv.Accounts.MagicLink
  alias Vutuv.Accounts.SearchTerm
  alias Vutuv.Accounts.Slug
  alias Vutuv.Accounts.User
  alias Vutuv.Notifications.Emailer
  alias Vutuv.Repo

  # ── Registration ──

  def register_user(conn, user_params, assocs \\ []) do
    user_params
    |> slug_changeset()
    |> user_changeset(conn, user_params, assocs)
    |> Repo.insert()
    |> case do
      {:ok, user} ->
        user = Repo.preload(user, user_tags: [:tag])
        maybe_fetch_gravatar(user)
        {:ok, user}

      error ->
        error
    end
  end

  defp slug_changeset(user_params) do
    if user_params["first_name"] != nil or user_params["last_name"] != nil do
      struct = %User{first_name: user_params["first_name"], last_name: user_params["last_name"]}
      slug_value = Vutuv.SlugHelpers.gen_slug_unique(struct, Slug, :value)
      Slug.changeset(%Slug{}, %{value: slug_value})
    else
      Slug.changeset(%Slug{}, %{value: "invalid"})
      |> Ecto.Changeset.add_error(:value, "Invalid slug")
    end
  end

  defp user_changeset(slug_changeset, conn, user_params, assocs) do
    search_terms = SearchTerm.create_search_terms(user_params)

    changeset =
      User.changeset(%User{}, user_params)
      |> Ecto.Changeset.put_assoc(:slugs, [slug_changeset])
      |> Ecto.Changeset.put_assoc(:search_terms, search_terms)
      |> Ecto.Changeset.put_change(:active_slug, slug_changeset.changes[:value])
      |> Ecto.Changeset.put_change(:locale, conn.assigns[:locale])

    Enum.reduce([changeset | assocs], fn {type, params}, changeset ->
      Ecto.Changeset.put_assoc(changeset, type, [params])
    end)
  end

  # Best-effort gravatar import: spawned (when enabled) under the app-wide
  # Task.Supervisor rather than an orphaned `Task.start/3`, and disabled in
  # tests via `:fetch_gravatar` so the SQL Sandbox connection is never used by
  # a process that does not own it and no live HTTP request is made.
  defp maybe_fetch_gravatar(user) do
    if Application.get_env(:vutuv, :fetch_gravatar, true) do
      Task.Supervisor.start_child(Vutuv.TaskSupervisor, fn -> store_gravatar(user) end)
    end

    :ok
  end

  defp store_gravatar(user) do
    url = "https://www.gravatar.com/avatar/#{hd(user.emails).md5sum}?s=130&d=404"

    case Req.get(url, receive_timeout: 1000, connect_options: [timeout: 1000]) do
      {:ok, %Req.Response{status: 404}} ->
        nil

      {:ok, %Req.Response{status: 200, body: body, headers: headers}} ->
        content_type = find_content_type(headers)
        filename = "/#{user.active_slug}.#{String.replace(content_type, "image/", "")}"
        path = System.tmp_dir()

        upload = %Plug.Upload{
          content_type: content_type,
          filename: filename,
          path: path <> filename
        }

        File.write(path <> filename, body)

        user
        |> Repo.preload([:slugs, :oauth_providers, :emails])
        |> User.changeset(%{avatar: upload})
        |> Repo.update()

      _ ->
        nil
    end
  rescue
    error ->
      Logger.warning("gravatar import failed for user ##{user.id}: #{inspect(error)}")
      nil
  end

  defp find_content_type(headers) do
    case Map.get(headers, "content-type") do
      [value | _] -> value
      _ -> "image/jpeg"
    end
  end

  # ── Authentication ──

  def login(conn, user) do
    user = validate_user(user)

    conn
    |> Conn.assign(:current_user, user)
    |> Conn.put_session(:user_id, user.id)
    |> Conn.configure_session(renew: true)
  end

  def login_by_email(conn, email) do
    email = String.downcase(email)

    User
    |> join(:inner, [u], e in assoc(u, :emails))
    |> where([u, e], e.value == ^email)
    |> Repo.one()
    |> send_login_email(logout(conn), email)
  end

  defp send_login_email(nil, conn, _), do: {:error, :not_found, conn}

  defp send_login_email(user, conn, email) do
    case Conn.get_req_header(conn, "x-iorg-fbs") do
      ["true"] ->
        gen_magic_link(user, "login")
        |> Emailer.fbs_login_email(email, user)
        |> deliver_login_email(email)

        {:ok, put_pin_cookie(conn, email)}

      _ ->
        gen_magic_link(user, "login")
        |> Emailer.login_email(email, user)
        |> deliver_login_email(email)

        {:ok, conn}
    end
  end

  # Deliver a login email and never let a delivery failure pass silently:
  # the user is shown "check your email", so a dropped mail must at least be
  # logged (the magic link is already persisted, so we do not roll back).
  defp deliver_login_email(mail, address) do
    case Emailer.deliver(mail) do
      {:ok, _} = ok ->
        ok

      {:error, reason} = error ->
        Logger.error("Failed to deliver login email to #{address}: #{inspect(reason)}")
        error
    end
  end

  def logout(conn) do
    conn
    |> Conn.configure_session(drop: true)
    |> Conn.delete_session(:user_id)
  end

  defp validate_user(user) do
    user
    |> Ecto.Changeset.cast(%{validated?: true}, [:validated?])
    |> Repo.update!()
  end

  defp put_pin_cookie(conn, email) do
    salt = Application.fetch_env!(:vutuv, VutuvWeb.Endpoint)[:secret_key_base]
    payload = Phoenix.Token.sign(conn, salt, email)

    conn
    |> Conn.delete_resp_cookie("_vutuv_fbs_temp", max_age: 1800)
    |> Conn.put_resp_cookie("_vutuv_fbs_temp", payload, max_age: 1800)
  end

  # ── Magic Links ──

  @magic_link_expire_time 3600
  @pin_expire_time 1800
  @max_attempts 3

  def gen_magic_link(user, type, value \\ nil) do
    hash = gen_hash(user.id)
    pin = gen_pin()

    case Repo.one(
           from(m in MagicLink, where: m.user_id == ^user.id and m.magic_link_type == ^type)
         ) do
      nil -> Ecto.build_assoc(user, :magic_links)
      magic_link -> magic_link
    end
    |> MagicLink.changeset(%{
      magic_link: hash,
      magic_link_type: type,
      value: value,
      magic_link_created_at: NaiveDateTime.from_erl!(:calendar.universal_time()),
      pin: pin,
      pin_login_attempts: 0
    })
    |> Repo.insert_or_update!()

    {hash, pin}
  end

  defp gen_hash(user_id) do
    seconds_string =
      :calendar.universal_time()
      |> :calendar.datetime_to_gregorian_seconds()
      |> Integer.to_string()

    rand_string =
      :rand.uniform()
      |> Float.to_string()

    id_string =
      user_id
      |> Integer.to_string()

    :crypto.hash(:sha256, "#{seconds_string}#{rand_string}#{id_string}")
    |> Base.encode16()
    |> String.downcase()
  end

  defp gen_pin do
    :rand.uniform(1_000_000)
    |> Integer.to_string()
    |> String.pad_leading(6, "0")
  end

  defp expire_magic_link(magic_link) do
    changeset = MagicLink.changeset(magic_link, %{magic_link_created_at: nil})
    Repo.update!(changeset)
  end

  defp link_expired?(record), do: expired?(record, @magic_link_expire_time)

  defp pin_expired?(record), do: expired?(record, @pin_expire_time)

  defp expired?(%{magic_link_created_at: nil}, _threshold), do: true

  defp expired?(%{magic_link_created_at: date_time}, threshold) do
    time_created =
      date_time
      |> NaiveDateTime.to_erl()
      |> :calendar.datetime_to_gregorian_seconds()

    now =
      :calendar.universal_time()
      |> :calendar.datetime_to_gregorian_seconds()

    now - time_created > threshold
  end

  defp expired?(_, _threshold), do: true

  def check_magic_link(link, type) do
    case Repo.one(
           from(m in MagicLink, where: m.magic_link == ^link and m.magic_link_type == ^type)
         ) do
      nil ->
        {:error, Gettext.gettext(VutuvWeb.Gettext, "An error occured")}

      magic_link ->
        case link_expired?(magic_link) do
          true ->
            expire_magic_link(magic_link)
            {:error, Gettext.gettext(VutuvWeb.Gettext, "Link expired")}

          false ->
            expire_magic_link(magic_link)
            magic_link_response(magic_link)
        end
    end
  end

  def check_pin(email, pin, type) do
    case Repo.one(
           from(m in MagicLink,
             left_join: u in assoc(m, :user),
             left_join: e in assoc(u, :emails),
             where: e.value == ^email and m.magic_link_type == ^type
           )
         ) do
      nil ->
        {:error, Gettext.gettext(VutuvWeb.Gettext, "An error occured")}

      magic_link ->
        cond do
          pin_expired?(magic_link) ->
            expire_magic_link(magic_link)
            {:expired, Gettext.gettext(VutuvWeb.Gettext, "Link expired")}

          magic_link.pin != pin ->
            remove_attempt(magic_link)

          magic_link.pin == pin ->
            expire_magic_link(magic_link)
            magic_link_response(magic_link)
        end
    end
  end

  defp remove_attempt(magic_link) do
    attempts = magic_link.pin_login_attempts + 1

    if attempts >= @max_attempts do
      expire_magic_link(magic_link)
      :lockout
    else
      changeset = MagicLink.changeset(magic_link, %{pin_login_attempts: attempts})
      Repo.update!(changeset)
      {:error, "Incorrect Pin"}
    end
  end

  defp magic_link_response(%MagicLink{value: nil, user_id: user_id}) do
    {:ok, Repo.get(User, user_id)}
  end

  defp magic_link_response(%MagicLink{value: value, user_id: user_id}) do
    {:ok, value, Repo.get(User, user_id)}
  end

  # ── User CRUD ──

  def get_user!(id), do: Repo.get!(User, id)

  def count_users do
    Repo.one(from(u in User, select: count(u.id)))
  end

  def update_user(%User{} = user, attrs) do
    user
    |> User.changeset(attrs)
    |> Repo.update()
  end

  # ── Emails ──
end
