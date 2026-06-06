defmodule VutuvWeb.UserController do
  use VutuvWeb, :controller
  plug(VutuvWeb.Plug.UserResolveSlug when action in [:edit, :update, :show, :tags_create])
  plug(VutuvWeb.Plug.RequireLogin when action in [:delete, :confirm_delete])
  plug(VutuvWeb.Plug.AuthUser when action in [:edit, :update, :tags_create])
  plug(VutuvWeb.Plug.EnsureValidated when action not in [:delete, :confirm_delete])
  import VutuvWeb.UserHelpers

  import Ecto.Query

  alias Vutuv.Accounts
  alias Vutuv.Accounts.SearchTerm
  alias Vutuv.Accounts.User
  alias Vutuv.Notifications.Emailer
  alias Vutuv.Profiles.WorkExperience
  alias Vutuv.Social.Connection
  alias Vutuv.Tags.Tag
  alias Vutuv.Tags.UserTag
  alias VutuvWeb.RateLimit

  plug(:scrub_params, "user" when action in [:update])

  def show(conn, _params) do
    # The totals drive the "View all" links for the sections whose preloads
    # below are cut off after a few entries.
    totals = assoc_totals(conn.assigns[:user])
    user = preload_user_for_show(conn.assigns[:user])
    # Resolve the header's current job once (DB-backed, over all the user's
    # work experiences) and derive the work line from it, so the template
    # does not run the current_job/1 query chain itself.
    header_job = current_job(user)
    emails = VutuvWeb.UserHelpers.emails_for_display(user, conn.assigns[:current_user])
    recommended_users = recommended_users(user)
    followers = Enum.map(user.follower_connections, & &1.follower)
    followees = Enum.map(user.followee_connections, & &1.followee)
    # One work-info and one follow-state query for all the small user lists on
    # the page (the "Who to follow" rail plus both follow previews).
    preview_users = Enum.uniq_by(recommended_users ++ followers ++ followees, & &1.id)

    conn
    |> assign(:emails, emails)
    |> assign(:posts, Vutuv.Posts.profile_posts(user, conn.assigns[:current_user]))
    |> assign(:user_tags, user.user_tags)
    |> assign(:work_experience, user.work_experiences)
    |> assign(:follower_count, Vutuv.Social.follower_count(user))
    |> assign(:followee_count, Vutuv.Social.followee_count(user))
    |> assign(:user, user)
    |> assign(:work_info, work_information_string_for_job(header_job, 60))
    |> assign(:display_welcome_message, new_user?(user))
    |> assign(:recommended_users, recommended_users)
    |> assign(:followers, followers)
    |> assign(:followees, followees)
    |> assign(:totals, totals)
    |> assign(
      :work_info_by_id,
      VutuvWeb.UserHelpers.work_information_map(preview_users, 24)
    )
    |> assign(
      :following_by_id,
      VutuvWeb.UserHelpers.following_map(conn.assigns[:current_user], preview_users)
    )
    |> render("show.html", conn: conn)
  end

  # Only what show.html.heex (and the root layout's meta description) actually
  # renders: the first 10 tags, the latest 3 of each list-like association,
  # all social media accounts (there can be at most one per provider).
  defp preload_user_for_show(user) do
    user
    |> Repo.preload([
      :social_media_accounts,
      user_tags:
        from(u in Vutuv.Tags.UserTag,
          left_join: e in assoc(u, :endorsements),
          left_join: t in assoc(u, :tag),
          order_by: t.slug,
          # Postgres requires every ordered, non-aggregated column in GROUP BY;
          # each user_tag has exactly one tag, so this keeps one row per user_tag.
          group_by: [u.id, t.slug],
          limit: 10,
          preload: [:endorsements, :tag]
        ),
      work_experiences:
        from(u in Vutuv.Profiles.WorkExperience, limit: 3)
        |> WorkExperience.order_by_date(),
      phone_numbers:
        from(p in Vutuv.Profiles.PhoneNumber, order_by: [desc: p.updated_at], limit: 3),
      urls: from(u in Vutuv.Profiles.Url, order_by: [desc: u.updated_at], limit: 3),
      addresses: from(a in Vutuv.Profiles.Address, order_by: [desc: a.updated_at], limit: 3),
      follower_connections: {Connection.latest(3), [:follower]},
      followee_connections: {Connection.latest(3), [:followee]}
    ])
  end

  defp assoc_totals(user) do
    %{
      user_tags: count_assoc(user, :user_tags),
      jobs: count_assoc(user, :work_experiences),
      numbers: count_assoc(user, :phone_numbers),
      links: count_assoc(user, :urls),
      addresses: count_assoc(user, :addresses)
    }
  end

  defp count_assoc(user, assoc), do: Repo.aggregate(Ecto.assoc(user, assoc), :count)

  defp new_user?(user) do
    inserted_at = :calendar.datetime_to_gregorian_seconds(NaiveDateTime.to_erl(user.inserted_at))
    now = :calendar.datetime_to_gregorian_seconds(:calendar.universal_time())
    now - inserted_at <= 600
  end

  defp recommended_users(user) do
    case first_tag(user) do
      nil ->
        Vutuv.Social.most_followed_users(6)

      tag ->
        tag_users = Tag.recommended_users(tag)
        if tag_users == [user], do: Vutuv.Social.most_followed_users(6), else: tag_users
    end
  end

  defp first_tag(user) do
    Repo.one(
      from(w in assoc(user, :user_tags),
        join: t in assoc(w, :tag),
        order_by: w.inserted_at,
        limit: 1,
        select: t
      )
    )
  end

  def edit(conn, _params) do
    user =
      conn.assigns[:user]
      |> Repo.preload([:slugs, :oauth_providers])

    changeset = User.changeset(user)

    render(conn, "edit.html", user: user, changeset: changeset)
  end

  def update(conn, %{"user" => user_params}) do
    user = conn.assigns[:user]

    user
    |> Repo.preload([:slugs, :oauth_providers, :search_terms])
    |> User.changeset(user_params)
    |> update_search_terms(user_params)
    |> Repo.update()
    |> case do
      {:ok, user} ->
        conn
        |> put_flash(:info, gettext("User updated successfully."))
        |> redirect(to: ~p"/#{user}")

      {:error, changeset} ->
        render(conn, "edit.html", user: user, changeset: changeset)
    end
  end

  defp update_search_terms(changeset, params) do
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

  # Step 1: mail a PIN and render the PIN-entry form. Nothing is deleted yet.
  def delete(conn, _params) do
    user = conn.assigns[:current_user]
    email = Accounts.first_email_value(user)

    case RateLimit.check(conn, :account_deletion, email) do
      :ok ->
        user
        |> Vutuv.Accounts.gen_pin_for("delete")
        |> Emailer.user_deletion_email(email, user)
        |> Emailer.deliver()

        render(conn, "delete_confirmation.html", body_class: "stretch")

      :rate_limited ->
        conn
        |> put_flash(:error, gettext("Too many attempts. Please try again later."))
        |> redirect(to: ~p"/#{user}")
    end
  end

  # Step 2: the PIN confirms the deletion, which is then irreversible.
  def confirm_delete(conn, %{"account_deletion" => %{"pin" => pin}}) do
    user = conn.assigns[:current_user]

    case RateLimit.check(conn, :account_deletion_pin, Accounts.first_email_value(user)) do
      :ok ->
        verify_deletion_pin(conn, user, pin)

      :rate_limited ->
        conn
        |> put_flash(:error, gettext("Too many attempts. Please try again later."))
        |> redirect(to: ~p"/#{user}")
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
        |> redirect(to: ~p"/#{user}")

      :lockout ->
        conn
        |> put_flash(:error, gettext("Too many incorrect attempts."))
        |> redirect(to: ~p"/#{user}")
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
    |> redirect(to: ~p"/#{user}")
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
        |> redirect(to: ~p"/#{conn.assigns.current_user}")

      {:error, _changeset} ->
        conn
        |> put_flash(
          :error,
          Gettext.gettext(VutuvWeb.Gettext, "Couldn't follow back to %{name}.",
            name: full_name(user)
          )
        )
        |> redirect(to: ~p"/#{conn.assigns.current_user}")
    end
  end
end
