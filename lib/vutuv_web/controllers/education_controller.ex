defmodule VutuvWeb.EducationController do
  use VutuvWeb, :controller

  import Ecto.Query

  alias Vutuv.Accounts
  alias Vutuv.Profiles.CvUpdates
  alias Vutuv.Profiles.Education
  alias Vutuv.Social
  alias VutuvWeb.AgentDocs
  alias VutuvWeb.AgentDocs.SectionDocs
  alias VutuvWeb.ControllerHelpers

  plug(VutuvWeb.Plug.AuthUser when action not in [:index, :show])
  plug(:scrub_params, "education" when action in [:create, :update])

  plug(VutuvWeb.Plug.ResolveOwnedSlug,
    parent: :user,
    assoc: :educations,
    slug_param: "id",
    field: :slug,
    assign: :education,
    # imported entries can carry a NULL slug; their Phoenix.Param is the id
    id_fallback: true
  )

  # Index and show are also served as Markdown / text / JSON / XML via
  # VutuvWeb.AgentDocs.SectionDocs (keep the templates and the doc builder in
  # sync, see agent_docs_drift_test.exs).
  def index(conn, _params) do
    user = user_with_educations(conn)

    AgentDocs.respond(conn,
      html: fn conn ->
        render(conn, "index.html",
          as_owner?: false,
          user: user,
          education: user.educations,
          # The pinned profile headline (issue #882), so the shared card_list
          # never crashes on a missing assign — the chooser itself stays gated
          # on as_owner? and never renders here.
          profile_education_id: user.profile_education_id,
          page_title: VutuvWeb.UserHelpers.member_page_title(user, gettext("Education"))
        )
      end,
      doc: fn -> SectionDocs.build_index(user, :educations, user.educations) end
    )
  end

  # The owner's editor (GET /settings/educations), including the
  # profile-headline pin chooser (issue #882).
  def manage(conn, _params) do
    user = user_with_educations(conn)

    render(conn, "manage.html",
      user: user,
      education: user.educations,
      profile_education_id: user.profile_education_id,
      as_owner?: true,
      page_title: gettext("Education")
    )
  end

  # Pin one education as the member's profile headline, or clear the pin back to
  # the automatic job resolution (issue #882). Owner-only (AuthUser) and
  # owner-scoped (ResolveOwnedSlug assigns :education from the member's own
  # rows), so a member can only ever pin their own entry. Pinning also clears a
  # pinned work experience — the headline is one slot (Accounts).
  def pin(conn, _params) do
    user = conn.assigns[:user]

    case Accounts.pin_profile_education(user, conn.assigns[:education]) do
      {:ok, _user} ->
        conn
        |> put_flash(:info, gettext("This education now shows at the top of your profile."))
        |> redirect(to: ~p"/settings/educations")

      {:error, _} ->
        conn
        |> put_flash(:error, gettext("That education could not be pinned."))
        |> redirect(to: ~p"/settings/educations")
    end
  end

  def unpin(conn, _params) do
    user = conn.assigns[:user]
    {:ok, _user} = Accounts.unpin_profile_education(user)

    conn
    |> put_flash(:info, gettext("The top of your profile is chosen automatically again."))
    |> redirect(to: ~p"/settings/educations")
  end

  def new(conn, _params) do
    # The "tell my followers" box starts ticked (issue #980) — see
    # WorkExperienceController.new/2 for why. The data default stays false.
    changeset = Education.changeset(%Education{announce_to_followers?: true})

    render(conn, "new.html",
      changeset: changeset,
      current_year: current_year(),
      followers: Social.follower_count(conn.assigns[:user])
    )
  end

  def create(conn, %{"education" => education_params}) do
    user = conn.assigns[:user]

    changeset =
      user
      |> build_assoc(:educations)
      |> Education.changeset(education_params)

    result = Repo.insert(changeset)
    with {:ok, education} <- result, do: CvUpdates.announce(user, education)

    ControllerHelpers.save(conn, result,
      flash: gettext("Education created successfully."),
      redirect_to: ~p"/settings/educations",
      render: "new.html",
      assigns: [current_year: current_year(), followers: Social.follower_count(user)]
    )
  end

  def show(conn, _params) do
    # ResolveOwnedSlug scopes :education to conn.assigns[:user], so no re-check.
    AgentDocs.respond(conn,
      html:
        &render(&1, "show.html",
          education: conn.assigns[:education],
          page_title: entry_page_title(conn.assigns[:user], conn.assigns[:education])
        ),
      doc: fn ->
        SectionDocs.build_show(conn.assigns[:user], :educations, conn.assigns[:education])
      end
    )
  end

  defp entry_page_title(user, education) do
    label = if education.school in [nil, ""], do: gettext("Education"), else: education.school
    VutuvWeb.UserHelpers.member_page_title(user, label)
  end

  def edit(conn, _params) do
    education = conn.assigns[:education]
    changeset = Education.changeset(education)

    render(conn, "edit.html",
      education: education,
      changeset: changeset,
      current_year: current_year()
    )
  end

  def update(conn, %{"education" => education_params}) do
    education = conn.assigns[:education]
    changeset = Education.changeset(education, education_params)

    ControllerHelpers.save(conn, Repo.update(changeset),
      flash: gettext("Education updated successfully."),
      redirect_to: ~p"/settings/educations",
      render: "edit.html",
      assigns: [education: education, current_year: current_year()]
    )
  end

  defp current_year, do: Vutuv.BerlinTime.today().year

  def delete(conn, _params) do
    ControllerHelpers.delete(conn, conn.assigns[:education],
      flash: gettext("Education deleted successfully."),
      redirect_to: ~p"/settings/educations"
    )
  end

  defp user_with_educations(conn),
    do:
      Repo.preload(conn.assigns[:user],
        educations: from(e in Education) |> Education.order_by_date()
      )
end
