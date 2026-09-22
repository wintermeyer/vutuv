defmodule Vutuv.SignupTrap.Entry do
  @moduledoc """
  One sign-up `Vutuv.SignupTrap` caught: what the form submitted, where it came
  from, and which rule caught it. `reported_at` is set once the weekly report
  that lists the entry has gone out; `Vutuv.SignupTrap.run/2` deletes every
  entry 14 days after it arrived, reported or not.

  `params` is the whole submitted form, flattened to dotted keys
  (`"emails.0.value"`) and capped by `Vutuv.SignupTrap.record/4`, because the
  endpoint is unauthenticated and the shape of the POST is the sender's choice.
  """

  use VutuvWeb, :model

  schema "trapped_registrations" do
    field(:rule, :string)
    field(:first_name, :string)
    field(:last_name, :string)
    field(:email, :string)
    field(:tag_list, :string)
    field(:params, :map, default: %{})
    field(:ip_address, :string)
    field(:user_agent, :string)
    field(:accept_language, :string)
    field(:reported_at, :utc_datetime)

    timestamps(type: :utc_datetime, updated_at: false)
  end
end
