defmodule VutuvWeb.JobPostingLive.Form do
  @moduledoc """
  The job-posting editor (`/jobs/new`, `/jobs/:slug/edit`, issue #932). One form
  drives the whole lifecycle: "Save draft" persists whatever is filled in;
  "Publish" runs the publish-time validations (location for the chosen
  workplace, apply target, salary unless volunteer) and the anti-abuse gate.

  The workplace choice drives the form: on-site / hybrid show the address block,
  remote shows the applicant-countries select. Visibility leads with the human
  audience (everyone / members); the SEO / GEO machine toggles show only for an
  `everyone` posting. A live, non-blocking AGG hint nudges a gender-neutral
  title.
  """

  use VutuvWeb, :live_view

  import VutuvWeb.ErrorHelpers

  alias Vutuv.Countries
  alias Vutuv.Jobs
  alias Vutuv.Jobs.JobPosting
  alias Vutuv.Organizations
  alias Vutuv.Salary

  @impl true
  def mount(params, _session, socket) do
    case require_poster(socket) do
      {:ok, socket} -> {:ok, mount_action(socket, socket.assigns.live_action, params)}
      {:redirect, socket} -> {:ok, socket}
    end
  end

  defp require_poster(socket) do
    case socket.assigns.current_user do
      %{email_confirmed?: true} ->
        {:ok, socket}

      %{} ->
        {:redirect,
         socket
         |> put_flash(:error, gettext("Please confirm your email address before posting a job."))
         |> push_navigate(to: ~p"/jobs/mine")}

      nil ->
        {:redirect,
         socket
         |> put_flash(:error, gettext("Please log in to post a job."))
         |> push_navigate(to: ~p"/login")}
    end
  end

  defp mount_action(socket, :new, _params) do
    posting = %JobPosting{}
    changeset = Jobs.change_job_posting(posting)

    socket
    |> base_assigns(posting, changeset)
    |> assign(:required_tags, "")
    |> assign(:nice_tags, "")
    |> assign(:images, [])
  end

  defp mount_action(socket, :edit, %{"slug" => slug}) do
    posting = Jobs.get_job_posting_by_slug(slug)

    if posting && Jobs.owner?(posting, socket.assigns.current_user) do
      socket
      |> base_assigns(posting, Jobs.change_job_posting(posting))
      |> assign(:required_tags, Jobs.tag_names(posting, :required))
      |> assign(:nice_tags, Jobs.tag_names(posting, :nice_to_have))
      |> assign(:images, posting.images)
    else
      socket
      |> put_flash(:error, gettext("Posting not found."))
      |> push_navigate(to: ~p"/jobs/mine")
    end
  end

  defp base_assigns(socket, posting, changeset) do
    socket
    |> assign(:posting, posting)
    |> assign(
      :page_title,
      if(posting.id, do: gettext("Edit posting"), else: gettext("New posting"))
    )
    |> assign(:organizations, Organizations.postable_organizations(socket.assigns.current_user))
    |> allow_upload(:images,
      accept: Vutuv.JobPostingImageStore.extension_whitelist(),
      max_entries: Jobs.max_images_per_posting(),
      max_file_size: Jobs.max_image_filesize(),
      auto_upload: true,
      progress: &handle_progress/3
    )
    |> assign_form(changeset)
  end

  defp assign_form(socket, changeset) do
    socket
    |> assign(:changeset, changeset)
    |> assign(:form, to_form(changeset, as: :job_posting))
  end

  # --- events ----------------------------------------------------------------

  @impl true
  def handle_event("validate", %{"job_posting" => params}, socket) do
    changeset =
      socket.assigns.posting
      |> Jobs.change_job_posting(params)
      |> Map.put(:action, :validate)

    {:noreply,
     socket
     |> assign_form(changeset)
     |> assign(:required_tags, params["required_tags"] || "")
     |> assign(:nice_tags, params["nice_to_have_tags"] || "")}
  end

  def handle_event("save", %{"do" => action, "job_posting" => params}, socket) do
    attrs = build_attrs(params, socket)
    save(socket, socket.assigns.live_action, action, attrs, params["organization_id"])
  end

  def handle_event("remove-image", %{"id" => id}, socket) do
    images = socket.assigns.images

    case Enum.find(images, &(&1.id == id)) do
      nil ->
        {:noreply, socket}

      image ->
        Jobs.delete_pending_image(image)
        {:noreply, assign(socket, :images, images -- [image])}
    end
  end

  def handle_event("cancel-upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :images, ref)}
  end

  defp handle_progress(:images, entry, socket) do
    if entry.done? do
      image =
        consume_uploaded_entry(socket, entry, fn %{path: path} ->
          {:ok, Jobs.create_pending_image(socket.assigns.current_user, path, entry.client_name)}
        end)

      case image do
        {:ok, image} -> {:noreply, assign(socket, :images, socket.assigns.images ++ [image])}
        _ -> {:noreply, put_flash(socket, :error, gettext("That image could not be uploaded."))}
      end
    else
      {:noreply, socket}
    end
  end

  defp build_attrs(params, socket) do
    Map.merge(params, %{
      "required_tags" => params["required_tags"] || "",
      "nice_to_have_tags" => params["nice_to_have_tags"] || "",
      "image_ids" => Enum.map(socket.assigns.images, & &1.id)
    })
  end

  # --- save paths ------------------------------------------------------------

  defp save(socket, :new, "publish", attrs, org_id) do
    user = socket.assigns.current_user
    org = organization(socket, org_id)

    changeset =
      %JobPosting{user_id: user.id}
      |> JobPosting.publish_changeset(attrs)
      |> Map.put(:action, :validate)

    if changeset.valid? do
      # Gate before creating anything, so a rejected publish never leaves an
      # orphan draft (and a retry can't create a second one).
      gate_then_create(socket, user, org, attrs, changeset)
    else
      {:noreply, assign_form(socket, changeset)}
    end
  end

  defp save(socket, :new, _draft, attrs, org_id) do
    user = socket.assigns.current_user

    case Jobs.create_draft(user, attrs, organization: organization(socket, org_id)) do
      {:ok, draft} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Draft saved."))
         |> push_navigate(to: ~p"/jobs/#{draft.slug}/edit")}

      {:error, changeset} ->
        {:noreply, assign_form(socket, changeset)}
    end
  end

  defp save(socket, :edit, "publish", attrs, org_id) do
    user = socket.assigns.current_user
    org = organization(socket, org_id)

    case Jobs.publish(socket.assigns.posting, user, attrs, organization: org) do
      {:ok, published} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Your posting is live."))
         |> push_navigate(to: ~p"/jobs/#{published.slug}")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign_form(socket, changeset)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, publish_error(reason))}
    end
  end

  defp save(socket, :edit, _draft, attrs, org_id) do
    user = socket.assigns.current_user

    case Jobs.update_posting(socket.assigns.posting, user, attrs,
           organization: organization(socket, org_id)
         ) do
      {:ok, posting} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Saved."))
         |> push_navigate(to: ~p"/jobs/#{posting.slug}/edit")}

      {:error, changeset} ->
        {:noreply, assign_form(socket, changeset)}
    end
  end

  defp gate_then_create(socket, user, org, attrs, changeset) do
    candidate =
      changeset |> Ecto.Changeset.apply_changes() |> Map.put(:organization_id, org && org.id)

    case Jobs.publish_gate(user, candidate) do
      :ok -> create_and_publish(socket, user, org, attrs)
      {:error, reason} -> {:noreply, put_flash(socket, :error, publish_error(reason))}
    end
  end

  defp create_and_publish(socket, user, org, attrs) do
    with {:ok, draft} <- Jobs.create_draft(user, attrs, organization: org),
         {:ok, published} <- Jobs.publish(draft, user, attrs, organization: org) do
      {:noreply,
       socket
       |> put_flash(:info, gettext("Your posting is live."))
       |> push_navigate(to: ~p"/jobs/#{published.slug}")}
    else
      {:error, %Ecto.Changeset{} = cs} ->
        {:noreply, assign_form(socket, cs)}

      _ ->
        {:noreply, put_flash(socket, :error, gettext("Something went wrong. Please try again."))}
    end
  end

  defp organization(_socket, nil), do: nil
  defp organization(_socket, ""), do: nil

  defp organization(socket, org_id) do
    Enum.find(socket.assigns.organizations, &(&1.id == org_id))
  end

  defp publish_error(:email_unconfirmed), do: gettext("Please confirm your e-mail address first.")
  defp publish_error(:account_too_new), do: gettext("New accounts can publish after a few days.")

  defp publish_error(:member_quota),
    do: gettext("You already have the maximum number of published postings.")

  defp publish_error(:organization_quota),
    do: gettext("This organization has reached its published-postings limit.")

  # --- render ----------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <div class="py-6">
      <h1 class="mb-6 text-2xl font-bold text-slate-900 dark:text-slate-100">{@page_title}</h1>

      <.form for={@form} id="job-posting-form" phx-change="validate" phx-submit="save" class="space-y-6">
        <.form_error :if={@changeset.action} changeset={@changeset} />

        <.card class="space-y-5">
          <.section_title>{gettext("The role")}</.section_title>

          <div>
            <label class="mb-1 block text-sm font-medium" for="job_posting_title">
              {gettext("Job title")}
            </label>
            <input
              type="text"
              name="job_posting[title]"
              id="job_posting_title"
              value={@form[:title].value}
              class={input_class(@form, :title)}
              aria-invalid={@form.errors[:title] && "true"}
            />
            {error_tag(@form, :title)}
            <p
              :if={agg_hint?(@form)}
              class="mt-1 text-xs text-amber-700 dark:text-amber-400"
            >
              {gettext("Tip: adding a gender marker like (m/w/d) helps your posting comply with the AGG. This is a suggestion, not legal advice.")}
            </p>
          </div>

          <div :if={@organizations != []}>
            <label class="mb-1 block text-sm font-medium" for="job_posting_organization_id">
              {gettext("Post as")}
            </label>
            <select name="job_posting[organization_id]" id="job_posting_organization_id" class={input_class()}>
              <option value="">{gettext("Yourself (personal posting)")}</option>
              <option :for={org <- @organizations} value={org.id} selected={@posting.organization_id == org.id}>
                {org.name}
              </option>
            </select>
          </div>

          <div :if={current(@changeset, :organization_id) in [nil, ""]}>
            <label class="mb-1 block text-sm font-medium" for="job_posting_hiring_org_name">
              {gettext("Employer name (optional)")}
            </label>
            <input
              type="text"
              name="job_posting[hiring_org_name]"
              id="job_posting_hiring_org_name"
              value={@form[:hiring_org_name].value}
              class={input_class(@form, :hiring_org_name)}
            />
            <p class="editform__hint">{gettext("Shown as an unverified employer name.")}</p>
          </div>

          <div class="grid gap-4 sm:grid-cols-2">
            <div>
              <label class="mb-1 block text-sm font-medium" for="job_posting_employment_type">
                {gettext("Employment type")}
              </label>
              <select name="job_posting[employment_type]" id="job_posting_employment_type" class={input_class()}>
                <option
                  :for={{label, value} <- JobPosting.employment_type_options()}
                  value={value}
                  selected={to_string(current(@changeset, :employment_type)) == to_string(value)}
                >
                  {label}
                </option>
              </select>
            </div>

            <div>
              <label class="mb-1 block text-sm font-medium" for="job_posting_workplace_type">
                {gettext("Workplace")}
              </label>
              <select name="job_posting[workplace_type]" id="job_posting_workplace_type" class={input_class()}>
                <option
                  :for={{label, value} <- JobPosting.workplace_type_options()}
                  value={value}
                  selected={to_string(current(@changeset, :workplace_type)) == to_string(value)}
                >
                  {label}
                </option>
              </select>
            </div>
          </div>

          <div>
            <label class="mb-1 block text-sm font-medium" for="job_posting_language">
              {gettext("Posting language")}
            </label>
            <select name="job_posting[language]" id="job_posting_language" class={input_class()}>
              <option value="de" selected={current(@changeset, :language) == "de"}>Deutsch</option>
              <option value="en" selected={current(@changeset, :language) == "en"}>English</option>
            </select>
          </div>
        </.card>

        <.card class="space-y-5">
          <.section_title>{gettext("Location")}</.section_title>

          <div :if={current(@changeset, :workplace_type) != :remote} class="space-y-4">
            <div>
              <label class="mb-1 block text-sm font-medium" for="job_posting_street_address">
                {gettext("Street (optional)")}
              </label>
              <input type="text" name="job_posting[street_address]" id="job_posting_street_address"
                value={@form[:street_address].value} class={input_class(@form, :street_address)} />
            </div>
            <div class="grid gap-4 sm:grid-cols-3">
              <div>
                <label class="mb-1 block text-sm font-medium" for="job_posting_zip_code">{gettext("Postal code")}</label>
                <input type="text" name="job_posting[zip_code]" id="job_posting_zip_code"
                  value={@form[:zip_code].value} class={input_class(@form, :zip_code)} />
                {error_tag(@form, :zip_code)}
              </div>
              <div>
                <label class="mb-1 block text-sm font-medium" for="job_posting_city">{gettext("City")}</label>
                <input type="text" name="job_posting[city]" id="job_posting_city"
                  value={@form[:city].value} class={input_class(@form, :city)} />
                {error_tag(@form, :city)}
              </div>
              <div>
                <label class="mb-1 block text-sm font-medium" for="job_posting_country">{gettext("Country")}</label>
                <select name="job_posting[country]" id="job_posting_country" class={input_class()}>
                  <option
                    :for={{label, value} <- Countries.select_options()}
                    value={value}
                    selected={country_value(@changeset) == value}
                  >{label}</option>
                </select>
                {error_tag(@form, :country)}
              </div>
            </div>
          </div>

          <div :if={current(@changeset, :workplace_type) == :remote}>
            <label class="mb-1 block text-sm font-medium" for="job_posting_remote_countries">
              {gettext("Applicants must be located in")}
            </label>
            <select
              name="job_posting[remote_countries][]"
              id="job_posting_remote_countries"
              multiple
              size="6"
              class={input_class()}
            >
              <option
                :for={{label, value} <- Countries.select_options()}
                value={value}
                selected={value in remote_country_values(@changeset)}
              >{label}</option>
            </select>
            {error_tag(@form, :remote_countries)}
            <p class="editform__hint">{gettext("Hold Ctrl / Cmd to select more than one.")}</p>
          </div>
        </.card>

        <.card class="space-y-5">
          <.section_title>{gettext("Pay")}</.section_title>
          <p class="text-xs text-slate-600 dark:text-slate-400">
            {gettext("A pay range is required to publish (except volunteer postings).")}
          </p>
          <div class="grid gap-4 sm:grid-cols-4">
            <div>
              <label class="mb-1 block text-sm font-medium" for="job_posting_salary_min">{gettext("From")}</label>
              <input type="number" min="1" step="1" name="job_posting[salary_min]" id="job_posting_salary_min"
                value={@form[:salary_min].value} class={input_class(@form, :salary_min)} />
              {error_tag(@form, :salary_min)}
            </div>
            <div>
              <label class="mb-1 block text-sm font-medium" for="job_posting_salary_max">{gettext("up to")}</label>
              <input type="number" min="1" step="1" name="job_posting[salary_max]" id="job_posting_salary_max"
                value={@form[:salary_max].value} class={input_class(@form, :salary_max)} />
              {error_tag(@form, :salary_max)}
            </div>
            <div>
              <label class="mb-1 block text-sm font-medium" for="job_posting_salary_currency">{gettext("Currency")}</label>
              <select name="job_posting[salary_currency]" id="job_posting_salary_currency" class={input_class()}>
                <option :for={{label, value} <- Salary.currency_options()} value={value}
                  selected={current(@changeset, :salary_currency) == value}>{label}</option>
              </select>
            </div>
            <div>
              <label class="mb-1 block text-sm font-medium" for="job_posting_salary_period">{gettext("Per")}</label>
              <select name="job_posting[salary_period]" id="job_posting_salary_period" class={input_class()}>
                <option :for={{label, value} <- Salary.period_options()} value={value}
                  selected={current(@changeset, :salary_period) == value}>{label}</option>
              </select>
            </div>
          </div>
        </.card>

        <.card class="space-y-4">
          <.section_title>{gettext("Description")}</.section_title>
          <.markdown_editor
            id="job-description"
            name="job_posting[description]"
            value={@form[:description].value || ""}
            label={gettext("Job description")}
            placeholder={gettext("Describe the role. Markdown is supported.")}
            rows={10}
          />
          {error_tag(@form, :description)}

          <div>
            <.section_title>{gettext("Images")}</.section_title>
            <ul :if={@images != []} class="mt-2 flex flex-wrap gap-3">
              <li :for={image <- @images} class="relative">
                <img src={Vutuv.Jobs.JobPostingImage.url(image, "thumb")} class="h-20 w-20 rounded-lg object-cover" alt={image.alt} />
                <button type="button" phx-click="remove-image" phx-value-id={image.id}
                  class="absolute -right-2 -top-2 rounded-full bg-slate-800 px-1.5 text-xs text-white">×</button>
              </li>
            </ul>
            <label class="mt-2 inline-block cursor-pointer text-sm font-semibold text-brand-600 hover:text-brand-700">
              <.live_file_input upload={@uploads.images} class="sr-only" />
              📷 {gettext("Add images")}
            </label>
          </div>
        </.card>

        <.card class="space-y-4">
          <.section_title>{gettext("Tags")}</.section_title>
          <p class="text-xs text-slate-600 dark:text-slate-400">
            {gettext("Tags match your posting to members. Separate with commas; quote multi-word tags like \"Ruby on Rails\".")}
          </p>
          <div>
            <label class="mb-1 block text-sm font-medium" for="job_posting_required_tags">{gettext("Required")}</label>
            <input type="text" name="job_posting[required_tags]" id="job_posting_required_tags"
              value={@required_tags} class={input_class()} />
          </div>
          <div>
            <label class="mb-1 block text-sm font-medium" for="job_posting_nice_to_have_tags">{gettext("Nice to have")}</label>
            <input type="text" name="job_posting[nice_to_have_tags]" id="job_posting_nice_to_have_tags"
              value={@nice_tags} class={input_class()} />
          </div>
        </.card>

        <.card class="space-y-5">
          <.section_title>{gettext("How to apply")}</.section_title>
          <div>
            <label class="mb-1 block text-sm font-medium" for="job_posting_apply_kind">{gettext("Applications go to")}</label>
            <select name="job_posting[apply_kind]" id="job_posting_apply_kind" class={input_class()}>
              <option value="url" selected={current(@changeset, :apply_kind) == :url}>{gettext("A website")}</option>
              <option value="email" selected={current(@changeset, :apply_kind) == :email}>{gettext("An e-mail address")}</option>
              <option value="message" selected={current(@changeset, :apply_kind) == :message}>{gettext("A vutuv message to me")}</option>
            </select>
          </div>
          <div :if={current(@changeset, :apply_kind) == :url}>
            <label class="mb-1 block text-sm font-medium" for="job_posting_apply_url">{gettext("Application URL")}</label>
            <input type="url" name="job_posting[apply_url]" id="job_posting_apply_url"
              value={@form[:apply_url].value} class={input_class(@form, :apply_url)} />
            {error_tag(@form, :apply_url)}
          </div>
          <div :if={current(@changeset, :apply_kind) == :email}>
            <label class="mb-1 block text-sm font-medium" for="job_posting_apply_email">{gettext("Application e-mail")}</label>
            <input type="email" name="job_posting[apply_email]" id="job_posting_apply_email"
              value={@form[:apply_email].value} class={input_class(@form, :apply_email)} />
            {error_tag(@form, :apply_email)}
          </div>
        </.card>

        <.card class="space-y-5">
          <.section_title>{gettext("Visibility")}</.section_title>
          <div>
            <label class="mb-1 block text-sm font-medium" for="job_posting_visibility">{gettext("Who can see it")}</label>
            <select name="job_posting[visibility]" id="job_posting_visibility" class={input_class()}>
              <option value="everyone" selected={current(@changeset, :visibility) == :everyone}>{gettext("Everyone (public)")}</option>
              <option value="members" selected={current(@changeset, :visibility) == :members}>{gettext("Signed-in members only")}</option>
            </select>
          </div>

          <div :if={current(@changeset, :visibility) == :everyone} class="space-y-3">
            <label class="flex items-start gap-3 text-sm">
              <input type="hidden" name="job_posting[seo?]" value="false" />
              <input type="checkbox" name="job_posting[seo?]" value="true"
                checked={checked?(@form[:seo?].value)} class={checkbox_class()} />
              <span>{gettext("Let search engines index this posting.")}</span>
            </label>
            <label class="flex items-start gap-3 text-sm">
              <input type="hidden" name="job_posting[geo?]" value="false" />
              <input type="checkbox" name="job_posting[geo?]" value="true"
                checked={checked?(@form[:geo?].value)} class={checkbox_class()} />
              <span>{gettext("Offer the machine-readable formats (.md/.txt/.json/.xml) to AI agents.")}</span>
            </label>
          </div>
        </.card>

        <div class="flex flex-wrap items-center gap-3">
          <button type="submit" name="do" value="publish"
            class="rounded-lg bg-brand-600 px-4 py-2 text-sm font-semibold text-white hover:bg-brand-700">
            {gettext("Publish")}
          </button>
          <button type="submit" name="do" value="draft"
            class="rounded-lg bg-slate-100 px-4 py-2 text-sm font-semibold text-slate-700 hover:bg-slate-200 dark:bg-slate-800 dark:text-slate-200 dark:hover:bg-slate-700">
            {gettext("Save draft")}
          </button>
          <.link navigate={~p"/jobs/mine"} class="text-sm font-semibold text-slate-600 hover:text-slate-800 dark:text-slate-400">
            {gettext("Cancel")}
          </.link>
        </div>
      </.form>
    </div>
    """
  end

  # --- render helpers --------------------------------------------------------

  # The current value of a field in the working changeset (change or stored),
  # driving the form's conditional blocks.
  defp current(changeset, field), do: Ecto.Changeset.get_field(changeset, field)

  # A new posting preselects the installation's default country (issue #932);
  # an existing one keeps its own.
  defp country_value(changeset), do: current(changeset, :country) || Vutuv.Geo.default_country()

  defp remote_country_values(changeset) do
    case current(changeset, :remote_countries) do
      [] -> [Vutuv.Geo.default_country()]
      codes -> codes
    end
  end

  defp agg_hint?(form), do: JobPosting.agg_hint?(form[:title].value || "")

  defp checked?(value), do: value in [true, "true"]
end
