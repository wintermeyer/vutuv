defmodule VutuvWeb.Admin.PrefHTML do
  @moduledoc false
  use VutuvWeb, :html

  alias Vutuv.Prefs
  alias Vutuv.Prefs.Pref

  embed_templates("../../templates/admin/pref/*")

  @doc """
  One preference control on the admin forms, rendered from its registry
  definition: a number input, a checkbox or a select, named `prefs[<key>]`
  (id `pref_<key>`), pre-filled with the raw string `value`.

  Both admin pages render every registry pref through this — the defaults
  page as-is, the per-member override page with `blank_option` (an extra
  leading "installation default" choice; there a blank submission means
  "clear back to inherit", so its number inputs are not `required`).
  """
  attr(:pref, Pref, required: true)
  attr(:value, :string, required: true)
  attr(:invalid, :boolean, default: false)
  attr(:blank_option, :string, default: nil)

  def pref_control(%{pref: %Pref{type: :integer}} = assigns) do
    ~H"""
    <input
      type="number"
      id={"pref_#{@pref.key}"}
      name={"prefs[#{@pref.key}]"}
      value={@value}
      min={@pref.min}
      max={@pref.max}
      required={is_nil(@blank_option)}
      placeholder={@blank_option}
      class={[input_class(@invalid), "sm:max-w-32"]}
      aria-invalid={@invalid && "true"}
    />
    """
  end

  def pref_control(%{pref: %Pref{type: :boolean}} = assigns) do
    ~H"""
    <%= if @blank_option do %>
      <select
        id={"pref_#{@pref.key}"}
        name={"prefs[#{@pref.key}]"}
        class={[input_class(@invalid), "sm:max-w-64"]}
      >
        <option value="">{@blank_option}</option>
        <option value="true" selected={@value == "true"}>{Prefs.value_label(@pref, true)}</option>
        <option value="false" selected={@value == "false"}>
          {Prefs.value_label(@pref, false)}
        </option>
      </select>
    <% else %>
      <span class="inline-flex">
        <input type="hidden" name={"prefs[#{@pref.key}]"} value="false" />
        <input
          type="checkbox"
          id={"pref_#{@pref.key}"}
          name={"prefs[#{@pref.key}]"}
          value="true"
          checked={@value == "true"}
          class={checkbox_class()}
        />
      </span>
    <% end %>
    """
  end

  def pref_control(%{pref: %Pref{type: :select}} = assigns) do
    ~H"""
    <select
      id={"pref_#{@pref.key}"}
      name={"prefs[#{@pref.key}]"}
      class={[input_class(@invalid), "sm:max-w-64"]}
    >
      <option :if={@blank_option} value="">{@blank_option}</option>
      <%= for option <- @pref.values do %>
        <option value={option} selected={@value == option}>
          {Prefs.value_label(@pref, option)}
        </option>
      <% end %>
    </select>
    """
  end

  @doc "The red field-error line under an invalid control."
  attr(:invalid, :boolean, required: true)

  def pref_error(assigns) do
    ~H"""
    <span :if={@invalid} class="editform__error">
      {gettext("This value is not valid.")}
    </span>
    """
  end
end
