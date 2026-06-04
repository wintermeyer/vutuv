defmodule VutuvWeb.UserController do
  use VutuvWeb, :controller
  plug(VutuvWeb.Plug.UserResolveSlug when action in [:edit, :update, :show, :tags_create])
  plug(VutuvWeb.Plug.RequireLogin when action in [:delete, :confirm_delete])
  plug(:auth when action in [:edit, :update, :tags_create])
  plug(VutuvWeb.Plug.RequireUserLoggedOut when action in [:new, :create])
  plug(VutuvWeb.Plug.EnsureValidated when action not in [:delete, :confirm_delete])
  import VutuvWeb.UserHelpers

  import Ecto.Query

  alias Vutuv.Accounts.Email
  alias Vutuv.Accounts.Locale
  alias Vutuv.Accounts.SearchTerm
  alias Vutuv.Accounts.Slug
  alias Vutuv.Accounts.User
  alias Vutuv.Notifications.Emailer
  alias Vutuv.Profiles.WorkExperience
  alias Vutuv.Recruiting.Coupon
  alias Vutuv.Recruiting.RecruiterSubscription
  alias Vutuv.Social.Connection
  alias Vutuv.Tags.Tag
  alias Vutuv.Tags.UserTag
  alias VutuvWeb.RateLimit

  plug(:scrub_params, "user" when action in [:create, :update])

  def new(conn, _params) do
    changeset =
      User.changeset(%User{})
      |> Ecto.Changeset.put_assoc(:emails, [%Email{}])

    render(conn, "new.html", changeset: changeset, conn: conn)
  end

  def create(conn, %{"user" => user_params}) do
    email = user_params["emails"]["0"]["value"]

    case Vutuv.Accounts.register_user(conn, user_params) do
      {:ok, user} ->
        case Vutuv.Accounts.login_by_email(conn, email) do
          {:ok, conn} ->
            conn
            |> put_flash(
              :info,
              Gettext.gettext(
                VutuvWeb.Gettext,
                "User %{name} created successfully. An email has been sent with your PIN.",
                name: full_name(user)
              )
            )
            |> redirect(to: ~p"/new_registration")

          {:error, _reason, conn} ->
            conn
            |> put_flash(:error, gettext("There was an error"))
            |> redirect(to: ~p"/")
        end

      {:error, changeset} ->
        render(conn, "new.html", changeset: changeset)
    end
  end

  def show(conn, _params) do
    totals = compute_assoc_totals(conn.assigns[:user])
    user = preload_user_for_show(conn.assigns[:user], totals)
    # Resolve the header's current job once (DB-backed, over all the user's
    # work experiences) and reuse it for the title/organization/work-line
    # assigns, so the template no longer runs the current_job/1 chain twice
    # (finding [49]).
    header_job = current_job(user)
    emails = VutuvWeb.UserHelpers.emails_for_display(user, conn.assigns[:current_user])
    reccomended_users = recommended_users(user)

    conn
    |> assign(:emails, emails)
    |> assign(:user_tags, user.user_tags)
    |> assign(:work_experience, user.work_experiences)
    |> assign(:follower_count, follower_count(user))
    |> assign(:followee_count, followee_count(user))
    |> assign(:user, user)
    |> assign(:job, header_job)
    |> assign(:organization, current_organization(header_job))
    |> assign(:title, current_title(header_job))
    |> assign(:work_info, work_information_string_for_job(header_job, 60))
    |> assign(:total_jobs, totals.jobs)
    |> assign(:total_numbers, totals.numbers)
    |> assign(:total_links, totals.links)
    |> assign(:total_addresses, totals.addresses)
    |> assign(:total_user_tags, totals.user_tags)
    |> assign(:display_welcome_message, new_user?(user))
    |> assign(:active_subscription, active_subscription_for(conn.assigns[:current_user]))
    |> assign(:recruiter_packages, recruiter_packages_for(conn.assigns[:locale]))
    |> assign(:reccomended_users, reccomended_users)
    |> assign(
      :reccomended_work_info,
      VutuvWeb.UserHelpers.work_information_map(reccomended_users, 24)
    )
    |> assign(
      :reccomended_following,
      VutuvWeb.UserHelpers.following_map(conn.assigns[:current_user], reccomended_users)
    )
    |> assign(:work_string_length, 35)
    |> assign(:new_coupon, build_coupon(user))
    |> render("show.html", conn: conn)
  end

  defp compute_assoc_totals(user) do
    %{
      jobs: count_user_assoc(Vutuv.Profiles.WorkExperience, user),
      numbers: count_user_assoc(Vutuv.Profiles.PhoneNumber, user),
      links: count_user_assoc(Vutuv.Profiles.Url, user),
      addresses: count_user_assoc(Vutuv.Profiles.Address, user),
      user_tags: count_user_assoc(Vutuv.Tags.UserTag, user)
    }
  end

  defp preload_user_for_show(user, totals) do
    job_limit = min(totals.jobs, 3)
    number_limit = min(totals.numbers, 3)
    link_limit = min(totals.links, 3)
    address_limit = min(totals.addresses, 3)
    user_tag_limit = min(totals.user_tags, 10)

    user
    |> Repo.preload([
      :social_media_accounts,
      :followees,
      :followers,
      :coupons,
      user_tags:
        from(u in Vutuv.Tags.UserTag,
          left_join: e in assoc(u, :endorsements),
          left_join: t in assoc(u, :tag),
          order_by: t.slug,
          # Postgres requires every ordered, non-aggregated column in GROUP BY;
          # each user_tag has exactly one tag, so this keeps one row per user_tag.
          group_by: [u.id, t.slug],
          limit: ^user_tag_limit,
          preload: [:endorsements, :tag]
        ),
      followee_connections: {Connection.latest(3), [:followee]},
      follower_connections: {Connection.latest(3), [:follower]},
      phone_numbers:
        from(u in Vutuv.Profiles.PhoneNumber,
          order_by: [desc: u.updated_at],
          limit: ^number_limit
        ),
      urls: from(u in Vutuv.Profiles.Url, order_by: [desc: u.updated_at], limit: ^link_limit),
      addresses:
        from(u in Vutuv.Profiles.Address, order_by: [desc: u.updated_at], limit: ^address_limit),
      work_experiences:
        from(u in Vutuv.Profiles.WorkExperience, limit: ^job_limit)
        |> WorkExperience.order_by_date()
    ])
  end

  defp new_user?(user) do
    inserted_at = :calendar.datetime_to_gregorian_seconds(NaiveDateTime.to_erl(user.inserted_at))
    now = :calendar.datetime_to_gregorian_seconds(:calendar.universal_time())
    now - inserted_at <= 600
  end

  defp active_subscription_for(nil), do: nil

  defp active_subscription_for(current_user) do
    RecruiterSubscription.active_subscription(current_user.id)
  end

  defp recruiter_packages_for(locale) do
    Repo.all(
      from(r in Vutuv.Recruiting.RecruiterPackage,
        where: r.locale_id == ^Locale.locale_id(locale),
        select: {r.name, r.id}
      )
    )
  end

  defp recommended_users(user) do
    default = default_recommended_users()

    case first_user_tag(user) do
      nil ->
        default

      user_tag ->
        tag_users = Tag.reccomended_users(Repo.get(Tag, user_tag.tag_id))
        if tag_users == [user], do: default, else: tag_users
    end
  end

  defp default_recommended_users do
    Repo.all(
      from(u in User,
        left_join: f in assoc(u, :followers),
        group_by: u.id,
        order_by: [fragment("count(?) DESC", f.id), u.first_name, u.last_name],
        limit: 6
      )
    )
  end

  defp first_user_tag(user) do
    Repo.one(
      from(w in assoc(user, :user_tags),
        join: t in assoc(w, :tag),
        order_by: w.inserted_at,
        limit: 1
      )
    )
  end

  defp build_coupon(user) do
    ends_on = Date.utc_today() |> Date.add(7)

    Coupon.changeset(%Coupon{
      code: Coupon.random_code(),
      user_id: user.id,
      percentage: 20,
      ends_on: ends_on
    })
  end

  def count_user_assoc(schema, user) do
    Repo.one(from(a in schema, where: a.user_id == ^user.id, select: count("*")))
  end

  def edit(conn, _params) do
    user =
      conn.assigns[:user]
      |> Repo.preload([:emails, :slugs, :oauth_providers])

    changeset = User.changeset(user)

    render(conn, "edit.html", user: user, changeset: changeset)
  end

  def update(conn, %{"user" => user_params}) do
    user = conn.assigns[:user]

    user
    |> Repo.preload([:emails, :slugs, :oauth_providers, :search_terms])
    |> User.changeset(user_params)
    |> update_search_terms(user_params)
    |> Repo.update()
    |> case do
      {:ok, user} ->
        conn
        |> put_flash(:info, gettext("User updated successfully."))
        |> redirect(to: ~p"/users/#{user}")

      {:error, changeset} ->
        render(conn, "edit.html", user: user, changeset: changeset)
    end
  end

  def update_search_terms(changeset, params) do
    first_name = Ecto.Changeset.get_change(changeset, :first_name)
    last_name = Ecto.Changeset.get_change(changeset, :last_name)
    # if first or last name is changed, update search terms
    if first_name || last_name do
      Ecto.Changeset.put_assoc(
        changeset,
        :search_terms,
        SearchTerm.create_search_terms(params)
      )
    else
      changeset
    end
  end

  def insert_slug(conn, %{"id" => id, "params" => params}) do
    user = Repo.get!(User, id)
    slug_changeset = Slug.changeset(%Slug{user_id: id}, params)

    case Repo.insert(slug_changeset) do
      {:ok, _slug} ->
        conn
        |> put_flash(:info, gettext("Slug updated successfully."))
        |> redirect(to: ~p"/users/#{user}")

      {:error, _changeset} ->
        changeset = User.changeset(user)

        render(conn, "edit.html",
          user: user,
          changeset: changeset,
          slug_changeset: slug_changeset
        )
    end
  end

  # Step 1: mail a PIN and render the PIN-entry form. Nothing is deleted yet.
  def delete(conn, _params) do
    user = conn.assigns[:current_user]

    case RateLimit.check(conn, :account_deletion, email(user)) do
      :ok ->
        user
        |> Vutuv.Accounts.gen_pin_for("delete")
        |> Emailer.user_deletion_email(email(user), user)
        |> Emailer.deliver()

        render(conn, "delete_confirmation.html", body_class: "stretch")

      :rate_limited ->
        conn
        |> put_flash(:error, gettext("Too many attempts. Please try again later."))
        |> redirect(to: ~p"/users/#{user}")
    end
  end

  # Step 2: the PIN confirms the deletion, which is then irreversible.
  def confirm_delete(conn, %{"account_deletion" => %{"pin" => pin}}) do
    user = conn.assigns[:current_user]

    case RateLimit.check(conn, :account_deletion_pin, email(user)) do
      :ok ->
        verify_deletion_pin(conn, user, pin)

      :rate_limited ->
        conn
        |> put_flash(:error, gettext("Too many attempts. Please try again later."))
        |> redirect(to: ~p"/users/#{user}")
    end
  end

  defp verify_deletion_pin(conn, user, pin) do
    case Vutuv.Accounts.check_pin(user, pin, "delete") do
      {:ok, user} ->
        # Here we use delete! (with a bang) because we expect
        # it to always work (and if it does not, it will raise).
        Repo.delete!(user)

        conn
        |> Vutuv.Accounts.logout()
        |> put_flash(:info, gettext("User deleted successfully."))
        |> redirect(to: ~p"/")

      {:error, reason} ->
        conn
        |> put_flash(:error, reason)
        |> render("delete_confirmation.html", body_class: "stretch")

      {:expired, message} ->
        conn
        |> put_flash(:error, message)
        |> redirect(to: ~p"/users/#{user}")

      :lockout ->
        conn
        |> put_flash(:error, gettext("Too many incorrect attempts."))
        |> redirect(to: ~p"/users/#{user}")
    end
  end

  def tags_create(conn, %{"tags" => %{"tags" => tags}}) do
    user =
      conn.assigns[:user]
      |> Repo.preload(user_tags: [:tag])

    tag_list =
      tags
      |> String.split(",")

    results =
      for(tag <- tag_list) do
        capitalized_tag =
          tag
          |> String.trim()

        user
        |> Ecto.build_assoc(:user_tags, %{})
        |> UserTag.changeset()
        |> Tag.create_or_link_tag(%{"value" => capitalized_tag})
        |> Repo.insert()
      end

    failures =
      Enum.reduce(results, 0, fn {result, _}, acc ->
        case result do
          :error -> acc + 1
          :ok -> acc
        end
      end)

    conn
    |> put_flash(
      :info,
      Gettext.gettext(
        VutuvWeb.Gettext,
        "Successfully added %{successes} tags with %{failures} failures.",
        successes: Enum.count(tag_list) - failures,
        failures: failures
      )
    )
    |> redirect(to: ~p"/users/#{user}")
  end

  def follow_back(conn, %{"id" => id}) do
    user = Repo.get!(User, id)

    # Through the Social.follow/2 chokepoint so the followee also gets the live
    # "started following you" notification (this path skipped it before).
    case Vutuv.Social.follow(conn.assigns.current_user, user.id) do
      {:ok, _connection} ->
        conn
        |> put_flash(
          :info,
          Gettext.gettext(VutuvWeb.Gettext, "You follow back %{name}.", name: full_name(user))
        )
        |> redirect(to: ~p"/users/#{conn.assigns.current_user}")

      {:error, _changeset} ->
        conn
        |> put_flash(
          :error,
          Gettext.gettext(VutuvWeb.Gettext, "Couldn't follow back to %{name}.",
            name: full_name(user)
          )
        )
        |> redirect(to: ~p"/users/#{conn.assigns.current_user}")
    end
  end

  defp auth(conn, _opts) do
    with %{"slug" => slug} <- conn.params,
         user_id when not is_nil(user_id) <-
           Repo.one(from(s in Slug, where: s.value == ^slug, select: s.user_id)) do
      if user_id == conn.assigns[:current_user_id] do
        conn
      else
        conn
        |> put_status(403)
        |> put_view(html: VutuvWeb.ErrorHTML)
        |> render("403.html")
        |> halt
      end
    else
      _ -> not_found(conn)
    end
  end

  def not_found(conn) do
    conn
    |> put_status(:not_found)
    |> put_view(html: VutuvWeb.ErrorHTML)
    |> render("404.html")
    |> halt
  end
end
