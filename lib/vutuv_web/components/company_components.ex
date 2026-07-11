defmodule VutuvWeb.CompanyComponents do
  @moduledoc """
  Shared kit-page pieces for verified company pages (issue #929): the logo tile
  (uploaded image or an initials fallback) and the verified-domain badge. Not
  globally imported — `import VutuvWeb.CompanyComponents` at the call site.
  """

  use Phoenix.Component

  use Gettext, backend: VutuvWeb.Gettext

  import VutuvWeb.ErrorHelpers
  import VutuvWeb.UI, only: [input_class: 2]

  alias Vutuv.Companies.CompanyImage
  alias Vutuv.Countries

  attr(:company, :map, required: true)
  attr(:version, :string, default: "feed")
  attr(:class, :string, default: "h-16 w-16")

  @doc "A company's logo, or a brand-tint initials tile when it has none."
  def company_logo(assigns) do
    ~H"""
    <%= if @company.logo do %>
      <img
        src={CompanyImage.token_url(@company.logo, @version)}
        alt={@company.name}
        class={[@class, "rounded-2xl object-cover ring-1 ring-slate-200 dark:ring-slate-800"]}
      />
    <% else %>
      <span
        class={[
          @class,
          "flex items-center justify-center rounded-2xl bg-brand-50 font-bold text-brand-700 dark:bg-brand-900/40 dark:text-brand-100"
        ]}
        aria-hidden="true"
      >
        {initial(@company.name)}
      </span>
    <% end %>
    """
  end

  attr(:domain, :string, required: true)
  attr(:class, :string, default: nil)

  @doc "The prominent verified-domain badge: the domain is what viewers trust."
  def verified_badge(assigns) do
    ~H"""
    <span class={[
      "inline-flex items-center gap-1.5 rounded-full bg-emerald-50 px-3 py-1 text-sm font-semibold text-emerald-700 ring-1 ring-emerald-200 dark:bg-emerald-900/30 dark:text-emerald-200 dark:ring-emerald-800",
      @class
    ]}>
      <svg class="h-4 w-4" viewBox="0 0 20 20" fill="currentColor" aria-hidden="true">
        <path
          fill-rule="evenodd"
          d="M16.704 4.153a.75.75 0 0 1 .143 1.052l-8 10.5a.75.75 0 0 1-1.127.075l-4.5-4.5a.75.75 0 0 1 1.06-1.06l3.894 3.893 7.48-9.817a.75.75 0 0 1 1.05-.143Z"
          clip-rule="evenodd"
        />
      </svg>
      {gettext("Verified via %{domain}", domain: @domain)}
    </span>
    """
  end

  attr(:company, :map, required: true)
  attr(:class, :string, default: nil)

  @doc "The company's \"City, Country\" line (nil parts folded away)."
  def company_location(assigns) do
    ~H"""
    <p class={@class}>
      {[@company.city, Countries.name(@company.country)] |> Enum.reject(&(&1 in [nil, ""])) |> Enum.join(", ")}
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

  attr(:company, :map, required: true)
  attr(:active, :atom, required: true)
  attr(:owner?, :boolean, default: false)

  @doc """
  The header + tab bar shared by the company management pages (issue #930): a
  back link to the public page and tabs for Page (edit), Team (roles) and
  Domains. Team/Domains show only for an owner (admins may edit the page only).
  """
  def manage_header(assigns) do
    ~H"""
    <div class="mb-6">
      <.link
        navigate={"/companies/#{@company.slug}"}
        class="text-sm font-semibold text-slate-600 hover:text-slate-800 dark:text-slate-400 dark:hover:text-slate-200"
      >
        ← {@company.name}
      </.link>
      <nav class="mt-3 flex flex-wrap gap-1 border-b border-slate-200 dark:border-slate-800">
        <.manage_tab active={@active == :edit} navigate={"/companies/#{@company.slug}/edit"}>
          {gettext("Page")}
        </.manage_tab>
        <.manage_tab :if={@owner?} active={@active == :roles} navigate={"/companies/#{@company.slug}/roles"}>
          {gettext("Team")}
        </.manage_tab>
        <.manage_tab :if={@owner?} active={@active == :domains} navigate={"/companies/#{@company.slug}/domains"}>
          {gettext("Domains")}
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

  @doc "The human, localized label for a company role."
  def role_label("owner"), do: gettext("Owner")
  def role_label("admin"), do: gettext("Admin")
  def role_label("recruiter"), do: gettext("Recruiter")
  def role_label(_), do: gettext("Member")

  @doc "The human, localized label for an alias kind."
  def alias_kind_label("former"), do: gettext("Former name")
  def alias_kind_label("brand"), do: gettext("Brand")
  def alias_kind_label("abbreviation"), do: gettext("Abbreviation")
  def alias_kind_label(_), do: gettext("Alias")

  defp initial(name) do
    name
    |> String.trim()
    |> String.first()
    |> Kernel.||("?")
    |> String.upcase()
  end
end
