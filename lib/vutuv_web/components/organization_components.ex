defmodule VutuvWeb.OrganizationComponents do
  @moduledoc """
  Shared kit-page pieces for verified organization pages (issue #929): the
  domain-verification panel's parts, the kind badge, the location line. Not
  globally imported — `import VutuvWeb.OrganizationComponents` at the call site.
  The logo tile lives in `VutuvWeb.UI` (issue #1410), and so does the emerald ✓
  that vouches for the proven domain (`<.verified_mark>`, shared with a member's
  verified webpage link).
  """

  use Phoenix.Component

  use Gettext, backend: VutuvWeb.Gettext

  import VutuvWeb.ErrorHelpers
  # `organization_logo/1` lives in the kit (issue #1410): the shared face
  # strips render it too, and `VutuvWeb.UI` cannot import this module back.
  import VutuvWeb.UI, only: [input_class: 2, organization_logo: 1]

  alias Vutuv.Countries
  alias Vutuv.Organizations
  alias Vutuv.Organizations.Organization

  attr(:domain, :string, required: true)

  @doc """
  The standing promise under a verification panel: this is not the only thing
  that ever looks again. Without it the honest reading of the panel is that a
  member has to sit and press the button until DNS catches up, which is what
  issue #1466 described doing.
  """
  def check_reassurance(assigns) do
    ~H"""
    <p data-check-reassurance class="mt-3 text-xs text-slate-600 dark:text-slate-400">
      {gettext("A new entry can take a while to reach everyone. We keep checking %{domain} by ourselves and send you an email as soon as it works, so you can close this page.", domain: @domain)}
    </p>
    """
  end

  attr(:organization, :map, required: true)
  slot(:inner_block)
  slot(:actions)

  @doc """
  One organization in a list: logo, name and location. The default slot carries
  whatever belongs under the name (a row of role badges), `:actions` whatever
  sits at the right edge of the row (an unfollow button).

  The three lists that show organizations — a member's followers, the
  organizations they follow, and the ones they administer — each carried their
  own copy of these fifteen lines, and the third had already drifted: it built
  its own `/organizations/:slug` path instead of asking
  `Organizations.canonical_path/1`, so a page with an opt-in root handle was
  linked by its slug there and by its handle in the other two.
  """
  def organization_row(assigns) do
    ~H"""
    <li class="flex items-center gap-4 py-4">
      <.link navigate={Organizations.canonical_path(@organization)} class="shrink-0">
        <.organization_logo organization={@organization} class="h-12 w-12" />
      </.link>
      <div class="min-w-0 flex-1">
        <.link
          navigate={Organizations.canonical_path(@organization)}
          class="block truncate font-semibold text-slate-900 hover:text-brand-700 dark:text-slate-100 dark:hover:text-brand-300"
        >
          {@organization.name}
        </.link>
        <.organization_location
          organization={@organization}
          class="truncate text-sm text-slate-600 dark:text-slate-400"
        />
        {render_slot(@inner_block)}
      </div>
      {render_slot(@actions)}
    </li>
    """
  end

  attr(:organization, :map, required: true)
  attr(:class, :string, default: nil)

  @doc "The organization's \"City, Country\" line (nil parts folded away)."
  def organization_location(assigns) do
    ~H"""
    <p class={@class}>
      {[@organization.city, Countries.name(@organization.country)] |> Enum.reject(&(&1 in [nil, ""])) |> Enum.join(", ")}
    </p>
    """
  end

  attr(:form, :any, required: true)
  attr(:field, :atom, required: true)
  attr(:label, :string, required: true)
  attr(:type, :string, default: "text")
  attr(:rest, :global)

  @doc "A labelled text/url input bound to a form field, with error marking."
  def text_field(assigns) do
    ~H"""
    <div>
      <label for={@form[@field].id} class="block text-sm font-semibold text-slate-700 dark:text-slate-200">
        {@label}
      </label>
      <input
        type={@type}
        id={@form[@field].id}
        name={@form[@field].name}
        value={Phoenix.HTML.Form.normalize_value(@type, @form[@field].value)}
        aria-invalid={@form[@field].errors != [] && "true"}
        class={input_class(@form, @field)}
        {@rest}
      />
      {error_tag(@form, @field)}
    </div>
    """
  end

  attr(:form, :any, required: true)
  attr(:countries, :list, required: true)
  attr(:label, :string, required: true)

  @doc "The ISO country `<select>` bound to the `:country` form field."
  def country_select(assigns) do
    ~H"""
    <div>
      <label for={@form[:country].id} class="block text-sm font-semibold text-slate-700 dark:text-slate-200">
        {@label}
      </label>
      <select id={@form[:country].id} name={@form[:country].name} class={input_class(@form, :country)}>
        <option value="">{gettext("Select a country")}</option>
        <option :for={{name, code} <- @countries} value={code} selected={@form[:country].value == code}>
          {name}
        </option>
      </select>
      {error_tag(@form, :country)}
    </div>
    """
  end

  attr(:form, :any, required: true)
  attr(:label, :string, required: true)

  @doc """
  The organization-kind (Art) select for the claim wizard and the owner edit
  form. A blank first option so a new organization must actively choose its kind
  (a blank submit fails the required `Ecto.Enum` cast). Options and labels come
  from `Organization` so this select, the page badge and the agent docs can never
  disagree.
  """
  def kind_select(assigns) do
    ~H"""
    <div>
      <label for={@form[:kind].id} class="block text-sm font-semibold text-slate-700 dark:text-slate-200">
        {@label}
      </label>
      <select id={@form[:kind].id} name={@form[:kind].name} class={input_class(@form, :kind)}>
        <option value="">{gettext("Please choose")}</option>
        <option
          :for={{label, value} <- Organization.kind_options()}
          value={value}
          selected={to_string(@form[:kind].value) == to_string(value)}
        >
          {label}
        </option>
      </select>
      {error_tag(@form, :kind)}
    </div>
    """
  end

  attr(:kind, :any, required: true)
  attr(:class, :string, default: nil)

  @doc """
  The organization-kind (Art) pill, e.g. "Verein / Verband" or "Behörde", so a
  visitor sees at a glance that a page is a Verein or a Behörde and not assume
  every organization is a company. Renders nothing for an unknown/blank kind.
  """
  def kind_badge(assigns) do
    ~H"""
    <span
      :if={Organization.kind_label(@kind)}
      class={[
        "inline-flex items-center rounded-full bg-slate-100 px-2.5 py-0.5 text-xs font-medium text-slate-700 dark:bg-slate-800 dark:text-slate-200",
        @class
      ]}
    >
      {Organization.kind_label(@kind)}
    </span>
    """
  end

  attr(:organization, :map, required: true)
  attr(:active, :atom, required: true)
  attr(:viewer, :map, required: true)

  @doc """
  The header + tab bar shared by the organization management pages (issue #930): a
  back link to the public page and tabs for Page (edit), Team (roles), Domains and
  Job exclusions. Team/Domains show only for an owner (admins may edit the page
  only); Job exclusions (issue #939) and Activity show for any role holder, since
  the standing default governs the postings they can already manage.

  Every page that renders this header is already behind a `can_manage?/2` gate,
  which is why those two tabs are unconditional here: the `manage?` attribute
  they used to be guarded by was passed `true` by all nine call sites, so it was
  a knob that only ever read one way.

  **It reads the roles itself, and that is the fix for issue #1484 carried one
  step further.** The two booleans used to be required attributes, threaded from
  nine call sites — five of which passed a literal `true` read off the route
  rather than off the viewer, which is a hidden tab waiting to happen exactly as
  `publisher?` defaulting to `false` already was. One `Organizations.role_powers/2`
  here answers both from one query, and "a page forgot to compute a role" stops
  being expressible. The pages are already behind their own `can_manage?/2` gate;
  this only decides which tabs show.
  """
  def manage_header(assigns) do
    assigns =
      assign(assigns, :powers, Organizations.role_powers(assigns.organization, assigns.viewer))

    ~H"""
    <div class="mb-6">
      <.link
        navigate={"/organizations/#{@organization.slug}"}
        class="text-sm font-semibold text-slate-600 hover:text-slate-800 dark:text-slate-400 dark:hover:text-slate-200"
      >
        ← {@organization.name}
      </.link>
      <nav class="mt-3 flex flex-wrap gap-1 border-b border-slate-200 dark:border-slate-800">
        <.manage_tab active={@active == :edit} navigate={"/organizations/#{@organization.slug}/edit"}>
          {gettext("Page")}
        </.manage_tab>
        <.manage_tab :if={@powers.owner?} active={@active == :roles} navigate={"/organizations/#{@organization.slug}/roles"}>
          {gettext("Team")}
        </.manage_tab>
        <.manage_tab :if={@powers.owner?} active={@active == :domains} navigate={"/organizations/#{@organization.slug}/domains"}>
          {gettext("Domains")}
        </.manage_tab>
        <.manage_tab active={@active == :exclusions} navigate={"/organizations/#{@organization.slug}/exclusions"}>
          {gettext("Job exclusions")}
        </.manage_tab>
        <%!-- What happened to the page (issue #1336). Open to the whole team,
        not only its publishers: this is news ABOUT the page rather than
        speaking FOR it. --%>
        <.manage_tab active={@active == :activity} navigate={"/organizations/#{@organization.slug}/activity"}>
          {gettext("Activity")}
        </.manage_tab>
        <%!-- What the page reads (issue #1336). Publishers only, unlike
        Activity beside it: this is the page's own reading, part of speaking
        for it, not news about it. --%>
        <.manage_tab :if={@powers.publisher?} active={@active == :feed} navigate={"/organizations/#{@organization.slug}/feed"}>
          {gettext("Feed")}
        </.manage_tab>
        <%!-- "Follows", not "Following": the member-voiced msgid translates to
        "Folge ich" (I follow), which is the wrong voice under a page's nav —
        this list is what the PAGE follows, not what the reader does. --%>
        <.manage_tab :if={@powers.publisher?} active={@active == :following} navigate={"/organizations/#{@organization.slug}/following"}>
          {gettext("Follows")}
        </.manage_tab>
        <%!-- Owner-only (issue #1334): federating decides how the page appears
        on servers we do not run, and cannot be fully taken back. --%>
        <.manage_tab :if={@powers.owner?} active={@active == :fediverse} navigate={"/organizations/#{@organization.slug}/fediverse"}>
          {gettext("Fediverse")}
        </.manage_tab>
        <%!-- Its own tab rather than a card on the Fediverse one, mirroring the
        member's /settings/apps: federating publishes the page to other servers,
        while this only decides whether the Editorial team may reach it from a
        phone app. Owner-only all the same — it is an administrative question
        about the page, not part of speaking for it. --%>
        <.manage_tab :if={@powers.owner?} active={@active == :apps} navigate={"/organizations/#{@organization.slug}/apps"}>
          {gettext("Apps")}
        </.manage_tab>
      </nav>
    </div>
    """
  end

  attr(:active, :boolean, default: false)
  attr(:navigate, :string, required: true)
  slot(:inner_block, required: true)

  defp manage_tab(assigns) do
    ~H"""
    <.link
      navigate={@navigate}
      class={[
        "-mb-px border-b-2 px-3 py-2 text-sm font-semibold",
        if(@active,
          do: "border-brand-600 text-brand-700 dark:text-brand-300",
          else:
            "border-transparent text-slate-600 hover:text-slate-800 dark:text-slate-400 dark:hover:text-slate-200"
        )
      ]}
    >
      {render_slot(@inner_block)}
    </.link>
    """
  end

  @doc "The human, localized label for an organization role."
  def role_label("owner"), do: gettext("Owner")
  def role_label("admin"), do: gettext("Admin")
  # "Editorial" / "Redaktion" names the function rather than the person, which
  # is the point: this role says "may write in our name" and must not read as
  # seniority. The code name stays `publisher`.
  def role_label("publisher"), do: gettext("Editorial")
  def role_label("recruiter"), do: gettext("Recruiter")
  def role_label(_), do: gettext("Member")

  @doc "One line saying what a role may do, for the roster's checkboxes."
  def role_hint("owner"), do: gettext("Manages the team and the domains, and edits the page.")
  def role_hint("admin"), do: gettext("Edits the page and posts jobs.")
  def role_hint("publisher"), do: gettext("Writes posts in the organization's name.")
  def role_hint("recruiter"), do: gettext("Posts jobs.")
  def role_hint(_), do: ""

  @doc "The human, localized label for an alias kind."
  def alias_kind_label("former"), do: gettext("Former name")
  def alias_kind_label("brand"), do: gettext("Brand")
  def alias_kind_label("abbreviation"), do: gettext("Abbreviation")
  def alias_kind_label(_), do: gettext("Alias")
end
