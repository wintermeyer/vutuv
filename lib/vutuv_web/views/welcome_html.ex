defmodule VutuvWeb.WelcomeHTML do
  @moduledoc false
  use VutuvWeb, :html

  import VutuvWeb.UserHelpers,
    only: [
      employment_status_options: 0,
      desired_salary_currency_options: 0,
      desired_salary_period_options: 0,
      desired_workplace_options: 0
    ]

  alias Phoenix.HTML.Form
  alias Vutuv.Accounts.User
  alias VutuvWeb.AddressHTML

  embed_templates("../templates/welcome/*")

  @doc """
  The hero greeting: the member's first name when they gave one, so the page
  reads as a personal welcome rather than a form. Falls back to the plain
  greeting for an account that only has a last name or a nickname.
  """
  def welcome_title(%User{first_name: name}) when is_binary(name) and name != "",
    do: gettext("Welcome to vutuv, %{name}!", name: name)

  def welcome_title(%User{}), do: gettext("Welcome to vutuv!")

  @doc """
  The address-label choices offered on the welcome page. The stored value is
  the translated word itself, because `addresses.description` is a free-text
  label everywhere else (the member types their own on /settings/addresses) —
  there is no code that reads it back.
  """
  def address_label_options do
    [gettext("Private"), gettext("Work")]
  end

  @doc """
  Which address label the radio group shows as picked: whatever was submitted,
  else the first choice ("Private"). Preselecting the everyday case keeps the
  member from having to answer a question they did not ask for — and the label
  alone never creates an address (`Address.location_given?/1`).
  """
  def selected_address_label(form) do
    case Form.input_value(form, :description) do
      value when is_binary(value) and value != "" -> value
      _ -> hd(address_label_options())
    end
  end

  @doc "The country choices, shared with the classic address forms."
  defdelegate country_names, to: AddressHTML
end
